"""
PDF Parser — Extracts exam questions from PDFs using PyMuPDF + Google Gemini AI.

The parser first segments a paper by topic headings such as:
FOUNDATION: BUSINESS LAW
FOUNDATION: ECONOMICS

Each topic is then parsed independently so completed topics can be stored as
individual quizzes while later topics are still processing.
"""

import io
import json
import logging
import os
import re
from collections import OrderedDict

import fitz  # PyMuPDF
import google.generativeai as genai
import pytesseract
from google.api_core.exceptions import DeadlineExceeded
from PIL import Image

from config import Config

logger = logging.getLogger(__name__)

_gemini_configured = False

if Config.TESSERACT_CMD:
    pytesseract.pytesseract.tesseract_cmd = Config.TESSERACT_CMD

OCR_MIN_TEXT_LENGTH = 20

SECTION_ORDER = {"MCQ": 0, "SAQ": 1, "SEQ": 2}

PARSE_PROMPT_TEMPLATE = """You are an expert exam paper parser.

This chunk belongs to the topic/course: {topic_name}

Common structure for this paper:
- FOUNDATION: {{Topic Name}}
- MCQ or MULTIPLE CHOICE QUESTIONS
- SOLUTION TO MCQ
- SHORT ANSWER QUESTIONS (SAQ) or SEQ
- SOLUTION TO SAQ or SOLUTION TO SEQ

Analyze the text chunk and return structured JSON.

Return ONLY valid JSON in this format:
{{
  "course_name": "{topic_name}",
  "quiz_title": "A descriptive title for this topic quiz",
  "sections": [
    {{
      "type": "MCQ",
      "label": "SECTION A",
      "questions": [
        {{
          "number": 1,
          "text": "Question text",
          "options": {{
            "a": "Option A",
            "b": "Option B",
            "c": "Option C",
            "d": "Option D"
          }},
          "correct_answer": "A",
          "answer_source": "explicit_solution",
          "confidence": 87
        }}
      ]
    }}
  ]
}}

Rules:
- Keep this chunk scoped to the topic {topic_name}.
- Prefer answers from explicit solution blocks.
- If no explicit solution exists but an answer can be inferred confidently, use it and set answer_source to ai_inferred.
- If no reliable answer exists, set correct_answer to an empty string and answer_source to unknown.
- For MCQ, correct_answer must be A/B/C/D when available.
- For SAQ/SEQ, correct_answer should be answer text when available.
- If section labels are missing, infer them from the nearest heading.
- Ignore unrelated noise.
- When answer_source is ai_inferred, include an integer "confidence" from 0-100 estimating how sure you are. Omit or zero it for explicit_solution.
- Always provide your best-effort correct_answer and set answer_source to ai_inferred rather than unknown, unless the question truly cannot be answered from the given text (e.g. it depends on an image or table that isn't present).

Text chunk:

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

ANSWER_KEY_PROMPT_TEMPLATE = """You are reading an answer key / solutions document for an exam.

Extract the answer for every question number you can find. Return ONLY valid JSON:
{{
  "answers": [
    {{"question_number": 1, "answer": "B"}},
    {{"question_number": 2, "answer": "Because supply exceeds demand"}}
  ]
}}

Document:

"""

SEGMENT_PROMPT_TEMPLATE = """You are analyzing an exam paper made of {page_count} pages, each marked with a "--- PAGE N ---" header.

Identify the distinct topic or course sections in this document. A new topic usually starts with a heading naming a subject/course (e.g. "FOUNDATION: BUSINESS LAW"), but wording varies by document, so use your judgment about where one topic's questions end and the next begins.

Return ONLY valid JSON: a list of segments in page order, covering every page exactly once, in this format:
[
  {{"topic_name": "Business Law", "start_page": 1, "end_page": 4}},
  {{"topic_name": "Economics", "start_page": 5, "end_page": 9}}
]

If the whole document is a single topic, return one segment covering all {page_count} pages.

Document:

"""


def _ensure_gemini():
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


def _ocr_page(page) -> str:
    try:
        pix = page.get_pixmap(dpi=300)
        image = Image.open(io.BytesIO(pix.tobytes("png")))
        return pytesseract.image_to_string(image).strip()
    except Exception:
        logger.exception("OCR failed for a page; continuing with empty text")
        return ""


def _extract_page_text(page) -> tuple[str, bool]:
    text = page.get_text("text").strip()
    if len(text) >= OCR_MIN_TEXT_LENGTH:
        return text, False
    ocr_text = _ocr_page(page)
    if ocr_text:
        return ocr_text, True
    return text, False


def extract_pages_from_pdf(pdf_path: str) -> list[str]:
    doc = fitz.open(pdf_path)
    pages = []
    ocr_page_count = 0
    for page_num in range(len(doc)):
        text, used_ocr = _extract_page_text(doc[page_num])
        if used_ocr:
            ocr_page_count += 1
        pages.append(text)
    doc.close()
    logger.info(
        "Extracted %d pages from %s (%d via OCR)",
        len(pages),
        os.path.basename(pdf_path),
        ocr_page_count,
    )
    return pages



def extract_text_from_pdf(pdf_path: str) -> str:
    return "\n\n--- PAGE BREAK ---\n\n".join(extract_pages_from_pdf(pdf_path))



def _join_pages(pages: list[str]) -> str:
    return "\n\n".join(
        f"--- PAGE {index} ---\n{page.strip() or '[EMPTY PAGE]'}"
        for index, page in enumerate(pages, start=1)
    )


def segment_topics_with_ai(pages: list[str]) -> list[dict]:
    _ensure_gemini()
    joined = _join_pages(pages)
    model = _build_model()
    prompt = SEGMENT_PROMPT_TEMPLATE.format(page_count=len(pages)) + joined

    try:
        response = model.generate_content(
            prompt,
            request_options={"timeout": Config.GEMINI_REQUEST_TIMEOUT},
        )
        segments = _extract_json_payload(response.text)
    except Exception:
        logger.exception("AI topic segmentation failed; treating document as one topic")
        return []

    if not isinstance(segments, list):
        logger.warning("AI segmentation returned a non-list payload; treating document as one topic")
        return []

    normalized = []
    for segment in segments:
        if not isinstance(segment, dict):
            continue
        topic_name = str(segment.get("topic_name") or "").strip()
        try:
            start_page = int(segment.get("start_page", 0))
            end_page = int(segment.get("end_page", 0))
        except (TypeError, ValueError):
            continue
        if not topic_name or start_page < 1 or end_page < start_page or end_page > len(pages):
            continue
        normalized.append({"topic_name": topic_name, "start_page": start_page, "end_page": end_page})

    return normalized


def extract_topic_segments_from_pdf(pdf_path: str) -> list[dict]:
    pages = extract_pages_from_pdf(pdf_path)
    segments = segment_topics_with_ai(pages)

    if not segments:
        return [{"topic_name": "Unknown Course", "text": _join_pages(pages)}]

    topics = []
    for segment in segments:
        page_slice = pages[segment["start_page"] - 1 : segment["end_page"]]
        topic_text = _join_pages(page_slice)
        if not topic_text.strip():
            continue
        topics.append({"topic_name": segment["topic_name"], "text": topic_text})

    if not topics:
        return [{"topic_name": "Unknown Course", "text": _join_pages(pages)}]

    logger.info("Detected %d topic segments", len(topics))
    return topics



def _build_batches_from_text(text: str, max_chars: int) -> list[str]:
    page_marker = re.compile(r"(?=--- PAGE \d+ ---)")
    parts = [part.strip() for part in page_marker.split(text) if part.strip()]
    if not parts:
        return [text]

    batches = []
    current_parts = []
    current_len = 0

    for part in parts:
        if current_parts and current_len + len(part) > max_chars:
            batches.append("\n\n".join(current_parts))
            current_parts = []
            current_len = 0

        current_parts.append(part)
        current_len += len(part)

    if current_parts:
        batches.append("\n\n".join(current_parts))

    return batches



def _build_model():
    return genai.GenerativeModel(
        Config.GEMINI_MODEL,
        generation_config=genai.GenerationConfig(
            response_mime_type="application/json",
            temperature=0.1,
        ),
    )



def _empty_parse_result(topic_name: str = "Unknown Course") -> dict:
    return {
        "course_name": topic_name,
        "quiz_title": f"{topic_name} Quiz",
        "sections": [],
    }



def _extract_json_payload(raw_text: str):
    raw_text = raw_text.strip()
    if not raw_text:
        raise json.JSONDecodeError("empty response", raw_text, 0)

    decoder = json.JSONDecoder()
    candidate_indices = [raw_text.find(start_char) for start_char in ("{", "[")]
    for start_index in sorted(index for index in candidate_indices if index != -1):
        try:
            payload, _ = decoder.raw_decode(raw_text[start_index:])
            return payload
        except json.JSONDecodeError:
            continue

    return json.loads(raw_text)



def _split_batch_text(batch_text: str) -> list[str]:
    page_marker = "--- PAGE "
    positions = []
    search_from = 0
    while True:
        position = batch_text.find(page_marker, search_from)
        if position == -1:
            break
        positions.append(position)
        search_from = position + len(page_marker)

    if len(positions) > 1:
        midpoint = len(positions) // 2
        split_index = positions[midpoint]
        left = batch_text[:split_index].strip()
        right = batch_text[split_index:].strip()
        return [part for part in (left, right) if part]

    midpoint = len(batch_text) // 2
    if midpoint <= 0 or midpoint >= len(batch_text):
        return [batch_text]

    left = batch_text[:midpoint].strip()
    right = batch_text[midpoint:].strip()
    return [part for part in (left, right) if part]



def _normalize_batch_result(result, topic_name: str, batch_number: int) -> dict:
    if isinstance(result, list):
        logger.warning(
            "Batch %d returned a top-level list; normalizing it",
            batch_number,
        )
        if all(isinstance(item, dict) and "questions" in item for item in result):
            result = {
                "course_name": topic_name,
                "quiz_title": f"{topic_name} Quiz",
                "sections": result,
            }
        elif all(isinstance(item, dict) for item in result):
            result = {
                "course_name": topic_name,
                "quiz_title": f"{topic_name} Quiz",
                "sections": [
                    {
                        "type": "",
                        "label": "",
                        "questions": result,
                    }
                ],
            }
        else:
            result = _empty_parse_result(topic_name)

    if not isinstance(result, dict):
        logger.warning(
            "Batch %d returned unsupported JSON type %s; continuing with empty sections",
            batch_number,
            type(result).__name__,
        )
        result = _empty_parse_result(topic_name)

    if "sections" not in result:
        logger.warning(
            "Batch %d returned no sections key; continuing with empty sections",
            batch_number,
        )
        result["sections"] = []

    result.setdefault("course_name", topic_name)
    result.setdefault("quiz_title", f"{topic_name} Quiz")
    return result



def _parse_batch(model, topic_name: str, batch_text: str, batch_number: int, total_batches: int) -> dict:
    prompt = PARSE_PROMPT_TEMPLATE.format(topic_name=topic_name) + batch_text
    logger.info(
        "Sending topic '%s' batch %d/%d to Gemini (%d chars)",
        topic_name,
        batch_number,
        total_batches,
        len(prompt),
    )

    try:
        response = model.generate_content(
            prompt,
            request_options={"timeout": Config.GEMINI_REQUEST_TIMEOUT},
        )
    except DeadlineExceeded:
        logger.warning(
            "Gemini timed out on topic '%s' batch %d after %ss",
            topic_name,
            batch_number,
            Config.GEMINI_REQUEST_TIMEOUT,
        )
        split_parts = _split_batch_text(batch_text)
        if len(split_parts) > 1:
            sub_results = [
                _parse_batch(model, topic_name, part, (batch_number * 10) + index, total_batches)
                for index, part in enumerate(split_parts, start=1)
            ]
            return _merge_batch_results(sub_results, topic_name)
        return _empty_parse_result(topic_name)

    try:
        result = _extract_json_payload(response.text)
    except json.JSONDecodeError:
        logger.warning(
            "Gemini returned invalid JSON for topic '%s' batch %d: %s",
            topic_name,
            batch_number,
            response.text[:500],
        )
        split_parts = _split_batch_text(batch_text)
        if len(split_parts) > 1:
            sub_results = [
                _parse_batch(model, topic_name, part, (batch_number * 10) + index, total_batches)
                for index, part in enumerate(split_parts, start=1)
            ]
            return _merge_batch_results(sub_results, topic_name)
        return _empty_parse_result(topic_name)

    return _normalize_batch_result(result, topic_name, batch_number)



def _infer_section_type(section: dict, questions: list[dict]) -> str:
    raw_type = str(section.get("type") or "").strip().upper()
    if raw_type in SECTION_ORDER:
        return raw_type

    label = str(section.get("label") or "").strip().upper()
    if "MCQ" in label or "MULTIPLE CHOICE" in label:
        return "MCQ"
    if "SAQ" in label or "SHORT ANSWER" in label:
        return "SAQ"
    if "SEQ" in label or "ESSAY" in label or "SECTION B" in label:
        return "SEQ"

    mcq_like = 0
    text_like = 0
    for question in questions:
        options = question.get("options") or {}
        if any(options.get(key) for key in ("a", "b", "c", "d")):
            mcq_like += 1
        elif str(question.get("text") or "").strip():
            text_like += 1

    if mcq_like:
        return "MCQ"
    if text_like:
        return "SAQ"
    return "UNKNOWN"



def _normalize_section(section: dict) -> dict | None:
    raw_questions = section.get("questions")
    if not isinstance(raw_questions, list):
        return None

    questions = [item for item in raw_questions if isinstance(item, dict)]
    if not questions:
        return None

    section_type = _infer_section_type(section, questions)
    if section_type == "UNKNOWN":
        return None

    raw_label = str(section.get("label") or "").strip()
    if raw_label:
        section_label = raw_label
    else:
        default_labels = {
            "MCQ": "MULTIPLE CHOICE QUESTIONS (MCQ)",
            "SAQ": "SHORT ANSWER QUESTIONS (SAQ)",
            "SEQ": "SECTION B / SEQ",
        }
        section_label = default_labels.get(section_type, section_type)

    return {
        "type": section_type,
        "label": section_label,
        "questions": questions,
    }



def _normalize_question(section_type: str, question: dict) -> dict:
    try:
        number = int(question.get("number", 0))
    except (TypeError, ValueError):
        number = 0

    answer_source = str(question.get("answer_source") or "unknown").strip() or "unknown"
    confidence = None
    if answer_source == "ai_inferred":
        try:
            confidence = int(question.get("confidence", 0))
        except (TypeError, ValueError):
            confidence = 0
        confidence = max(0, min(100, confidence))

    normalized = {
        "number": number,
        "text": str(question.get("text") or "").strip(),
        "correct_answer": str(question.get("correct_answer") or "").strip(),
        "answer_source": answer_source,
        "confidence": confidence,
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



def _is_usable_question(question: dict) -> bool:
    if question["number"] <= 0:
        return False
    if question["text"]:
        return True
    options = question.get("options") or {}
    return any(str(value or "").strip() for value in options.values())



def _question_rank(question: dict) -> tuple[int, int, int]:
    source_rank = {
        "explicit_solution": 2,
        "ai_inferred": 1,
        "unknown": 0,
    }.get(question.get("answer_source", "unknown"), 0)
    answer_rank = 1 if question.get("correct_answer") else 0
    confidence_rank = question.get("confidence") or 0
    return source_rank, answer_rank, confidence_rank



def _merge_batch_results(batch_results: list[dict], topic_name: str = "Unknown Course") -> dict:
    course_name = topic_name
    quiz_title = f"{topic_name} Quiz"
    merged_sections: dict[tuple[str, str], dict] = OrderedDict()

    for result in batch_results:
        candidate_course = str(result.get("course_name") or "").strip()
        candidate_title = str(result.get("quiz_title") or "").strip()
        if candidate_course and course_name == topic_name:
            course_name = candidate_course
        if candidate_title and quiz_title == f"{topic_name} Quiz":
            quiz_title = candidate_title

        for raw_section in result.get("sections", []):
            if not isinstance(raw_section, dict):
                continue
            section = _normalize_section(raw_section)
            if section is None:
                continue

            section_type = section["type"]
            section_label = section["label"]
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
                if not _is_usable_question(normalized):
                    continue
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
                    existing["confidence"] = normalized.get("confidence")

    sections = []
    for section in sorted(
        merged_sections.values(),
        key=lambda item: (SECTION_ORDER.get(item["type"], 99), item["label"]),
    ):
        sections.append(
            {
                "type": section["type"],
                "label": section["label"],
                "questions": sorted(section["questions"].values(), key=lambda item: item["number"]),
            }
        )

    return {
        "course_name": course_name,
        "quiz_title": quiz_title,
        "sections": sections,
    }



def parse_topic_with_ai(topic_name: str, topic_text: str) -> dict:
    _ensure_gemini()
    if not topic_text.strip():
        return _empty_parse_result(topic_name)

    batches = _build_batches_from_text(topic_text, Config.GEMINI_PARSE_BATCH_CHARS)
    model = _build_model()
    batch_results = [
        _parse_batch(model, topic_name, batch_text, index, len(batches))
        for index, batch_text in enumerate(batches, start=1)
    ]
    result = _merge_batch_results(batch_results, topic_name)
    logger.info(
        "Parsed topic '%s' into %d sections and %d questions",
        topic_name,
        len(result.get("sections", [])),
        sum(len(section.get("questions", [])) for section in result.get("sections", [])),
    )
    return result



def parse_pdf_topics_with_ai(pdf_path: str) -> list[dict]:
    topics = extract_topic_segments_from_pdf(pdf_path)
    parsed_topics = []
    for topic in topics:
        parsed_topics.append(
            parse_topic_with_ai(
                topic_name=topic["topic_name"],
                topic_text=topic["text"],
            )
        )
    return parsed_topics



def parse_pdf_with_ai(pdf_path: str) -> dict:
    parsed_topics = parse_pdf_topics_with_ai(pdf_path)
    if not parsed_topics:
        return _empty_parse_result()
    return parsed_topics[0]



def grade_answer_with_ai(question_text: str, correct_answer: str, student_answer: str) -> dict:
    _ensure_gemini()
    model = _build_model()
    prompt = GRADE_PROMPT.format(
        question=question_text,
        correct_answer=correct_answer,
        student_answer=student_answer,
    )
    response = model.generate_content(
        prompt,
        request_options={"timeout": Config.GEMINI_REQUEST_TIMEOUT},
    )

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



def parse_answer_key_document(pdf_path: str) -> dict[int, str]:
    _ensure_gemini()
    pages = extract_pages_from_pdf(pdf_path)
    text = _join_pages(pages)
    model = _build_model()
    prompt = ANSWER_KEY_PROMPT_TEMPLATE + text

    try:
        response = model.generate_content(
            prompt,
            request_options={"timeout": Config.GEMINI_REQUEST_TIMEOUT},
        )
        result = _extract_json_payload(response.text)
    except Exception:
        logger.exception("Failed to parse answer key document")
        return {}

    if not isinstance(result, dict):
        return {}

    answers: dict[int, str] = {}
    for item in result.get("answers", []):
        if not isinstance(item, dict):
            continue
        try:
            number = int(item.get("question_number"))
        except (TypeError, ValueError):
            continue
        answer = str(item.get("answer") or "").strip()
        if answer:
            answers[number] = answer

    return answers
