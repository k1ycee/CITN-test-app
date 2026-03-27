"""
PDF Parser — Extracts exam questions from PDFs using PyMuPDF + Google Gemini AI.

Supports three question types:
  - MCQ (Multiple Choice Questions) with options (a)(b)(c)(d)
  - SAQ (Short Answer Questions) with fill-in-the-blank
  - SEQ (Short Essay Questions)

The AI reads the full text and returns structured JSON with course name,
question types, questions, and matched answers.
"""

import json
import logging
import os

import fitz  # PyMuPDF
import google.generativeai as genai

from config import Config

logger = logging.getLogger(__name__)

# --------------------------------------------------------------------------- #
#  Gemini AI configuration
# --------------------------------------------------------------------------- #

_gemini_configured = False


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


# --------------------------------------------------------------------------- #
#  PDF text extraction
# --------------------------------------------------------------------------- #


def extract_text_from_pdf(pdf_path: str) -> str:
    """Extract all text from a PDF file using PyMuPDF."""
    doc = fitz.open(pdf_path)
    pages = []
    for page_num in range(len(doc)):
        page = doc[page_num]
        text = page.get_text("text")
        pages.append(text)
    doc.close()
    full_text = "\n\n--- PAGE BREAK ---\n\n".join(pages)
    logger.info(
        "Extracted %d characters from %d pages of %s",
        len(full_text),
        len(pages),
        os.path.basename(pdf_path),
    )
    return full_text


# --------------------------------------------------------------------------- #
#  AI-powered parsing
# --------------------------------------------------------------------------- #

PARSE_PROMPT = """You are an expert exam paper parser. Analyze the following text extracted from a university/college exam PDF and return structured JSON.

The PDF may contain one or more of these sections:
1. **MCQ** (Multiple Choice Questions) — numbered questions with options labeled (a), (b), (c), (d). Answers appear in a "SOLUTION TO MCQ" section.
2. **SAQ** (Short Answer Questions) — fill-in-the-blank or short questions. Answers appear in a "SOLUTION TO SAQ" section.
3. **SEQ** (Short Essay-Type Questions) — longer questions requiring brief essay answers. Answers appear in a "SOLUTION TO SECTION B" or "SOLUTION TO SEQ" section.

Return ONLY valid JSON (no markdown, no code fences) in this exact format:
{
  "course_name": "The course/subject name detected from the document (e.g. 'Taxation Law', 'Business Economics')",
  "quiz_title": "A descriptive title for this quiz (e.g. 'Taxation Law Past Questions 2023')",
  "sections": [
    {
      "type": "MCQ",
      "label": "SECTION A: MULTIPLE CHOICE QUESTIONS",
      "questions": [
        {
          "number": 1,
          "text": "The full question text",
          "options": {
            "a": "First option text",
            "b": "Second option text",
            "c": "Third option text",
            "d": "Fourth option text"
          },
          "correct_answer": "A"
        }
      ]
    },
    {
      "type": "SAQ",
      "label": "SHORT ANSWER QUESTIONS",
      "questions": [
        {
          "number": 1,
          "text": "Caveat emptor means -----------------",
          "correct_answer": "Let Buyer beware"
        }
      ]
    },
    {
      "type": "SEQ",
      "label": "SECTION B: SHORT ESSAY-TYPE QUESTIONS",
      "questions": [
        {
          "number": 1,
          "text": "The basic economic problems in socialist economy are resolved by -----------",
          "correct_answer": "Government decision"
        }
      ]
    }
  ]
}

IMPORTANT RULES:
- Match each question to its correct answer from the SOLUTION section.
- For MCQ, the correct_answer should be the UPPERCASE letter (A, B, C, or D).
- For SAQ/SEQ, the correct_answer should be the full answer text from the solutions.
- If a section type is not present in the PDF, omit it from the sections array.
- Preserve the original question numbering.
- Clean up any formatting artifacts from PDF extraction.
- If you cannot detect the course name, use "Unknown Course".
- Include ALL questions — do not skip any.

Here is the extracted PDF text:

"""

GRADE_PROMPT = """You are an exam grading assistant. Compare a student's answer to the correct answer and determine if it is correct.

Question: {question}
Correct Answer: {correct_answer}
Student's Answer: {student_answer}

Evaluate whether the student's answer is semantically equivalent to the correct answer. 
The student doesn't need to use the exact same words — they just need to convey the same meaning/concept.

Return ONLY valid JSON (no markdown, no code fences):
{{
  "is_correct": true or false,
  "status": "correct" or "partially_correct" or "incorrect",
  "explanation": "Brief explanation of why the answer is correct/incorrect"
}}
"""


def parse_pdf_with_ai(pdf_path: str) -> dict:
    """
    Parse a PDF exam paper using PyMuPDF for text extraction
    and Google Gemini AI for intelligent structuring.

    Returns a dict with course_name, quiz_title, and sections
    containing structured questions with answers.
    """
    _ensure_gemini()

    # Step 1: Extract raw text
    raw_text = extract_text_from_pdf(pdf_path)

    if not raw_text.strip():
        raise ValueError("PDF appears to be empty or image-only (no extractable text)")

    # Step 2: Send to Gemini for parsing
    model = genai.GenerativeModel(
        Config.GEMINI_MODEL,
        generation_config=genai.GenerationConfig(
            response_mime_type="application/json",
            temperature=0.1,  # Low temp for accuracy
        ),
    )

    prompt = PARSE_PROMPT + raw_text

    logger.info("Sending %d chars to Gemini for parsing...", len(prompt))
    response = model.generate_content(prompt)

    # Step 3: Parse the JSON response
    try:
        result = json.loads(response.text)
    except json.JSONDecodeError as e:
        logger.error("Gemini returned invalid JSON: %s", response.text[:500])
        raise ValueError(f"AI returned invalid JSON: {e}") from e

    # Validate structure
    if "sections" not in result:
        raise ValueError("AI response missing 'sections' key")

    total_questions = sum(
        len(section.get("questions", []))
        for section in result.get("sections", [])
    )
    logger.info(
        "Parsed: course='%s', title='%s', %d sections, %d total questions",
        result.get("course_name", "Unknown"),
        result.get("quiz_title", "Untitled"),
        len(result.get("sections", [])),
        total_questions,
    )

    return result


def grade_answer_with_ai(
    question_text: str, correct_answer: str, student_answer: str
) -> dict:
    """
    Use Gemini AI to evaluate a student's text answer against the correct answer.
    Used for SAQ and SEQ questions where exact string matching is insufficient.

    Returns dict with is_correct, status, and explanation.
    """
    _ensure_gemini()

    model = genai.GenerativeModel(
        Config.GEMINI_MODEL,
        generation_config=genai.GenerationConfig(
            response_mime_type="application/json",
            temperature=0.1,
        ),
    )

    prompt = GRADE_PROMPT.format(
        question=question_text,
        correct_answer=correct_answer,
        student_answer=student_answer,
    )

    response = model.generate_content(prompt)

    try:
        result = json.loads(response.text)
    except json.JSONDecodeError:
        # Fallback: simple string comparison
        is_match = (
            student_answer.strip().lower() == correct_answer.strip().lower()
        )
        return {
            "is_correct": is_match,
            "status": "correct" if is_match else "incorrect",
            "explanation": "Exact match comparison (AI grading unavailable)",
        }

    return result
