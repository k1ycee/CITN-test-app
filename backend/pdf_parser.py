"""
PDF Parser — Extracts exam questions from PDFs using PyMuPDF + Google Gemini AI.

Supports three question types:
  - MCQ (Multiple Choice Questions) with options (a)(b)(c)(d)
  - SAQ (Short Answer Questions) with fill-in-the-blank
  - SEQ (Short Essay Questions)

The parser batches large PDFs before sending them to Gemini, then merges the
partial results into one normalized quiz payload.
"""

import json
import logging
import os
from collections import OrderedDict

import fitz  # PyMuPDF
import google.generativeai as genai

from config import Config

logger = logging.getLogger(__name__)

_gemini_configured = False


SECTION_ORDER = {"MCQ": 0, "SAQ": 1, "SEQ": 2}

PARSE_PROMPT = """You are an expert exam paper parser. Analyze the following text extracted from a university/college exam PDF and return structured JSON.

The PDF may contain one or more of these sections:
1. MCQ (Multiple Choice Questions) — numbered questions with options labeled (a), (b), (c), (d). Answers may appear in a solution section, answer key, or may need to be inferred from the question.
2. SAQ (Short Answer Questions) — fill-in-the-blank or short questions. Answers may appear in a solution section or may need to be inferred.
3. SEQ (Short Essay-Type Questions) — longer questions requiring brief essay answers. Answers may appear in a solution section or may need to be inferred.

Return ONLY valid JSON (no markdown, no code fences) in this exact format:
{
  "course_name": "The detected course name",
  "quiz_title": "A descriptive title for the quiz",
  "sections": [
    {
      "type": "MCQ",
      "label": "SECTION A",
      "questions": [
        {
          "number": 1,
          "text": "Question text",
          "options": {
            "a": "Option A",
            "b": "Option B",
            "c": "Option C",
            "d": "Option D"
          },
          "correct_answer": "A",
          "answer_source": "explicit_solution"
        }
      ]
    }
  ]
}

IMPORTANT RULES:
- Include every question detected in this chunk.
- If an explicit solution/answer key is present, use it and set answer_source to explicit_solution.
- If the document does not include an explicit answer but the answer can be confidently inferred from the question, set correct_answer using best effort and set answer_source to ai_inferred.
- If no reliable answer can be determined, set correct_answer to an empty string and answer_source to unknown.
- For MCQ, correct_answer must be A/B/C/D when available.
- For SAQ/SEQ, correct_answer should be the answer text when available.
- Preserve numbering and section labels where possible.
- Clean PDF artefacts.
- If the course name cannot be detected, use Unknown Course.

Here is the extracted PDF text chunk:

"""

GRADE_PROMPT = """You are an exam grading assistant. Compare a student's answer to the correct answer and determine if it is correct.

Question: {question}
Correct Answer: {correct_answer}
Student's Answer: {student_answer}

Evaluate whether the student's answer is semantically equivalent to the correct answer.
The student does not need exact wording. Judge meaning.

Return ONLY valid JSON (no markdown, no code fences):
{{
  "is_correct": true or false,
  "status": "correct" or "partially_correct" or "incorrect",
  "explanation": "Brief explanation"
}}
"""


def _ensure_gemini():
    """Lazily configure the Gemini client."""
    global _gemini_configured
    if not _gemini_configured:
        api_key = Config.GEMINI_API_KEY
        if not api_key:
            raise RuntimeError(
                "GEMINI_API_KEY is not set. "
                "Get one at https://aistudio.google.com/apikey"
            )
        genai.configure(api_key=api_key)
        _gemini_configured = True



def extract_pages_from_pdf(pdf_path: str) -> list[str]:
    """Extract PDF text page by page using PyMuPDF."""
    doc = fitz.open(pdf_path)
    pages = []
    for page_num in range(len(doc)):
        page = doc[page_num]
        text = page.get_text("text")
        pages.append(text.strip())
    doc.close()
    logger.info(
        "Extracted %d pages from %s",
        len(pages),
        os.path.basename(pdf_path),
    )
    return pages



def extract_text_from_pdf(pdf_path: str) -> str:
    """Extract all text from a PDF file using PyMuPDF."""
    return "\n\n--- PAGE BREAK ---\n\n".join(extract_pages_from_pdf(pdf_path))



def _build_batches(pages: list[str], max_chars: int) -> list[str]:
    """Combine pages into bounded prompt batches."""
    batches = []
    current_pages = []
    current_len = 0

    for index, page_text in enumerate(pages, start=1):
        normalized = page_text.strip() or "[EMPTY PAGE]"
        page_block = f"--- PAGE {index} ---\n{normalized}"

        if current_pages and current_len + len(page_block) > max_chars:
            batches.append("\n\n".join(current_pages))
            current_pages = []
            current_len = 0

        current_pages.append(page_block)
        current_len += len(page_block)

    if current_pages:
        batches.append("\n\n".join(current_pages))

    return batches



def _build_model():
    return genai.GenerativeModel(
        Config.GEMINI_MODEL,
        generation_config=genai.GenerationConfig(
            response_mime_type="application/json",
            temperature=0.1,
        ),
    )



def _parse_batch(model, batch_text: str, batch_number: int, total_batches: int) -> dict:
    prompt = PARSE_PROMPT + batch_text
    logger.info(
        "Sending batch %d/%d to Gemini (%d chars)",
        batch_number,
        total_batches,
        len(prompt),
    )
    response = model.generate_content(prompt)

    try:
        result = json.loads(response.text)
    except json.JSONDecodeError as exc:
        logger.error("Gemini returned invalid JSON for batch %d: %s", batch_number, response.text[:500])
        raise ValueError(f"AI returned invalid JSON for batch {batch_number}: {exc}") from exc

    if "sections" not in result:
        raise ValueError(f"AI response missing 'sections' key for batch {batch_number}")

    return result



def _normalize_question(section_type: str, question: dict) -> dict:
    normalized = {
        "number": int(question.get("number", 0)),
        "text": str(question.get("text") or "").strip(),
        "correct_answer": str(question.get("correct_answer") or "").strip(),
        "answer_source": str(question.get("answer_source") or "unknown").strip() or "unknown",
    }
    if section_type == "MCQ":
        options = question.get("options") or {}
        normalized["options"] = {
            "a": options.get("a"),
            "b": options.get("b"),
            "c": options.get("c"),
            "d": options.get("d"),
        }
        if normalized["correct_answer"]:
            normalized["correct_answer"] = normalized["correct_answer"].upper()
    return normalized



def _question_rank(question: dict) -> tuple[int, int]:
    source = question.get("answer_source", "unknown")
    source_rank = {
        "explicit_solution": 2,
        "ai_inferred": 1,
        "unknown": 0,
    }.get(source, 0)
    answer_rank = 1 if question.get("correct_answer") else 0
    return source_rank, answer_rank



def _merge_batch_results(batch_results: list[dict]) -> dict:
    course_name = "Unknown Course"
    quiz_title = "Untitled Quiz"
    merged_sections: dict[tuple[str, str], dict] = OrderedDict()

    for result in batch_results:
        candidate_course = str(result.get("course_name") or "").strip()
        candidate_title = str(result.get("quiz_title") or "").strip()
        if candidate_course and course_name == "Unknown Course":
            course_name = candidate_course
        if candidate_title and quiz_title == "Untitled Quiz":
            quiz_title = candidate_title

        for section in result.get("sections", []):
            section_type = str(section.get("type") or "").upper()
            section_label = str(section.get("label") or section_type).strip() or section_type
            section_key = (section_type, section_label)
            merged_section = merged_sections.setdefault(
                section_key,
                {
                    "type": section_type,
                    "label": section_label,
                    "questions": OrderedDict(),
                },
            )

            for question in section.get("questions", []):
                normalized = _normalize_question(section_type, question)
                question_key = normalized["number"]
                existing = merged_section["questions"].get(question_key)

                if existing is None:
                    merged_section["questions"][question_key] = normalized
                    continue

                if not existing.get("text") and normalized.get("text"):
                    existing["text"] = normalized["text"]

                if section_type == "MCQ":
                    existing_options = existing.setdefault("options", {})
                    for option_key, option_value in normalized.get("options", {}).items():
                        if option_value and not existing_options.get(option_key):
                            existing_options[option_key] = option_value

                if _question_rank(normalized) > _question_rank(existing):
                    existing["correct_answer"] = normalized.get("correct_answer", "")
                    existing["answer_source"] = normalized.get("answer_source", "unknown")

    sections = []
    for section in sorted(
        merged_sections.values(),
        key=lambda item: (SECTION_ORDER.get(item["type"], 99), item["label"]),
    ):
        questions = sorted(
            section["questions"].values(),
            key=lambda item: item["number"],
        )
        sections.append(
            {
                "type": section["type"],
                "label": section["label"],
                "questions": questions,
            }
        )

    return {
        "course_name": course_name,
        "quiz_title": quiz_title,
        "sections": sections,
    }



def parse_pdf_with_ai(pdf_path: str) -> dict:
    """Parse a PDF exam paper using batched Gemini requests."""
    _ensure_gemini()

    pages = extract_pages_from_pdf(pdf_path)
    if not any(page.strip() for page in pages):
        raise ValueError("PDF appears to be empty or image-only (no extractable text)")

    batches = _build_batches(pages, Config.GEMINI_PARSE_BATCH_CHARS)
    model = _build_model()
    batch_results = [
        _parse_batch(model, batch_text, index, len(batches))
        for index, batch_text in enumerate(batches, start=1)
    ]
    result = _merge_batch_results(batch_results)

    total_questions = sum(
        len(section.get("questions", []))
        for section in result.get("sections", [])
    )
    explicit_answers = sum(
        1
        for section in result.get("sections", [])
        for question in section.get("questions", [])
        if question.get("answer_source") == "explicit_solution"
    )
    inferred_answers = sum(
        1
        for section in result.get("sections", [])
        for question in section.get("questions", [])
        if question.get("answer_source") == "ai_inferred"
    )

    logger.info(
        "Parsed: course='%s', title='%s', %d batches, %d questions, explicit=%d, inferred=%d",
        result.get("course_name", "Unknown"),
        result.get("quiz_title", "Untitled"),
        len(batches),
        total_questions,
        explicit_answers,
        inferred_answers,
    )

    return result



def grade_answer_with_ai(
    question_text: str, correct_answer: str, student_answer: str
) -> dict:
    """Use Gemini AI to evaluate a student's text answer."""
    _ensure_gemini()

    model = _build_model()
    prompt = GRADE_PROMPT.format(
        question=question_text,
        correct_answer=correct_answer,
        student_answer=student_answer,
    )
    response = model.generate_content(prompt)

    try:
        result = json.loads(response.text)
    except json.JSONDecodeError:
        is_match = student_answer.strip().lower() == correct_answer.strip().lower()
        return {
            "is_correct": is_match,
            "status": "correct" if is_match else "incorrect",
            "explanation": "Exact match comparison (AI grading unavailable)",
        }

    return result
