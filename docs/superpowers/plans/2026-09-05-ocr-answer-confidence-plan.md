# OCR Ingestion + AI-Answer Confidence Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Let the app ingest any PDF (scanned or text-based) via OCR fallback, generalize topic segmentation away from a fixed heading format, surface AI-guessed answers with a confidence score, gate a quiz on a dedicated "Add answer key" page only when it has zero explicit answers, and let any AI-guessed answer be corrected inline later — every correction persisted and immediately live for grading.

**Architecture:** Backend (Flask): OCR fallback in `pdf_parser.py`'s page extraction, an AI call replacing regex-based topic segmentation, a `confidence` field added to the existing parse schema, two new `Question` columns plus a new `AnswerEvent` audit table, and three new endpoints (`answer-key/manual`, `answer-key/upload`, `questions/<id>/correct`) that all funnel through one `set_question_answer` helper. Frontend (Flutter): existing models/client/repo/view-model/view layers each gain the new fields and calls; one new dedicated page for filling answer-key gaps; `QuestionCard` gains a confidence badge with an inline correction control.

**Tech Stack:** Flask + SQLAlchemy + SQLite, PyMuPDF, `pytesseract` (new), Google Gemini (`google-generativeai`), pytest (new, first backend test suite); Flutter + Riverpod (`hooks_riverpod`) + Dio + `fpdart` + `file_selector`, `flutter_test`.

**Spec:** `docs/superpowers/specs/2026-09-05-ocr-answer-confidence-design.md`

## Global Constraints

- OCR only runs on pages where `get_text("text").strip()` is under 20 characters — never on pages that already have a usable text layer.
- Confidence is only ever present for `answer_source == "ai_inferred"`; `explicit_solution` is treated as ground truth and never carries a confidence score.
- `needs_answer_key` is computed **per quiz** (true iff the quiz has ≥1 question and zero of them are `explicit_solution`), never aggregated across an upload job.
- Partial gaps (some but not all questions in a quiz lack an explicit answer) never trigger a prompt — the AI fills just those with `ai_inferred` + confidence, correctable later only via the inline-correction path.
- The `answer-key/upload` endpoint has no distinct failure branch — unmatched question numbers simply remain gaps and flow into the normal AI auto-infer path.
- `POST /api/questions/<id>/correct` is not source-gated server-side.
- No authentication changes; no UI to browse the `AnswerEvent` ledger; MCQ/SAQ/SEQ grading comparison logic itself is unchanged.
- The "Add answer key" flow is a **dedicated page**, not a dialog.

---

## Backend

### Task 1: Backend test harness

Nothing in `backend/` has an automated test today. This task adds the pytest scaffolding every later backend task depends on, proven with one smoke test.

**Files:**
- Create: `backend/tests/__init__.py` (empty)
- Create: `backend/tests/conftest.py`
- Create: `backend/tests/test_health.py`
- Modify: `backend/requirements.txt`

**Interfaces:**
- Produces: a pytest fixture `app` (a Flask app, active `app_context`, tables created against a temp SQLite file, dropped/recreated after each test) and a fixture `client` (`app.test_client()`) — every later backend test file uses both.

- [ ] **Step 1: Add pytest to requirements**

Append to `backend/requirements.txt`:
```
pytest==8.3.4
```

- [ ] **Step 2: Write the test harness**

Create `backend/tests/__init__.py` (empty file).

Create `backend/tests/conftest.py`:
```python
import os
import sys
import tempfile

sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))

_TEST_DB_FD, _TEST_DB_PATH = tempfile.mkstemp(suffix=".db")
os.environ["DATABASE_URL"] = f"sqlite:///{_TEST_DB_PATH}"
os.environ.setdefault("GEMINI_API_KEY", "test-key")

import pytest

from app import create_app
from models import db


@pytest.fixture
def app():
    flask_app = create_app()
    with flask_app.app_context():
        db.create_all()
        yield flask_app
        db.session.remove()
        db.drop_all()


@pytest.fixture
def client(app):
    return app.test_client()
```

Create `backend/tests/test_health.py`:
```python
def test_health_check_returns_ok(client):
    response = client.get("/api/health")

    assert response.status_code == 200
    assert response.get_json() == {"status": "ok"}
```

- [ ] **Step 3: Run it to verify it passes**

Run: `cd backend && python -m pytest tests/test_health.py -v`
Expected: `test_health_check_returns_ok PASSED`

- [ ] **Step 4: Commit**

```bash
git add backend/requirements.txt backend/tests/__init__.py backend/tests/conftest.py backend/tests/test_health.py
git commit -m "test: add backend pytest harness"
```

---

### Task 2: OCR fallback for low-text pages

**Files:**
- Modify: `backend/pdf_parser.py`
- Modify: `backend/config.py`
- Modify: `backend/requirements.txt`
- Test: `backend/tests/test_pdf_parser_ocr.py`

**Interfaces:**
- Produces: `pdf_parser._extract_page_text(page) -> tuple[str, bool]`, `pdf_parser._ocr_page(page) -> str`, both used internally by the unchanged-signature `pdf_parser.extract_pages_from_pdf(pdf_path: str) -> list[str]`.

- [ ] **Step 1: Add OCR dependencies and config**

Append to `backend/requirements.txt`:
```
pytesseract==0.3.13
Pillow==11.1.0
```

In `backend/config.py`, add inside the `Config` class, after `GEMINI_REQUEST_TIMEOUT`:
```python
    TESSERACT_CMD = os.getenv("TESSERACT_CMD", "")
```

- [ ] **Step 2: Write the failing tests**

Create `backend/tests/test_pdf_parser_ocr.py`:
```python
class _FakePage:
    def __init__(self, text):
        self._text = text

    def get_text(self, mode):
        return self._text


def test_extract_page_text_uses_ocr_when_text_layer_is_sparse(monkeypatch):
    from pdf_parser import _extract_page_text

    monkeypatch.setattr("pdf_parser._ocr_page", lambda page: "ocr recovered text")

    text, used_ocr = _extract_page_text(_FakePage("  "))

    assert used_ocr is True
    assert text == "ocr recovered text"


def test_extract_page_text_keeps_existing_text_layer(monkeypatch):
    from pdf_parser import _extract_page_text

    def _fail(page):
        raise AssertionError("OCR should not run when a text layer exists")

    monkeypatch.setattr("pdf_parser._ocr_page", _fail)

    text, used_ocr = _extract_page_text(_FakePage("Plenty of real extracted text here."))

    assert used_ocr is False
    assert text == "Plenty of real extracted text here."
```

- [ ] **Step 3: Run to verify it fails**

Run: `cd backend && python -m pytest tests/test_pdf_parser_ocr.py -v`
Expected: FAIL — `ImportError: cannot import name '_extract_page_text'`

- [ ] **Step 4: Implement OCR fallback**

In `backend/pdf_parser.py`, add near the top imports:
```python
import io

import pytesseract
from PIL import Image
```

After the `from config import Config` line, add:
```python
if Config.TESSERACT_CMD:
    pytesseract.pytesseract.tesseract_cmd = Config.TESSERACT_CMD

OCR_MIN_TEXT_LENGTH = 20
```

Replace `extract_pages_from_pdf` with:
```python
def _ocr_page(page) -> str:
    pix = page.get_pixmap(dpi=300)
    image = Image.open(io.BytesIO(pix.tobytes("png")))
    try:
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
```

- [ ] **Step 5: Run to verify it passes**

Run: `cd backend && python -m pytest tests/test_pdf_parser_ocr.py -v`
Expected: 2 passed

- [ ] **Step 6: Commit**

```bash
git add backend/pdf_parser.py backend/config.py backend/requirements.txt backend/tests/test_pdf_parser_ocr.py
git commit -m "feat: OCR fallback for pages with no usable text layer"
```

---

### Task 3: AI-driven topic segmentation

**Files:**
- Modify: `backend/pdf_parser.py`
- Test: `backend/tests/test_pdf_parser_segmentation.py`

**Interfaces:**
- Consumes: `pdf_parser._ensure_gemini()`, `pdf_parser._build_model()`, `pdf_parser._join_pages(pages: list[str]) -> str`, `pdf_parser._extract_json_payload(raw_text: str)` — all pre-existing.
- Produces: `pdf_parser.segment_topics_with_ai(pages: list[str]) -> list[dict]` (each dict: `topic_name: str, start_page: int, end_page: int`, 1-indexed inclusive). `pdf_parser.extract_topic_segments_from_pdf(pdf_path: str) -> list[dict]` keeps its existing signature and return shape (`{"topic_name": str, "text": str}`), used unchanged by `app.py`.

- [ ] **Step 1: Write the failing tests**

Create `backend/tests/test_pdf_parser_segmentation.py`:
```python
import json


def test_segment_topics_with_ai_returns_ai_boundaries(monkeypatch):
    from pdf_parser import segment_topics_with_ai

    monkeypatch.setattr("pdf_parser._ensure_gemini", lambda: None)

    class _FakeResponse:
        text = json.dumps(
            [
                {"topic_name": "Business Law", "start_page": 1, "end_page": 2},
                {"topic_name": "Economics", "start_page": 3, "end_page": 3},
            ]
        )

    class _FakeModel:
        def generate_content(self, prompt, request_options=None):
            return _FakeResponse()

    monkeypatch.setattr("pdf_parser._build_model", lambda: _FakeModel())

    segments = segment_topics_with_ai(["page one", "page two", "page three"])

    assert segments == [
        {"topic_name": "Business Law", "start_page": 1, "end_page": 2},
        {"topic_name": "Economics", "start_page": 3, "end_page": 3},
    ]


def test_segment_topics_with_ai_falls_back_to_empty_on_failure(monkeypatch):
    from pdf_parser import segment_topics_with_ai

    monkeypatch.setattr("pdf_parser._ensure_gemini", lambda: None)

    class _FailingModel:
        def generate_content(self, prompt, request_options=None):
            raise RuntimeError("gemini is down")

    monkeypatch.setattr("pdf_parser._build_model", lambda: _FailingModel())

    assert segment_topics_with_ai(["page one"]) == []


def test_extract_topic_segments_from_pdf_falls_back_to_single_segment(monkeypatch):
    from pdf_parser import extract_topic_segments_from_pdf

    monkeypatch.setattr("pdf_parser.extract_pages_from_pdf", lambda path: ["p1 text", "p2 text"])
    monkeypatch.setattr("pdf_parser.segment_topics_with_ai", lambda pages: [])

    segments = extract_topic_segments_from_pdf("fake.pdf")

    assert len(segments) == 1
    assert segments[0]["topic_name"] == "Unknown Course"
    assert "p1 text" in segments[0]["text"]
    assert "p2 text" in segments[0]["text"]


def test_extract_topic_segments_from_pdf_slices_by_ai_page_ranges(monkeypatch):
    from pdf_parser import extract_topic_segments_from_pdf

    monkeypatch.setattr(
        "pdf_parser.extract_pages_from_pdf", lambda path: ["law text", "law text 2", "econ text"]
    )
    monkeypatch.setattr(
        "pdf_parser.segment_topics_with_ai",
        lambda pages: [
            {"topic_name": "Business Law", "start_page": 1, "end_page": 2},
            {"topic_name": "Economics", "start_page": 3, "end_page": 3},
        ],
    )

    segments = extract_topic_segments_from_pdf("fake.pdf")

    assert [segment["topic_name"] for segment in segments] == ["Business Law", "Economics"]
    assert "law text" in segments[0]["text"]
    assert "law text 2" in segments[0]["text"]
    assert "econ text" not in segments[0]["text"]
    assert "econ text" in segments[1]["text"]
```

- [ ] **Step 2: Run to verify it fails**

Run: `cd backend && python -m pytest tests/test_pdf_parser_segmentation.py -v`
Expected: FAIL — `ImportError: cannot import name 'segment_topics_with_ai'`

- [ ] **Step 3: Implement AI segmentation**

In `backend/pdf_parser.py`, remove the now-unused `TOPIC_HEADING_RE` constant, then replace `extract_topic_segments_from_pdf` with:
```python
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
```

- [ ] **Step 4: Run to verify it passes**

Run: `cd backend && python -m pytest tests/test_pdf_parser_segmentation.py -v`
Expected: 4 passed

- [ ] **Step 5: Commit**

```bash
git add backend/pdf_parser.py backend/tests/test_pdf_parser_segmentation.py
git commit -m "feat: replace regex topic segmentation with an AI-driven pass"
```

---

### Task 4: Confidence in the parse prompt/schema

**Files:**
- Modify: `backend/pdf_parser.py`
- Test: `backend/tests/test_pdf_parser_confidence.py`

**Interfaces:**
- Produces: `_normalize_question(section_type: str, question: dict) -> dict` now includes a `"confidence": int | None` key. `_question_rank(question: dict) -> tuple[int, int, int]` (was `tuple[int, int]`) — later merge logic in `_merge_batch_results` copies `confidence` alongside `correct_answer`/`answer_source` whenever `_question_rank` picks a new winner.

- [ ] **Step 1: Write the failing tests**

Create `backend/tests/test_pdf_parser_confidence.py`:
```python
def test_normalize_question_clamps_confidence_for_ai_inferred():
    from pdf_parser import _normalize_question

    result = _normalize_question(
        "SAQ",
        {
            "number": 3,
            "text": "Explain X",
            "correct_answer": "Because Y",
            "answer_source": "ai_inferred",
            "confidence": 150,
        },
    )

    assert result["answer_source"] == "ai_inferred"
    assert result["confidence"] == 100


def test_normalize_question_has_no_confidence_for_explicit_solution():
    from pdf_parser import _normalize_question

    result = _normalize_question(
        "SAQ",
        {
            "number": 1,
            "text": "Explain X",
            "correct_answer": "Because Y",
            "answer_source": "explicit_solution",
        },
    )

    assert result["confidence"] is None


def test_question_rank_prefers_higher_confidence_among_ai_inferred():
    from pdf_parser import _question_rank

    low_confidence = {"answer_source": "ai_inferred", "correct_answer": "A", "confidence": 40}
    high_confidence = {"answer_source": "ai_inferred", "correct_answer": "A", "confidence": 90}

    assert _question_rank(high_confidence) > _question_rank(low_confidence)


def test_merge_batch_results_carries_confidence_of_winning_answer():
    from pdf_parser import _merge_batch_results

    batch_one = {
        "course_name": "Econ",
        "quiz_title": "Econ Quiz",
        "sections": [
            {
                "type": "SAQ",
                "label": "SAQ",
                "questions": [
                    {
                        "number": 1,
                        "text": "Explain X",
                        "correct_answer": "guess A",
                        "answer_source": "ai_inferred",
                        "confidence": 30,
                    }
                ],
            }
        ],
    }
    batch_two = {
        "course_name": "Econ",
        "quiz_title": "Econ Quiz",
        "sections": [
            {
                "type": "SAQ",
                "label": "SAQ",
                "questions": [
                    {
                        "number": 1,
                        "text": "Explain X",
                        "correct_answer": "guess B",
                        "answer_source": "ai_inferred",
                        "confidence": 85,
                    }
                ],
            }
        ],
    }

    merged = _merge_batch_results([batch_one, batch_two], "Econ")

    question = merged["sections"][0]["questions"][0]
    assert question["correct_answer"] == "guess B"
    assert question["confidence"] == 85
```

- [ ] **Step 2: Run to verify it fails**

Run: `cd backend && python -m pytest tests/test_pdf_parser_confidence.py -v`
Expected: FAIL — `KeyError: 'confidence'` (or assertion failures)

- [ ] **Step 3: Implement confidence handling**

In `backend/pdf_parser.py`, update the JSON schema example inside `PARSE_PROMPT_TEMPLATE` — change the `"answer_source": "explicit_solution"` line to also show confidence, and add a rule. Replace:
```python
          "correct_answer": "A",
          "answer_source": "explicit_solution"
```
with:
```python
          "correct_answer": "A",
          "answer_source": "explicit_solution",
          "confidence": 87
```
and append to the `Rules:` list (after the existing `answer_source` rules):
```python
- When answer_source is ai_inferred, include an integer "confidence" from 0-100 estimating how sure you are. Omit or zero it for explicit_solution.
- Always provide your best-effort correct_answer and set answer_source to ai_inferred rather than unknown, unless the question truly cannot be answered from the given text (e.g. it depends on an image or table that isn't present).
```

Replace `_normalize_question`:
```python
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
```

Replace `_question_rank`:
```python
def _question_rank(question: dict) -> tuple[int, int, int]:
    source_rank = {
        "explicit_solution": 2,
        "ai_inferred": 1,
        "unknown": 0,
    }.get(question.get("answer_source", "unknown"), 0)
    answer_rank = 1 if question.get("correct_answer") else 0
    confidence_rank = question.get("confidence") or 0
    return source_rank, answer_rank, confidence_rank
```

In `_merge_batch_results`, in the block that updates the winning answer, add the confidence copy:
```python
                if _question_rank(normalized) > _question_rank(existing):
                    existing["correct_answer"] = normalized.get("correct_answer", "")
                    existing["answer_source"] = normalized.get("answer_source", "unknown")
                    existing["confidence"] = normalized.get("confidence")
```

- [ ] **Step 4: Run to verify it passes**

Run: `cd backend && python -m pytest tests/test_pdf_parser_confidence.py -v`
Expected: 4 passed

- [ ] **Step 5: Commit**

```bash
git add backend/pdf_parser.py backend/tests/test_pdf_parser_confidence.py
git commit -m "feat: add confidence scoring to AI-inferred answers"
```

---

### Task 5: `Question`/`AnswerEvent` schema and `set_question_answer` helper

**Files:**
- Modify: `backend/models.py`
- Test: `backend/tests/test_answer_events.py`

**Interfaces:**
- Produces: `Question.answer_source: str`, `Question.confidence: int | None` columns; `AnswerEvent` model (`question_id, previous_answer, previous_source, new_answer, new_source, confidence_at_time, created_at`); `models.set_question_answer(question: Question, new_answer: str, new_source: str) -> AnswerEvent`.

- [ ] **Step 1: Write the failing test**

Create `backend/tests/test_answer_events.py`:
```python
def test_set_question_answer_updates_question_and_logs_event(app):
    from models import AnswerEvent, Course, Question, Quiz, db, set_question_answer

    course = Course(name="Test Course")
    db.session.add(course)
    db.session.flush()
    quiz = Quiz(course=course, title="Quiz", pdf_filename="f.pdf")
    db.session.add(quiz)
    db.session.flush()
    question = Question(
        quiz=quiz,
        question_type="SAQ",
        question_number=1,
        question_text="Explain X",
        correct_answer="AI guess",
        answer_source="ai_inferred",
        confidence=55,
    )
    db.session.add(question)
    db.session.commit()

    event = set_question_answer(question, "Corrected answer", "user_corrected")
    db.session.commit()

    assert question.correct_answer == "Corrected answer"
    assert question.answer_source == "user_corrected"
    assert question.confidence is None
    assert event.previous_answer == "AI guess"
    assert event.previous_source == "ai_inferred"
    assert event.confidence_at_time == 55
    assert event.new_answer == "Corrected answer"
    assert AnswerEvent.query.filter_by(question_id=question.id).count() == 1
```

- [ ] **Step 2: Run to verify it fails**

Run: `cd backend && python -m pytest tests/test_answer_events.py -v`
Expected: FAIL — `ImportError: cannot import name 'set_question_answer'`

- [ ] **Step 3: Implement the schema and helper**

In `backend/models.py`, in the `Question` class, replace:
```python
    correct_answer = db.Column(db.Text, nullable=False)

    submission_answers = db.relationship(
        "SubmissionAnswer",
        backref="question",
        lazy=True,
        cascade="all, delete-orphan",
    )
```
with:
```python
    correct_answer = db.Column(db.Text, nullable=False)
    answer_source = db.Column(db.String(20), nullable=False, default="unknown")
    confidence = db.Column(db.Integer, nullable=True)

    submission_answers = db.relationship(
        "SubmissionAnswer",
        backref="question",
        lazy=True,
        cascade="all, delete-orphan",
    )
    answer_events = db.relationship(
        "AnswerEvent",
        backref="question",
        lazy=True,
        cascade="all, delete-orphan",
    )
```

In `Question.to_dict`, replace:
```python
    def to_dict(self, include_answer=False):
        data = {
            "id": self.id,
            "quiz_id": self.quiz_id,
            "question_type": self.question_type,
            "section_label": self.section_label,
            "question_number": self.question_number,
            "question_text": self.question_text,
        }
```
with:
```python
    def to_dict(self, include_answer=False):
        data = {
            "id": self.id,
            "quiz_id": self.quiz_id,
            "question_type": self.question_type,
            "section_label": self.section_label,
            "question_number": self.question_number,
            "question_text": self.question_text,
            "answer_source": self.answer_source,
            "confidence": self.confidence,
        }
```

At the end of `backend/models.py`, add:
```python
class AnswerEvent(db.Model):
    """A record of a question's correct answer being set or corrected."""

    __tablename__ = "answer_events"

    id = db.Column(db.Integer, primary_key=True)
    question_id = db.Column(db.Integer, db.ForeignKey("questions.id"), nullable=False)
    previous_answer = db.Column(db.Text, nullable=False)
    previous_source = db.Column(db.String(20), nullable=False)
    new_answer = db.Column(db.Text, nullable=False)
    new_source = db.Column(db.String(20), nullable=False)
    confidence_at_time = db.Column(db.Integer, nullable=True)
    created_at = db.Column(db.DateTime, default=lambda: datetime.now(timezone.utc))

    def to_dict(self):
        return {
            "id": self.id,
            "question_id": self.question_id,
            "previous_answer": self.previous_answer,
            "previous_source": self.previous_source,
            "new_answer": self.new_answer,
            "new_source": self.new_source,
            "confidence_at_time": self.confidence_at_time,
            "created_at": self.created_at.isoformat(),
        }


def set_question_answer(question: Question, new_answer: str, new_source: str) -> AnswerEvent:
    """Updates a question's live correct answer and logs the change for future reference."""
    event = AnswerEvent(
        question=question,
        previous_answer=question.correct_answer,
        previous_source=question.answer_source,
        new_answer=new_answer,
        new_source=new_source,
        confidence_at_time=question.confidence,
    )
    question.correct_answer = new_answer
    question.answer_source = new_source
    question.confidence = None
    db.session.add(event)
    db.session.add(question)
    return event
```

Delete `backend/instance/quiz.db` (this is a dev-only SQLite file with no migration tooling; the new columns/table require a fresh schema — `db.create_all()` won't alter an existing table):
```bash
rm -f backend/instance/quiz.db
```

- [ ] **Step 4: Run to verify it passes**

Run: `cd backend && python -m pytest tests/test_answer_events.py -v`
Expected: 1 passed

- [ ] **Step 5: Commit**

```bash
git add backend/models.py
git commit -m "feat: add Question answer metadata and AnswerEvent audit log"
```

---

### Task 6: `Quiz.needs_answer_key` and persisting parse metadata

**Files:**
- Modify: `backend/models.py`
- Modify: `backend/app.py`
- Test: `backend/tests/test_needs_answer_key.py`

**Interfaces:**
- Consumes: `Question` columns from Task 5.
- Produces: `Quiz.needs_answer_key` (property, `bool`), included in `Quiz.to_dict()`. `app._store_parsed_quiz` now persists `answer_source`/`confidence` from parsed question data instead of discarding them.

- [ ] **Step 1: Write the failing tests**

Create `backend/tests/test_needs_answer_key.py`:
```python
def _make_quiz(db, Course, Quiz):
    course = Course(name="Test Course")
    db.session.add(course)
    db.session.flush()
    quiz = Quiz(course=course, title="Quiz", pdf_filename="f.pdf")
    db.session.add(quiz)
    db.session.flush()
    return quiz


def test_needs_answer_key_true_when_no_explicit_answers(app):
    from models import Course, Question, Quiz, db

    quiz = _make_quiz(db, Course, Quiz)
    db.session.add(
        Question(
            quiz=quiz,
            question_type="SAQ",
            question_number=1,
            question_text="Q1",
            correct_answer="guess",
            answer_source="ai_inferred",
            confidence=40,
        )
    )
    db.session.commit()

    assert quiz.needs_answer_key is True
    assert quiz.to_dict()["needs_answer_key"] is True


def test_needs_answer_key_false_when_any_explicit_answer_present(app):
    from models import Course, Question, Quiz, db

    quiz = _make_quiz(db, Course, Quiz)
    db.session.add(
        Question(
            quiz=quiz,
            question_type="MCQ",
            question_number=1,
            question_text="Q1",
            correct_answer="A",
            answer_source="explicit_solution",
        )
    )
    db.session.add(
        Question(
            quiz=quiz,
            question_type="SAQ",
            question_number=2,
            question_text="Q2",
            correct_answer="guess",
            answer_source="ai_inferred",
            confidence=30,
        )
    )
    db.session.commit()

    assert quiz.needs_answer_key is False


def test_needs_answer_key_false_when_quiz_has_no_questions(app):
    from models import Course, Quiz, db

    quiz = _make_quiz(db, Course, Quiz)
    db.session.commit()

    assert quiz.needs_answer_key is False
```

- [ ] **Step 2: Run to verify it fails**

Run: `cd backend && python -m pytest tests/test_needs_answer_key.py -v`
Expected: FAIL — `AttributeError: 'Quiz' object has no attribute 'needs_answer_key'`

- [ ] **Step 3: Implement**

In `backend/models.py`, in `Quiz.to_dict`, add `"needs_answer_key": self.needs_answer_key,` right after `"submission_count": len(self.submissions),`, and add this property to the `Quiz` class (after `to_dict`):
```python
    @property
    def needs_answer_key(self) -> bool:
        if not self.questions:
            return False
        return not any(question.answer_source == "explicit_solution" for question in self.questions)
```

In `backend/app.py`, in `_store_parsed_quiz`, replace:
```python
            question = Question(
                quiz=quiz,
                question_type=question_type,
                section_label=label,
                question_number=question_number,
                question_text=question_text,
                option_a=options.get("a"),
                option_b=options.get("b"),
                option_c=options.get("c"),
                option_d=options.get("d"),
                correct_answer=str(question_data.get("correct_answer", "")).strip(),
            )
```
with:
```python
            question = Question(
                quiz=quiz,
                question_type=question_type,
                section_label=label,
                question_number=question_number,
                question_text=question_text,
                option_a=options.get("a"),
                option_b=options.get("b"),
                option_c=options.get("c"),
                option_d=options.get("d"),
                correct_answer=str(question_data.get("correct_answer", "")).strip(),
                answer_source=str(question_data.get("answer_source") or "unknown").strip() or "unknown",
                confidence=question_data.get("confidence"),
            )
```

- [ ] **Step 4: Run to verify it passes**

Run: `cd backend && python -m pytest tests/test_needs_answer_key.py -v`
Expected: 3 passed

- [ ] **Step 5: Commit**

```bash
git add backend/models.py backend/app.py backend/tests/test_needs_answer_key.py
git commit -m "feat: compute needs_answer_key and persist parse metadata"
```

---

### Task 7: `POST /api/quizzes/<id>/answer-key/manual`

**Files:**
- Modify: `backend/app.py`
- Test: `backend/tests/test_answer_key_manual.py`

**Interfaces:**
- Consumes: `models.set_question_answer` (Task 5).
- Produces: `POST /api/quizzes/<id>/answer-key/manual` → `{"applied": int, "quiz": <Quiz.to_dict(include_questions=True)>}`.

- [ ] **Step 1: Write the failing test**

Create `backend/tests/test_answer_key_manual.py`:
```python
def _create_quiz_with_gap():
    from models import Course, Question, Quiz, db

    course = Course(name="Test Course")
    db.session.add(course)
    db.session.flush()
    quiz = Quiz(course=course, title="Quiz", pdf_filename="f.pdf")
    db.session.add(quiz)
    db.session.flush()
    db.session.add(
        Question(
            quiz=quiz,
            question_type="SAQ",
            question_number=1,
            question_text="Q1",
            correct_answer="",
            answer_source="unknown",
        )
    )
    db.session.commit()
    return quiz.id


def test_manual_answer_key_updates_question(app, client):
    quiz_id = _create_quiz_with_gap()

    response = client.post(
        f"/api/quizzes/{quiz_id}/answer-key/manual",
        json={"answers": [{"question_number": 1, "answer": "42"}]},
    )

    assert response.status_code == 200
    body = response.get_json()
    assert body["applied"] == 1
    assert body["quiz"]["needs_answer_key"] is False
    assert body["quiz"]["questions"][0]["answer_source"] == "user_provided"


def test_manual_answer_key_ignores_unknown_question_numbers(app, client):
    quiz_id = _create_quiz_with_gap()

    response = client.post(
        f"/api/quizzes/{quiz_id}/answer-key/manual",
        json={"answers": [{"question_number": 99, "answer": "42"}]},
    )

    assert response.status_code == 200
    assert response.get_json()["applied"] == 0
```

- [ ] **Step 2: Run to verify it fails**

Run: `cd backend && python -m pytest tests/test_answer_key_manual.py -v`
Expected: FAIL — 404 (route does not exist)

- [ ] **Step 3: Implement the endpoint**

In `backend/app.py`, change the import from `models` to include `set_question_answer`:
```python
from models import Course, Question, Quiz, Submission, SubmissionAnswer, db, set_question_answer
```

Add the route, right after `submit_single_question`:
```python
    @app.post("/api/quizzes/<int:quiz_id>/answer-key/manual")
    def submit_manual_answer_key(quiz_id: int):
        quiz = Quiz.query.get_or_404(quiz_id)
        payload = request.get_json(silent=True) or {}
        answers_payload = payload.get("answers")

        if not isinstance(answers_payload, list):
            return jsonify({"error": "'answers' must be a list"}), 400

        questions_by_number = {q.question_number: q for q in quiz.questions}
        applied = 0
        for item in answers_payload:
            question_number = item.get("question_number")
            answer = str(item.get("answer", "")).strip()
            if question_number is None or not answer:
                continue
            question = questions_by_number.get(int(question_number))
            if question is None:
                continue
            set_question_answer(question, answer, "user_provided")
            applied += 1

        db.session.commit()
        return jsonify({"applied": applied, "quiz": quiz.to_dict(include_questions=True)})
```

- [ ] **Step 4: Run to verify it passes**

Run: `cd backend && python -m pytest tests/test_answer_key_manual.py -v`
Expected: 2 passed

- [ ] **Step 5: Commit**

```bash
git add backend/app.py backend/tests/test_answer_key_manual.py
git commit -m "feat: add manual answer-key submission endpoint"
```

---

### Task 8: Answer-key document upload + matching

**Files:**
- Modify: `backend/pdf_parser.py`
- Modify: `backend/app.py`
- Test: `backend/tests/test_pdf_parser_answer_key.py`
- Test: `backend/tests/test_answer_key_upload.py`

**Interfaces:**
- Produces: `pdf_parser.parse_answer_key_document(pdf_path: str) -> dict[int, str]` (question number → answer text). `POST /api/quizzes/<id>/answer-key/upload` → `{"applied": int, "unmatched": int, "quiz": <Quiz.to_dict(include_questions=True)>}`.

- [ ] **Step 1: Write the failing parser test**

Create `backend/tests/test_pdf_parser_answer_key.py`:
```python
import json


def test_parse_answer_key_document_extracts_answers_by_number(monkeypatch):
    from pdf_parser import parse_answer_key_document

    monkeypatch.setattr("pdf_parser._ensure_gemini", lambda: None)
    monkeypatch.setattr(
        "pdf_parser.extract_pages_from_pdf", lambda path: ["1. B\n2. Supply and demand"]
    )

    class _FakeResponse:
        text = json.dumps(
            {
                "answers": [
                    {"question_number": 1, "answer": "B"},
                    {"question_number": 2, "answer": "Supply and demand"},
                ]
            }
        )

    class _FakeModel:
        def generate_content(self, prompt, request_options=None):
            return _FakeResponse()

    monkeypatch.setattr("pdf_parser._build_model", lambda: _FakeModel())

    assert parse_answer_key_document("fake.pdf") == {1: "B", 2: "Supply and demand"}


def test_parse_answer_key_document_returns_empty_on_failure(monkeypatch):
    from pdf_parser import parse_answer_key_document

    monkeypatch.setattr("pdf_parser._ensure_gemini", lambda: None)
    monkeypatch.setattr("pdf_parser.extract_pages_from_pdf", lambda path: ["garbled ocr text"])

    class _FailingModel:
        def generate_content(self, prompt, request_options=None):
            raise RuntimeError("gemini down")

    monkeypatch.setattr("pdf_parser._build_model", lambda: _FailingModel())

    assert parse_answer_key_document("fake.pdf") == {}
```

- [ ] **Step 2: Run to verify it fails**

Run: `cd backend && python -m pytest tests/test_pdf_parser_answer_key.py -v`
Expected: FAIL — `ImportError: cannot import name 'parse_answer_key_document'`

- [ ] **Step 3: Implement the parser function**

In `backend/pdf_parser.py`, add:
```python
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
```

- [ ] **Step 4: Run to verify the parser test passes**

Run: `cd backend && python -m pytest tests/test_pdf_parser_answer_key.py -v`
Expected: 2 passed

- [ ] **Step 5: Write the failing endpoint test**

Create `backend/tests/test_answer_key_upload.py`:
```python
def _create_quiz_with_gap():
    from models import Course, Question, Quiz, db

    course = Course(name="Test Course")
    db.session.add(course)
    db.session.flush()
    quiz = Quiz(course=course, title="Quiz", pdf_filename="f.pdf")
    db.session.add(quiz)
    db.session.flush()
    db.session.add(
        Question(
            quiz=quiz,
            question_type="SAQ",
            question_number=1,
            question_text="Q1",
            correct_answer="",
            answer_source="unknown",
        )
    )
    db.session.commit()
    return quiz.id


def test_upload_answer_key_matches_by_question_number(app, client, monkeypatch, tmp_path):
    quiz_id = _create_quiz_with_gap()
    monkeypatch.setattr("app.parse_answer_key_document", lambda path: {1: "42"})

    pdf_path = tmp_path / "key.pdf"
    pdf_path.write_bytes(b"%PDF-1.4 fake content")

    with pdf_path.open("rb") as f:
        response = client.post(
            f"/api/quizzes/{quiz_id}/answer-key/upload",
            data={"file": (f, "key.pdf")},
            content_type="multipart/form-data",
        )

    assert response.status_code == 200
    body = response.get_json()
    assert body["applied"] == 1
    assert body["unmatched"] == 0
    assert body["quiz"]["needs_answer_key"] is False


def test_upload_answer_key_leaves_unmatched_questions_as_gaps(app, client, monkeypatch, tmp_path):
    quiz_id = _create_quiz_with_gap()
    monkeypatch.setattr("app.parse_answer_key_document", lambda path: {})

    pdf_path = tmp_path / "key.pdf"
    pdf_path.write_bytes(b"%PDF-1.4 fake content")

    with pdf_path.open("rb") as f:
        response = client.post(
            f"/api/quizzes/{quiz_id}/answer-key/upload",
            data={"file": (f, "key.pdf")},
            content_type="multipart/form-data",
        )

    assert response.status_code == 200
    body = response.get_json()
    assert body["applied"] == 0
    assert body["unmatched"] == 1
    assert body["quiz"]["needs_answer_key"] is True
```

- [ ] **Step 6: Run to verify it fails**

Run: `cd backend && python -m pytest tests/test_answer_key_upload.py -v`
Expected: FAIL — 404 (route does not exist)

- [ ] **Step 7: Implement the endpoint**

In `backend/app.py`, update the `pdf_parser` import to include `parse_answer_key_document`:
```python
from pdf_parser import (
    extract_topic_segments_from_pdf,
    grade_answer_with_ai,
    parse_answer_key_document,
    parse_pdf_with_ai,
    parse_topic_with_ai,
)
```

Add the route, after `submit_manual_answer_key`:
```python
    @app.post("/api/quizzes/<int:quiz_id>/answer-key/upload")
    def upload_answer_key(quiz_id: int):
        quiz = Quiz.query.get_or_404(quiz_id)

        if "file" not in request.files:
            return jsonify({"error": "Missing uploaded file under 'file'"}), 400

        file = request.files["file"]
        if not file or file.filename == "":
            return jsonify({"error": "No file selected"}), 400

        if not _allowed_file(file.filename):
            return jsonify({"error": "Only PDF uploads are supported"}), 400

        filename = secure_filename(file.filename)
        destination = Path(app.config["UPLOAD_FOLDER"]) / f"answerkey-{uuid4().hex}-{filename}"
        file.save(destination)

        try:
            answers_by_number = parse_answer_key_document(str(destination))
        except Exception as exc:  # pragma: no cover
            logger.exception("Failed to parse answer key document")
            return jsonify({"error": str(exc)}), 500

        applied = 0
        for question in quiz.questions:
            answer = answers_by_number.get(question.question_number)
            if answer:
                set_question_answer(question, answer, "user_provided")
                applied += 1

        db.session.commit()
        return jsonify(
            {
                "applied": applied,
                "unmatched": len(quiz.questions) - applied,
                "quiz": quiz.to_dict(include_questions=True),
            }
        )
```

- [ ] **Step 8: Run to verify it passes**

Run: `cd backend && python -m pytest tests/test_answer_key_upload.py -v`
Expected: 2 passed

- [ ] **Step 9: Commit**

```bash
git add backend/pdf_parser.py backend/app.py backend/tests/test_pdf_parser_answer_key.py backend/tests/test_answer_key_upload.py
git commit -m "feat: add answer-key document upload with number-matching"
```

---

### Task 9: Inline correction endpoint + result serialization

**Files:**
- Modify: `backend/app.py`
- Test: `backend/tests/test_correct_question.py`

**Interfaces:**
- Produces: `POST /api/questions/<id>/correct` → `{"quiz_id": int, "question_id": int, "correct_answer": str, "answer_source": str, "confidence": int|None}`. `_build_question_result` now also includes `answer_source`/`confidence` (used by both submit endpoints).

- [ ] **Step 1: Write the failing test**

Create `backend/tests/test_correct_question.py`:
```python
def test_correct_question_answer_updates_source_and_logs_event(app, client):
    from models import AnswerEvent, Course, Question, Quiz, db

    course = Course(name="Test Course")
    db.session.add(course)
    db.session.flush()
    quiz = Quiz(course=course, title="Quiz", pdf_filename="f.pdf")
    db.session.add(quiz)
    db.session.flush()
    question = Question(
        quiz=quiz,
        question_type="SAQ",
        question_number=1,
        question_text="Q1",
        correct_answer="AI guess",
        answer_source="ai_inferred",
        confidence=60,
    )
    db.session.add(question)
    db.session.commit()

    response = client.post(f"/api/questions/{question.id}/correct", json={"answer": "Real answer"})

    assert response.status_code == 200
    body = response.get_json()
    assert body["answer_source"] == "user_corrected"
    assert body["correct_answer"] == "Real answer"
    assert body["confidence"] is None
    assert AnswerEvent.query.filter_by(question_id=question.id).count() == 1


def test_correct_question_answer_rejects_empty_answer(app, client):
    from models import Course, Question, Quiz, db

    course = Course(name="Test Course")
    db.session.add(course)
    db.session.flush()
    quiz = Quiz(course=course, title="Quiz", pdf_filename="f.pdf")
    db.session.add(quiz)
    db.session.flush()
    question = Question(
        quiz=quiz,
        question_type="SAQ",
        question_number=1,
        question_text="Q1",
        correct_answer="AI guess",
        answer_source="ai_inferred",
        confidence=60,
    )
    db.session.add(question)
    db.session.commit()

    response = client.post(f"/api/questions/{question.id}/correct", json={"answer": "   "})

    assert response.status_code == 400
```

- [ ] **Step 2: Run to verify it fails**

Run: `cd backend && python -m pytest tests/test_correct_question.py -v`
Expected: FAIL — 404 (route does not exist)

- [ ] **Step 3: Implement**

In `backend/app.py`, add the route right after `upload_answer_key`:
```python
    @app.post("/api/questions/<int:question_id>/correct")
    def correct_question_answer(question_id: int):
        question = Question.query.get_or_404(question_id)
        payload = request.get_json(silent=True) or {}
        answer = str(payload.get("answer", "")).strip()

        if not answer:
            return jsonify({"error": "'answer' must not be empty"}), 400

        set_question_answer(question, answer, "user_corrected")
        db.session.commit()

        return jsonify(
            {
                "quiz_id": question.quiz_id,
                "question_id": question.id,
                "correct_answer": question.correct_answer,
                "answer_source": question.answer_source,
                "confidence": question.confidence,
            }
        )
```

Update `_build_question_result` to include the new fields — replace:
```python
        "is_correct": grading["is_correct"],
        "status": grading["status"],
        "explanation": grading.get("explanation", ""),
    }
```
with:
```python
        "is_correct": grading["is_correct"],
        "status": grading["status"],
        "explanation": grading.get("explanation", ""),
        "answer_source": question.answer_source,
        "confidence": question.confidence,
    }
```

- [ ] **Step 4: Run to verify it passes**

Run: `cd backend && python -m pytest tests/test_correct_question.py -v`
Expected: 2 passed

- [ ] **Step 5: Run the full backend suite**

Run: `cd backend && python -m pytest -v`
Expected: all tests from Tasks 1-9 pass

- [ ] **Step 6: Commit**

```bash
git add backend/app.py backend/tests/test_correct_question.py
git commit -m "feat: add inline answer-correction endpoint"
```

---

### Task 10: Deployment/docs updates for the new system dependency

**Files:**
- Modify: `backend/Dockerfile`
- Modify: `backend/start-backend-windows.ps1`
- Modify: `README.md`

**Interfaces:** none (docs/deploy only, no automated test — this is a config/documentation task).

- [ ] **Step 1: Install tesseract in the Docker image**

In `backend/Dockerfile`, after `WORKDIR /app` and before `COPY requirements.txt ./`, add:
```dockerfile
RUN apt-get update \
    && apt-get install -y --no-install-recommends tesseract-ocr \
    && rm -rf /var/lib/apt/lists/*
```

- [ ] **Step 2: Warn on Windows when tesseract is missing**

In `backend/start-backend-windows.ps1`, right after the `Write-Step "Using Python command: $python"` line, add:
```powershell
if (-not (Get-Command "tesseract" -ErrorAction SilentlyContinue)) {
    Write-Host "WARNING: tesseract was not found on PATH. Scanned-PDF OCR will fail until it's installed (e.g. via 'choco install tesseract') and PATH is updated, or TESSERACT_CMD is set in .env." -ForegroundColor Yellow
}
```

- [ ] **Step 3: Update README**

In `README.md`, under `## Backend Setup`, after the `cp .env.example .env` line, add a new subsection:
```markdown
### OCR system dependency

Scanned/image-only PDFs are read via Tesseract OCR. Install the `tesseract-ocr` binary separately:

- macOS: `brew install tesseract`
- Debian/Ubuntu: `sudo apt-get install tesseract-ocr`
- Windows: install via `choco install tesseract` or the [official installer](https://github.com/UB-Mannheim/tesseract/wiki), then either add it to PATH or set `TESSERACT_CMD` in `.env` to its full path.
```

In `README.md`, under `## API Endpoints`, add:
```markdown
- `POST /api/quizzes/<id>/answer-key/manual`
- `POST /api/quizzes/<id>/answer-key/upload`
- `POST /api/questions/<id>/correct`
```

Under `## Notes`, add:
```markdown
- Pages with no extractable text layer fall back to Tesseract OCR.
- Topic segmentation and answer-key extraction both run as Gemini calls rather than fixed-format parsing.
- Backend tests: `cd backend && python -m pytest`.
```

- [ ] **Step 4: Commit**

```bash
git add backend/Dockerfile backend/start-backend-windows.ps1 README.md
git commit -m "docs: document the tesseract OCR system dependency and new endpoints"
```

---

## Frontend

### Task 11: Wire new backend fields into existing Dart models

**Files:**
- Modify: `lib/core/api/models/question_item_model.dart`
- Modify: `lib/core/api/models/quiz_summary_model.dart`
- Modify: `lib/core/api/models/quiz_detail_model.dart`
- Modify: `lib/core/api/models/question_check_result_model.dart`
- Test: `test/core/api/models/question_item_model_test.dart`
- Test: `test/core/api/models/quiz_summary_model_test.dart`

**Interfaces:**
- Produces: `QuestionItemModel.answerSource: String`, `QuestionItemModel.confidence: int?`; `QuizSummaryModel.needsAnswerKey: bool`; `QuizDetailModel.needsAnswerKey: bool`; `QuestionCheckResultModel.answerSource: String`, `QuestionCheckResultModel.confidence: int?`.

- [ ] **Step 1: Write the failing tests**

Create `test/core/api/models/question_item_model_test.dart`:
```dart
import "package:flutter_test/flutter_test.dart";
import "package:test_app/core/api/models/question_item_model.dart";

void main() {
  test("parses answer_source and confidence from json", () {
    final question = QuestionItemModel.fromJson({
      "id": 1,
      "question_type": "SAQ",
      "question_number": 1,
      "question_text": "Explain X",
      "options": null,
      "answer_source": "ai_inferred",
      "confidence": 72,
    });

    expect(question.answerSource, "ai_inferred");
    expect(question.confidence, 72);
  });

  test("defaults answer_source to unknown when absent", () {
    final question = QuestionItemModel.fromJson({
      "id": 1,
      "question_type": "SAQ",
      "question_number": 1,
      "question_text": "Explain X",
      "options": null,
    });

    expect(question.answerSource, "unknown");
    expect(question.confidence, isNull);
  });
}
```

Create `test/core/api/models/quiz_summary_model_test.dart`:
```dart
import "package:flutter_test/flutter_test.dart";
import "package:test_app/core/api/models/quiz_summary_model.dart";

void main() {
  test("parses needs_answer_key from json", () {
    final quiz = QuizSummaryModel.fromJson({
      "id": 1,
      "title": "Quiz",
      "course_name": "Course",
      "question_count": 3,
      "needs_answer_key": true,
    });

    expect(quiz.needsAnswerKey, isTrue);
  });

  test("defaults needs_answer_key to false when absent", () {
    final quiz = QuizSummaryModel.fromJson({
      "id": 1,
      "title": "Quiz",
      "course_name": "Course",
      "question_count": 3,
    });

    expect(quiz.needsAnswerKey, isFalse);
  });
}
```

- [ ] **Step 2: Run to verify it fails**

Run: `flutter test test/core/api/models/question_item_model_test.dart test/core/api/models/quiz_summary_model_test.dart`
Expected: FAIL — no `answerSource`/`needsAnswerKey` getters

- [ ] **Step 3: Implement the model changes**

Replace `lib/core/api/models/question_item_model.dart`:
```dart
class QuestionItemModel {
  QuestionItemModel({
    required this.id,
    required this.questionType,
    required this.questionNumber,
    required this.questionText,
    required this.options,
    required this.answerSource,
    required this.confidence,
  });

  final int id;
  final String questionType;
  final int questionNumber;
  final String questionText;
  final Map<String, String?>? options;
  final String answerSource;
  final int? confidence;

  factory QuestionItemModel.fromJson(Map<String, dynamic> json) {
    final rawOptions = json["options"] as Map<String, dynamic>?;
    return QuestionItemModel(
      id: json["id"] as int,
      questionType: json["question_type"] as String? ?? "SAQ",
      questionNumber: json["question_number"] as int? ?? 0,
      questionText: json["question_text"] as String? ?? "",
      options: rawOptions?.map((key, value) => MapEntry(key, value as String?)),
      answerSource: json["answer_source"] as String? ?? "unknown",
      confidence: json["confidence"] as int?,
    );
  }
}
```

In `lib/core/api/models/quiz_summary_model.dart`, replace the whole class:
```dart
class QuizSummaryModel {
  QuizSummaryModel({
    required this.id,
    required this.title,
    required this.courseName,
    required this.questionCount,
    required this.needsAnswerKey,
  });

  final int id;
  final String title;
  final String courseName;
  final int questionCount;
  final bool needsAnswerKey;

  factory QuizSummaryModel.fromJson(Map<String, dynamic> json) {
    return QuizSummaryModel(
      id: json["id"] as int,
      title: json["title"] as String? ?? "Untitled Quiz",
      courseName: json["course_name"] as String? ?? "Unknown Course",
      questionCount: json["question_count"] as int? ?? 0,
      needsAnswerKey: json["needs_answer_key"] as bool? ?? false,
    );
  }
}
```

In `lib/core/api/models/quiz_detail_model.dart`, replace the whole class:
```dart
import "question_item_model.dart";

class QuizDetailModel {
  QuizDetailModel({
    required this.id,
    required this.title,
    required this.courseName,
    required this.questionCount,
    required this.needsAnswerKey,
    required this.questions,
  });

  final int id;
  final String title;
  final String courseName;
  final int questionCount;
  final bool needsAnswerKey;
  final List<QuestionItemModel> questions;

  factory QuizDetailModel.fromJson(Map<String, dynamic> json) {
    final questionsJson = json["questions"] as List<dynamic>? ?? <dynamic>[];
    return QuizDetailModel(
      id: json["id"] as int,
      title: json["title"] as String? ?? "Untitled Quiz",
      courseName: json["course_name"] as String? ?? "Unknown Course",
      questionCount: json["question_count"] as int? ?? 0,
      needsAnswerKey: json["needs_answer_key"] as bool? ?? false,
      questions: questionsJson
          .map((item) => QuestionItemModel.fromJson(item as Map<String, dynamic>))
          .toList(),
    );
  }
}
```

In `lib/core/api/models/question_check_result_model.dart`, replace the whole class:
```dart
class QuestionCheckResultModel {
  QuestionCheckResultModel({
    required this.questionId,
    required this.questionNumber,
    required this.questionType,
    required this.questionText,
    required this.studentAnswer,
    required this.correctAnswer,
    required this.hasCorrectAnswer,
    required this.isCorrect,
    required this.status,
    required this.explanation,
    required this.answerSource,
    required this.confidence,
  });

  final int questionId;
  final int questionNumber;
  final String questionType;
  final String questionText;
  final String studentAnswer;
  final String correctAnswer;
  final bool hasCorrectAnswer;
  final bool isCorrect;
  final String status;
  final String explanation;
  final String answerSource;
  final int? confidence;

  factory QuestionCheckResultModel.fromJson(Map<String, dynamic> json) {
    return QuestionCheckResultModel(
      questionId: json["question_id"] as int? ?? 0,
      questionNumber: json["question_number"] as int? ?? 0,
      questionType: json["question_type"] as String? ?? "SAQ",
      questionText: json["question_text"] as String? ?? "",
      studentAnswer: json["student_answer"] as String? ?? "",
      correctAnswer: json["correct_answer"] as String? ?? "",
      hasCorrectAnswer: json["has_correct_answer"] as bool? ?? false,
      isCorrect: json["is_correct"] as bool? ?? false,
      status: json["status"] as String? ?? "incorrect",
      explanation: json["explanation"] as String? ?? "",
      answerSource: json["answer_source"] as String? ?? "unknown",
      confidence: json["confidence"] as int?,
    );
  }
}
```

- [ ] **Step 4: Run to verify it passes**

Run: `flutter test test/core/api/models/question_item_model_test.dart test/core/api/models/quiz_summary_model_test.dart`
Expected: 4 passed

- [ ] **Step 5: Fix call sites that construct these models directly**

Run: `flutter analyze` and fix any reported missing-required-argument errors at construction call sites (there should be none yet, since nothing in `lib/` constructs these models directly outside of `fromJson` — this step exists to catch anything this plan's authoring missed).

- [ ] **Step 6: Commit**

```bash
git add lib/core/api/models/question_item_model.dart lib/core/api/models/quiz_summary_model.dart lib/core/api/models/quiz_detail_model.dart lib/core/api/models/question_check_result_model.dart test/core/api/models/question_item_model_test.dart test/core/api/models/quiz_summary_model_test.dart
git commit -m "feat: wire answer_source/confidence/needs_answer_key into Dart models"
```

---

### Task 12: New API surface — URLs, client methods, `CorrectedAnswerModel`

**Files:**
- Modify: `lib/core/api/urls/quiz_urls.dart`
- Modify: `lib/core/api/clients/quiz_client/quiz_client.dart`
- Create: `lib/core/api/models/corrected_answer_model.dart`
- Test: `test/core/api/clients/quiz_client_test.dart`

**Interfaces:**
- Consumes: `QuizDetailModel` (Task 11).
- Produces: `QuizClient.submitAnswerKeyManual(int quizId, List<MapEntry<int, String>> answers) -> Future<QuizDetailModel>`, `QuizClient.uploadAnswerKeyDocument(int quizId, String filename, List<int> bytes) -> Future<QuizDetailModel>`, `QuizClient.correctQuestionAnswer(int questionId, String answer) -> Future<CorrectedAnswerModel>`.

- [ ] **Step 1: Write the failing tests**

Create `lib/core/api/models/corrected_answer_model.dart`:
```dart
class CorrectedAnswerModel {
  CorrectedAnswerModel({
    required this.questionId,
    required this.correctAnswer,
    required this.answerSource,
    required this.confidence,
  });

  final int questionId;
  final String correctAnswer;
  final String answerSource;
  final int? confidence;

  factory CorrectedAnswerModel.fromJson(Map<String, dynamic> json) {
    return CorrectedAnswerModel(
      questionId: json["question_id"] as int,
      correctAnswer: json["correct_answer"] as String? ?? "",
      answerSource: json["answer_source"] as String? ?? "user_corrected",
      confidence: json["confidence"] as int?,
    );
  }
}
```

Create `test/core/api/clients/quiz_client_test.dart`:
```dart
import "dart:convert";
import "dart:typed_data";

import "package:dio/dio.dart";
import "package:flutter_test/flutter_test.dart";
import "package:test_app/core/api/clients/quiz_client/quiz_client.dart";

class _RecordingAdapter implements HttpClientAdapter {
  _RecordingAdapter(this.responseBody);

  final Map<String, dynamic> responseBody;
  RequestOptions? lastRequest;

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    lastRequest = options;
    return ResponseBody.fromString(
      jsonEncode(responseBody),
      200,
      headers: {
        Headers.contentTypeHeader: [Headers.jsonContentType],
      },
    );
  }

  @override
  void close({bool force = false}) {}
}

void main() {
  test("submitAnswerKeyManual posts question numbers and answers", () async {
    final adapter = _RecordingAdapter({
      "applied": 1,
      "quiz": {
        "id": 5,
        "title": "Quiz",
        "course_name": "Course",
        "question_count": 1,
        "needs_answer_key": false,
        "questions": <dynamic>[],
      },
    });
    final dio = Dio()..httpClientAdapter = adapter;
    final client = QuizClient(dio);

    final quiz = await client.submitAnswerKeyManual(5, [const MapEntry(1, "42")]);

    expect(quiz.needsAnswerKey, isFalse);
    final sentData = adapter.lastRequest!.data as Map<String, dynamic>;
    expect(sentData["answers"], [
      {"question_number": 1, "answer": "42"},
    ]);
  });

  test("correctQuestionAnswer parses the corrected answer response", () async {
    final adapter = _RecordingAdapter({
      "quiz_id": 5,
      "question_id": 9,
      "correct_answer": "Real answer",
      "answer_source": "user_corrected",
      "confidence": null,
    });
    final dio = Dio()..httpClientAdapter = adapter;
    final client = QuizClient(dio);

    final result = await client.correctQuestionAnswer(9, "Real answer");

    expect(result.answerSource, "user_corrected");
    expect(result.correctAnswer, "Real answer");
    expect(result.confidence, isNull);
  });
}
```

- [ ] **Step 2: Run to verify it fails**

Run: `flutter test test/core/api/clients/quiz_client_test.dart`
Expected: FAIL — no such methods on `QuizClient`

- [ ] **Step 3: Implement URLs and client methods**

In `lib/core/api/urls/quiz_urls.dart`, add:
```dart
  static String answerKeyManual(int quizId) => "/quizzes/$quizId/answer-key/manual";
  static String answerKeyUpload(int quizId) => "/quizzes/$quizId/answer-key/upload";
  static String correctQuestion(int questionId) => "/questions/$questionId/correct";
```

In `lib/core/api/clients/quiz_client/quiz_client.dart`, add the import:
```dart
import "../../models/corrected_answer_model.dart";
```

Add the methods, after `submitQuestion`:
```dart
  Future<QuizDetailModel> submitAnswerKeyManual(
    int quizId,
    List<MapEntry<int, String>> answers,
  ) async {
    final response = await _dio.post<Map<String, dynamic>>(
      QuizUrls.answerKeyManual(quizId),
      data: <String, dynamic>{
        "answers": answers
            .map((entry) => {"question_number": entry.key, "answer": entry.value})
            .toList(),
      },
    );
    return QuizDetailModel.fromJson(response.data!["quiz"] as Map<String, dynamic>);
  }

  Future<QuizDetailModel> uploadAnswerKeyDocument(
    int quizId,
    String filename,
    List<int> bytes,
  ) async {
    final formData = FormData.fromMap(<String, dynamic>{
      "file": MultipartFile.fromBytes(bytes, filename: filename),
    });
    final response = await _dio.post<Map<String, dynamic>>(
      QuizUrls.answerKeyUpload(quizId),
      data: formData,
    );
    return QuizDetailModel.fromJson(response.data!["quiz"] as Map<String, dynamic>);
  }

  Future<CorrectedAnswerModel> correctQuestionAnswer(int questionId, String answer) async {
    final response = await _dio.post<Map<String, dynamic>>(
      QuizUrls.correctQuestion(questionId),
      data: <String, dynamic>{"answer": answer},
    );
    return CorrectedAnswerModel.fromJson(response.data!);
  }
```

- [ ] **Step 4: Run to verify it passes**

Run: `flutter test test/core/api/clients/quiz_client_test.dart`
Expected: 2 passed

- [ ] **Step 5: Commit**

```bash
git add lib/core/api/urls/quiz_urls.dart lib/core/api/clients/quiz_client/quiz_client.dart lib/core/api/models/corrected_answer_model.dart test/core/api/clients/quiz_client_test.dart
git commit -m "feat: add client methods for the answer-key and correction endpoints"
```

---

### Task 13: Repository wrapper methods

**Files:**
- Modify: `lib/core/repositories/quiz/quiz_repo.dart`

**Interfaces:**
- Consumes: `QuizClient` methods from Task 12.
- Produces: `QuizRepository.submitAnswerKeyManual(...) -> Future<Either<RequestFailure, QuizDetailModel>>`, `QuizRepository.uploadAnswerKeyDocument(...) -> Future<Either<RequestFailure, QuizDetailModel>>`, `QuizRepository.correctQuestionAnswer(...) -> Future<Either<RequestFailure, CorrectedAnswerModel>>`.

This is pure delegation with no branching (identical shape to every other method already in this file), so it is verified via static analysis rather than a new unit test — consistent with how the rest of `quiz_repo.dart` has no dedicated tests today.

- [ ] **Step 1: Add the import**

In `lib/core/repositories/quiz/quiz_repo.dart`, add:
```dart
import "../../api/models/corrected_answer_model.dart";
```

- [ ] **Step 2: Add the wrapper methods**

Add, after `submitQuestion`:
```dart
  Future<Either<RequestFailure, QuizDetailModel>> submitAnswerKeyManual(
    int quizId,
    List<MapEntry<int, String>> answers,
  ) => handleRequestFailure(() => _client.submitAnswerKeyManual(quizId, answers));

  Future<Either<RequestFailure, QuizDetailModel>> uploadAnswerKeyDocument(
    int quizId,
    String filename,
    List<int> bytes,
  ) => handleRequestFailure(() => _client.uploadAnswerKeyDocument(quizId, filename, bytes));

  Future<Either<RequestFailure, CorrectedAnswerModel>> correctQuestionAnswer(
    int questionId,
    String answer,
  ) => handleRequestFailure(() => _client.correctQuestionAnswer(questionId, answer));
```

- [ ] **Step 3: Verify it compiles**

Run: `flutter analyze lib/core/repositories/quiz/quiz_repo.dart`
Expected: no issues found

- [ ] **Step 4: Commit**

```bash
git add lib/core/repositories/quiz/quiz_repo.dart
git commit -m "feat: add repository methods for the answer-key and correction endpoints"
```

---

### Task 14: `QuizViewModel` — gap detection, answer-key submission, inline correction

**Files:**
- Modify: `lib/core/view_models/quiz_vm.dart`
- Test: `test/core/view_models/quiz_vm_gap_detection_test.dart`

**Interfaces:**
- Consumes: `QuizRepository` methods from Task 13; `UploadResultModel.createdQuizzes` (added below).
- Produces: `quizIdsNeedingAnswerKey(List<QuizSummaryModel> quizzes) -> List<int>` (top-level, public, pure); `QuizViewModel.pendingAnswerKeyQuizId -> int?`; `QuizViewModel.dismissPendingAnswerKey()`; `QuizViewModel.fetchQuizDetail(int id) -> Future<QuizDetailModel?>`; `QuizViewModel.submitAnswerKeyManual(int quizId, List<MapEntry<int, String>> answers) -> Future<bool>`; `QuizViewModel.uploadAnswerKeyDocument(int quizId, String filename, List<int> bytes) -> Future<bool>`; `QuizViewModel.correctAnswer(QuestionItemModel question, String answer) -> Future<void>`.

- [ ] **Step 1: Carry created-quiz metadata through the upload job result**

In `lib/core/api/models/upload_result_model.dart`, replace the whole class:
```dart
import "quiz_summary_model.dart";

class UploadResultModel {
  UploadResultModel({required this.primaryQuizId, this.jobId, this.createdQuizzes = const []});

  final int? primaryQuizId;
  final String? jobId;
  final List<QuizSummaryModel> createdQuizzes;

  factory UploadResultModel.fromJson(Map<String, dynamic> json) {
    if (json.containsKey("job_id")) {
      return UploadResultModel(
        primaryQuizId: null,
        jobId: json["job_id"] as String?,
      );
    }

    if (json.containsKey("id")) {
      return UploadResultModel(primaryQuizId: json["id"] as int);
    }

    final quizzes = json["quizzes"] as List<dynamic>? ?? <dynamic>[];
    if (quizzes.isNotEmpty) {
      final firstQuiz = quizzes.first as Map<String, dynamic>;
      return UploadResultModel(primaryQuizId: firstQuiz["id"] as int);
    }

    throw Exception("Upload completed but no quiz was returned.");
  }
}
```

In `lib/core/repositories/quiz/quiz_repo.dart`, in `_waitForUploadJob`, replace:
```dart
      if (job.status == "completed") {
        if (job.quizzes.isEmpty) {
          throw Exception("Upload finished, but no quizzes were created.");
        }
        return UploadResultModel(primaryQuizId: job.quizzes.first.id, jobId: job.jobId);
      }
```
with:
```dart
      if (job.status == "completed") {
        if (job.quizzes.isEmpty) {
          throw Exception("Upload finished, but no quizzes were created.");
        }
        return UploadResultModel(
          primaryQuizId: job.quizzes.first.id,
          jobId: job.jobId,
          createdQuizzes: job.quizzes,
        );
      }
```

- [ ] **Step 2: Write the failing test for the pure gap-detection function**

Create `test/core/view_models/quiz_vm_gap_detection_test.dart`:
```dart
import "package:flutter_test/flutter_test.dart";
import "package:test_app/core/api/models/quiz_summary_model.dart";
import "package:test_app/core/view_models/quiz_vm.dart";

void main() {
  test("returns ids of only the quizzes that need an answer key", () {
    final quizzes = [
      QuizSummaryModel(id: 1, title: "A", courseName: "C", questionCount: 3, needsAnswerKey: true),
      QuizSummaryModel(id: 2, title: "B", courseName: "C", questionCount: 4, needsAnswerKey: false),
      QuizSummaryModel(id: 3, title: "D", courseName: "C", questionCount: 2, needsAnswerKey: true),
    ];

    expect(quizIdsNeedingAnswerKey(quizzes), [1, 3]);
  });

  test("returns an empty list when nothing needs a key", () {
    final quizzes = [
      QuizSummaryModel(id: 1, title: "A", courseName: "C", questionCount: 3, needsAnswerKey: false),
    ];

    expect(quizIdsNeedingAnswerKey(quizzes), isEmpty);
  });
}
```

- [ ] **Step 3: Run to verify it fails**

Run: `flutter test test/core/view_models/quiz_vm_gap_detection_test.dart`
Expected: FAIL — `quizIdsNeedingAnswerKey` is not defined

- [ ] **Step 4: Implement the view model changes**

In `lib/core/view_models/quiz_vm.dart`, add imports:
```dart
import "../api/models/corrected_answer_model.dart";
```

Add, above the `QuizViewModel` class:
```dart
List<int> quizIdsNeedingAnswerKey(List<QuizSummaryModel> quizzes) {
  return quizzes.where((quiz) => quiz.needsAnswerKey).map((quiz) => quiz.id).toList();
}
```

Add a field, alongside the other private fields:
```dart
  List<int> _pendingAnswerKeyQuizIds = <int>[];
```

Add getters, alongside the other getters:
```dart
  int? get pendingAnswerKeyQuizId =>
      _pendingAnswerKeyQuizIds.isEmpty ? null : _pendingAnswerKeyQuizIds.first;
```

Add a method, near `refresh`:
```dart
  void dismissPendingAnswerKey() {
    if (_pendingAnswerKeyQuizIds.isNotEmpty) {
      _pendingAnswerKeyQuizIds.removeAt(0);
      notify();
    }
  }

  Future<QuizDetailModel?> fetchQuizDetail(int id) async {
    return _unwrap(await _repo.fetchQuiz(id));
  }
```

In `upload()`, replace:
```dart
    if (uploadResult != null) {
      if (uploadResult.primaryQuizId == null) {
        _error = "Upload completed but no quiz was returned.";
      } else {
        await refresh(focusQuizId: uploadResult.primaryQuizId);
      }
    }
```
with:
```dart
    if (uploadResult != null) {
      if (uploadResult.primaryQuizId == null) {
        _error = "Upload completed but no quiz was returned.";
      } else {
        _pendingAnswerKeyQuizIds = quizIdsNeedingAnswerKey(uploadResult.createdQuizzes);
        await refresh(focusQuizId: uploadResult.primaryQuizId);
      }
    }
```

Add methods, after `checkQuestion`:
```dart
  Future<bool> submitAnswerKeyManual(int quizId, List<MapEntry<int, String>> answers) async {
    final result = _unwrap(await _repo.submitAnswerKeyManual(quizId, answers));
    if (result == null) {
      notify();
      return false;
    }
    if (_selectedQuiz?.id == quizId) {
      _selectedQuiz = result;
      _syncAnswers(clearExisting: false);
    }
    notify();
    return true;
  }

  Future<bool> uploadAnswerKeyDocument(int quizId, String filename, List<int> bytes) async {
    final result = _unwrap(await _repo.uploadAnswerKeyDocument(quizId, filename, bytes));
    if (result == null) {
      notify();
      return false;
    }
    if (_selectedQuiz?.id == quizId) {
      _selectedQuiz = result;
      _syncAnswers(clearExisting: false);
    }
    notify();
    return true;
  }

  Future<void> correctAnswer(QuestionItemModel question, String answer) async {
    final result = _unwrap(await _repo.correctQuestionAnswer(question.id, answer));
    if (result == null) {
      notify();
      return;
    }
    _questionResults[question.id] = QuestionCheckResultModel(
      questionId: result.questionId,
      questionNumber: question.questionNumber,
      questionType: question.questionType,
      questionText: question.questionText,
      studentAnswer: _answers[question.id] ?? "",
      correctAnswer: result.correctAnswer,
      hasCorrectAnswer: true,
      isCorrect: true,
      status: "corrected",
      explanation: "Answer corrected by user.",
      answerSource: result.answerSource,
      confidence: result.confidence,
    );
    notify();
  }
```

- [ ] **Step 5: Run to verify it passes**

Run: `flutter test test/core/view_models/quiz_vm_gap_detection_test.dart`
Expected: 2 passed

- [ ] **Step 6: Run the existing widget test to check nothing regressed**

Run: `flutter test test/widget_test.dart`
Expected: PASS (unchanged)

- [ ] **Step 7: Commit**

```bash
git add lib/core/api/models/upload_result_model.dart lib/core/repositories/quiz/quiz_repo.dart lib/core/view_models/quiz_vm.dart test/core/view_models/quiz_vm_gap_detection_test.dart
git commit -m "feat: detect answer-key gaps after upload and add correction/gap-fill methods"
```

---

### Task 15: Dedicated "Add answer key" page

**Files:**
- Create: `lib/views/answer_key/answer_key_page.dart`
- Test: `test/views/answer_key/answer_key_page_test.dart`

**Interfaces:**
- Consumes: `QuizViewModel.submitAnswerKeyManual`/`uploadAnswerKeyDocument` (Task 14), `quizViewModelProvider`/`dioProvider` (existing).
- Produces: `AnswerKeyPage({required QuizDetailModel quiz})` widget.

- [ ] **Step 1: Write the failing test**

Create `test/views/answer_key/answer_key_page_test.dart`:
```dart
import "dart:convert";
import "dart:typed_data";

import "package:dio/dio.dart";
import "package:flutter/material.dart";
import "package:flutter_test/flutter_test.dart";
import "package:hooks_riverpod/hooks_riverpod.dart";

import "package:test_app/core/api/models/question_item_model.dart";
import "package:test_app/core/api/models/quiz_detail_model.dart";
import "package:test_app/core/providers.dart";
import "package:test_app/views/answer_key/answer_key_page.dart";

class _RecordingAdapter implements HttpClientAdapter {
  _RecordingAdapter(this.responseBody);

  final Map<String, dynamic> responseBody;
  RequestOptions? lastRequest;

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    lastRequest = options;
    return ResponseBody.fromString(
      jsonEncode(responseBody),
      200,
      headers: {
        Headers.contentTypeHeader: [Headers.jsonContentType],
      },
    );
  }

  @override
  void close({bool force = false}) {}
}

void main() {
  testWidgets("typed answers are submitted for non-empty fields only", (tester) async {
    final adapter = _RecordingAdapter({
      "applied": 1,
      "quiz": {
        "id": 1,
        "title": "Quiz",
        "course_name": "Course",
        "question_count": 1,
        "needs_answer_key": false,
        "questions": <dynamic>[],
      },
    });
    final dio = Dio()..httpClientAdapter = adapter;

    final quiz = QuizDetailModel(
      id: 1,
      title: "Quiz",
      courseName: "Course",
      questionCount: 1,
      needsAnswerKey: true,
      questions: [
        QuestionItemModel(
          id: 10,
          questionType: "SAQ",
          questionNumber: 1,
          questionText: "Explain X",
          options: null,
          answerSource: "unknown",
          confidence: null,
        ),
      ],
    );

    await tester.pumpWidget(
      ProviderScope(
        overrides: [dioProvider.overrideWithValue(dio)],
        child: MaterialApp(home: AnswerKeyPage(quiz: quiz)),
      ),
    );

    await tester.enterText(find.byType(TextFormField).first, "42");
    await tester.tap(find.text("Save answers"));
    await tester.pumpAndSettle();

    final sentData = adapter.lastRequest!.data as Map<String, dynamic>;
    expect(sentData["answers"], [
      {"question_number": 1, "answer": "42"},
    ]);
  });
}
```

- [ ] **Step 2: Run to verify it fails**

Run: `flutter test test/views/answer_key/answer_key_page_test.dart`
Expected: FAIL — file `lib/views/answer_key/answer_key_page.dart` does not exist

- [ ] **Step 3: Implement the page**

Create `lib/views/answer_key/answer_key_page.dart`:
```dart
import "package:file_selector/file_selector.dart";
import "package:flutter/material.dart";
import "package:hooks_riverpod/hooks_riverpod.dart";

import "../../core/api/models/quiz_detail_model.dart";
import "../../core/providers.dart";

class AnswerKeyPage extends ConsumerStatefulWidget {
  const AnswerKeyPage({super.key, required this.quiz});

  final QuizDetailModel quiz;

  @override
  ConsumerState<AnswerKeyPage> createState() => _AnswerKeyPageState();
}

class _AnswerKeyPageState extends ConsumerState<AnswerKeyPage> {
  final Map<int, TextEditingController> _controllers = <int, TextEditingController>{};
  bool _submitting = false;

  @override
  void initState() {
    super.initState();
    for (final question in widget.quiz.questions) {
      _controllers[question.id] = TextEditingController();
    }
  }

  @override
  void dispose() {
    for (final controller in _controllers.values) {
      controller.dispose();
    }
    super.dispose();
  }

  Future<void> _saveTypedAnswers() async {
    final answers = <MapEntry<int, String>>[];
    for (final question in widget.quiz.questions) {
      final text = _controllers[question.id]?.text.trim() ?? "";
      if (text.isNotEmpty) {
        answers.add(MapEntry(question.questionNumber, text));
      }
    }
    if (answers.isEmpty) {
      if (mounted) Navigator.of(context).pop();
      return;
    }
    setState(() => _submitting = true);
    await ref.read(quizViewModelProvider).submitAnswerKeyManual(widget.quiz.id, answers);
    if (mounted) Navigator.of(context).pop();
  }

  Future<void> _uploadDocument() async {
    final file = await openFile(
      acceptedTypeGroups: const <XTypeGroup>[
        XTypeGroup(label: "PDF", extensions: <String>["pdf"]),
      ],
    );
    if (file == null) {
      return;
    }
    setState(() => _submitting = true);
    final bytes = await file.readAsBytes();
    await ref.read(quizViewModelProvider).uploadAnswerKeyDocument(widget.quiz.id, file.name, bytes);
    if (mounted) Navigator.of(context).pop();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: Text("Add answer key: ${widget.quiz.title}")),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          const Text(
            "This document didn't include answers for these questions. Provide them below, "
            "upload a separate answer key, or skip to use the AI's best guesses.",
          ),
          const SizedBox(height: 16),
          Row(
            children: [
              OutlinedButton.icon(
                onPressed: _submitting ? null : _uploadDocument,
                icon: const Icon(Icons.upload_file),
                label: const Text("Upload answer key document"),
              ),
              const SizedBox(width: 12),
              TextButton(
                onPressed: _submitting ? null : () => Navigator.of(context).pop(),
                child: const Text("Skip"),
              ),
            ],
          ),
          const Divider(height: 32),
          for (final question in widget.quiz.questions)
            Padding(
              padding: const EdgeInsets.only(bottom: 16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text("Q${question.questionNumber}: ${question.questionText}"),
                  const SizedBox(height: 8),
                  TextFormField(
                    controller: _controllers[question.id],
                    decoration: const InputDecoration(
                      border: OutlineInputBorder(),
                      hintText: "Correct answer",
                    ),
                  ),
                ],
              ),
            ),
          const SizedBox(height: 16),
          FilledButton(
            onPressed: _submitting ? null : _saveTypedAnswers,
            child: Text(_submitting ? "Saving..." : "Save answers"),
          ),
        ],
      ),
    );
  }
}
```

- [ ] **Step 4: Run to verify it passes**

Run: `flutter test test/views/answer_key/answer_key_page_test.dart`
Expected: 1 passed

- [ ] **Step 5: Commit**

```bash
git add lib/views/answer_key/answer_key_page.dart test/views/answer_key/answer_key_page_test.dart
git commit -m "feat: add dedicated answer-key gap-fill page"
```

---

### Task 16: Navigate to the answer-key page after upload

**Files:**
- Modify: `lib/views/dashboard/quiz_dashboard_page.dart`
- Test: `test/views/dashboard/quiz_dashboard_page_navigation_test.dart`

**Interfaces:**
- Consumes: `QuizViewModel.pendingAnswerKeyQuizId`/`dismissPendingAnswerKey`/`fetchQuizDetail` (Task 14), `AnswerKeyPage` (Task 15).
- Produces: `shouldShowAnswerKeyPrompt(int? previousPendingId, int? nextPendingId) -> bool` (top-level, public, pure).

- [ ] **Step 1: Write the failing test for the pure decision function**

Create `test/views/dashboard/quiz_dashboard_page_navigation_test.dart`:
```dart
import "package:flutter_test/flutter_test.dart";
import "package:test_app/views/dashboard/quiz_dashboard_page.dart";

void main() {
  test("shows the prompt when a new pending id appears", () {
    expect(shouldShowAnswerKeyPrompt(null, 5), isTrue);
    expect(shouldShowAnswerKeyPrompt(5, 7), isTrue);
  });

  test("does not show the prompt when there is nothing pending or it is unchanged", () {
    expect(shouldShowAnswerKeyPrompt(null, null), isFalse);
    expect(shouldShowAnswerKeyPrompt(5, 5), isFalse);
  });
}
```

- [ ] **Step 2: Run to verify it fails**

Run: `flutter test test/views/dashboard/quiz_dashboard_page_navigation_test.dart`
Expected: FAIL — `shouldShowAnswerKeyPrompt` is not defined

- [ ] **Step 3: Implement**

In `lib/views/dashboard/quiz_dashboard_page.dart`, add the import:
```dart
import "../answer_key/answer_key_page.dart";
```

Add, above the `QuizDashboardPage` class:
```dart
bool shouldShowAnswerKeyPrompt(int? previousPendingId, int? nextPendingId) {
  return nextPendingId != null && previousPendingId != nextPendingId;
}
```

In `build`, right after `final filteredQuizzes = vm.filteredQuizzes;`, add:
```dart
    ref.listen(quizViewModelProvider, (previous, next) {
      final pendingId = next.pendingAnswerKeyQuizId;
      if (shouldShowAnswerKeyPrompt(previous?.pendingAnswerKeyQuizId, pendingId)) {
        next.dismissPendingAnswerKey();
        Navigator.of(context).push(
          MaterialPageRoute<void>(
            builder: (_) => FutureBuilder(
              future: next.fetchQuizDetail(pendingId!),
              builder: (context, snapshot) {
                final quiz = snapshot.data;
                if (quiz == null) {
                  return const Scaffold(body: Center(child: CircularProgressIndicator()));
                }
                return AnswerKeyPage(quiz: quiz);
              },
            ),
          ),
        );
      }
    });
```

- [ ] **Step 4: Run to verify it passes**

Run: `flutter test test/views/dashboard/quiz_dashboard_page_navigation_test.dart`
Expected: 2 passed

- [ ] **Step 5: Commit**

```bash
git add lib/views/dashboard/quiz_dashboard_page.dart test/views/dashboard/quiz_dashboard_page_navigation_test.dart
git commit -m "feat: navigate to the answer-key page when an upload leaves gaps"
```

---

### Task 17: Confidence badge and inline correction in `QuestionCard`

**Files:**
- Modify: `lib/views/dashboard/widget/question_card.dart`
- Modify: `lib/views/dashboard/widget/quiz_workspace.dart`
- Modify: `lib/views/dashboard/quiz_dashboard_page.dart`
- Test: `test/views/dashboard/widget/question_card_test.dart`

**Interfaces:**
- Consumes: `QuestionCheckResultModel.answerSource`/`.confidence` (Task 11), `QuizViewModel.correctAnswer` (Task 14).
- Produces: `QuestionCard` gains a required `onCorrect: ValueChanged<String>` parameter.

- [ ] **Step 1: Write the failing test**

Create `test/views/dashboard/widget/question_card_test.dart`:
```dart
import "package:flutter/material.dart";
import "package:flutter_test/flutter_test.dart";

import "package:test_app/core/api/models/question_check_result_model.dart";
import "package:test_app/core/api/models/question_item_model.dart";
import "package:test_app/views/dashboard/widget/question_card.dart";

void main() {
  testWidgets("shows the AI confidence badge and reports corrections", (tester) async {
    String? corrected;

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: QuestionCard(
            question: QuestionItemModel(
              id: 1,
              questionType: "SAQ",
              questionNumber: 1,
              questionText: "Explain X",
              options: null,
              answerSource: "ai_inferred",
              confidence: 68,
            ),
            currentAnswer: "my answer",
            result: QuestionCheckResultModel(
              questionId: 1,
              questionNumber: 1,
              questionType: "SAQ",
              questionText: "Explain X",
              studentAnswer: "my answer",
              correctAnswer: "AI guess",
              hasCorrectAnswer: true,
              isCorrect: false,
              status: "incorrect",
              explanation: "not quite",
              answerSource: "ai_inferred",
              confidence: 68,
            ),
            isChecking: false,
            onChanged: (_) {},
            onCheck: () {},
            onCorrect: (value) => corrected = value,
          ),
        ),
      ),
    );

    expect(find.textContaining("68% confidence"), findsOneWidget);

    await tester.tap(find.text("Correct this"));
    await tester.pump();
    await tester.enterText(find.byType(TextFormField).last, "Real answer");
    await tester.tap(find.byIcon(Icons.check));
    await tester.pump();

    expect(corrected, "Real answer");
  });

  testWidgets("shows no badge for explicit-solution answers", (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: QuestionCard(
            question: QuestionItemModel(
              id: 1,
              questionType: "MCQ",
              questionNumber: 1,
              questionText: "Pick one",
              options: const {"a": "A", "b": "B"},
              answerSource: "explicit_solution",
              confidence: null,
            ),
            currentAnswer: "A",
            result: QuestionCheckResultModel(
              questionId: 1,
              questionNumber: 1,
              questionType: "MCQ",
              questionText: "Pick one",
              studentAnswer: "A",
              correctAnswer: "A",
              hasCorrectAnswer: true,
              isCorrect: true,
              status: "correct",
              explanation: "Matched the correct option.",
              answerSource: "explicit_solution",
              confidence: null,
            ),
            isChecking: false,
            onChanged: (_) {},
            onCheck: () {},
            onCorrect: (_) {},
          ),
        ),
      ),
    );

    expect(find.text("Correct this"), findsNothing);
  });
}
```

- [ ] **Step 2: Run to verify it fails**

Run: `flutter test test/views/dashboard/widget/question_card_test.dart`
Expected: FAIL — `onCorrect` parameter does not exist

- [ ] **Step 3: Implement**

In `lib/views/dashboard/widget/question_card.dart`, add `onCorrect` to the constructor:
```dart
  const QuestionCard({
    super.key,
    required this.question,
    required this.currentAnswer,
    required this.result,
    required this.isChecking,
    required this.onChanged,
    required this.onCheck,
    required this.onCorrect,
  });
```
and the field:
```dart
  final ValueChanged<String> onCorrect;
```

Replace the result-display block at the end of `build`:
```dart
          if (result != null) ...[
            const SizedBox(height: 12),
            Text(
              result!.isCorrect ? "Correct" : "Incorrect",
              style: TextStyle(
                fontWeight: FontWeight.w700,
                color: result!.isCorrect
                    ? const Color(0xFF2E7D32)
                    : const Color(0xFFC62828),
              ),
            ),
            if (result!.hasCorrectAnswer) ...[
              const SizedBox(height: 4),
              Text("Correct answer: ${result!.correctAnswer}"),
            ],
            const SizedBox(height: 4),
            Text(result!.explanation),
          ],
```
with:
```dart
          if (result != null) ...[
            const SizedBox(height: 12),
            Text(
              result!.isCorrect ? "Correct" : "Incorrect",
              style: TextStyle(
                fontWeight: FontWeight.w700,
                color: result!.isCorrect
                    ? const Color(0xFF2E7D32)
                    : const Color(0xFFC62828),
              ),
            ),
            if (result!.hasCorrectAnswer) ...[
              const SizedBox(height: 4),
              Text("Correct answer: ${result!.correctAnswer}"),
            ],
            const SizedBox(height: 4),
            Text(result!.explanation),
            if (result!.answerSource == "ai_inferred" || result!.answerSource == "unknown") ...[
              const SizedBox(height: 10),
              _AiAnswerReview(result: result!, onCorrect: onCorrect),
            ],
          ],
```

Add, below the `QuestionCard` class:
```dart
class _AiAnswerReview extends StatefulWidget {
  const _AiAnswerReview({required this.result, required this.onCorrect});

  final QuestionCheckResultModel result;
  final ValueChanged<String> onCorrect;

  @override
  State<_AiAnswerReview> createState() => _AiAnswerReviewState();
}

class _AiAnswerReviewState extends State<_AiAnswerReview> {
  final _controller = TextEditingController();
  bool _editing = false;

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final label = widget.result.answerSource == "ai_inferred"
        ? "AI's best guess"
            "${widget.result.confidence != null ? " · ${widget.result.confidence}% confidence" : ""}"
        : "AI couldn't determine an answer";

    if (!_editing) {
      return Row(
        children: [
          Expanded(
            child: Text(label, style: const TextStyle(fontStyle: FontStyle.italic)),
          ),
          TextButton(
            onPressed: () => setState(() => _editing = true),
            child: const Text("Correct this"),
          ),
        ],
      );
    }

    return Row(
      children: [
        Expanded(
          child: TextFormField(
            controller: _controller,
            decoration: const InputDecoration(
              border: OutlineInputBorder(),
              hintText: "Enter the correct answer",
            ),
          ),
        ),
        const SizedBox(width: 8),
        IconButton(
          icon: const Icon(Icons.check),
          onPressed: () {
            final value = _controller.text.trim();
            if (value.isEmpty) return;
            widget.onCorrect(value);
            setState(() => _editing = false);
          },
        ),
      ],
    );
  }
}
```

In `lib/views/dashboard/widget/quiz_workspace.dart`, add a required callback and thread it through. Add to the constructor:
```dart
    required this.onCorrectAnswer,
```
and field (typed as `Future<void> Function(...)` to match the return type of `vm.correctAnswer` and the sibling `onCheckQuestion`/`onSubmit` fields in this same file):
```dart
  final Future<void> Function(QuestionItemModel question, String value) onCorrectAnswer;
```
In `build`, update the `QuestionCard(...)` construction to pass it:
```dart
                child: QuestionCard(
                  question: question,
                  currentAnswer: answers[question.id] ?? "",
                  result: questionResults[question.id],
                  isChecking: checkingQuestionIds.contains(question.id),
                  onChanged: (value) => onChange(question, value),
                  onCheck: () => onCheckQuestion(question),
                  onCorrect: (value) => onCorrectAnswer(question, value),
                ),
```

In `lib/views/dashboard/quiz_dashboard_page.dart`, update the `QuizWorkspace(...)` construction to pass it:
```dart
                  final workspace = QuizWorkspace(
                    quiz: quiz,
                    answers: vm.answers,
                    submission: vm.submission,
                    questionResults: vm.questionResults,
                    checkingQuestionIds: vm.checkingQuestionIds,
                    submitting: vm.submitting,
                    onChange: vm.handleAnswerChange,
                    onCheckQuestion: vm.checkQuestion,
                    onSubmit: vm.submit,
                    onCorrectAnswer: vm.correctAnswer,
                  );
```

- [ ] **Step 4: Run to verify it passes**

Run: `flutter test test/views/dashboard/widget/question_card_test.dart`
Expected: 2 passed

- [ ] **Step 5: Commit**

```bash
git add lib/views/dashboard/widget/question_card.dart lib/views/dashboard/widget/quiz_workspace.dart lib/views/dashboard/quiz_dashboard_page.dart test/views/dashboard/widget/question_card_test.dart
git commit -m "feat: show AI confidence badge with inline correction in QuestionCard"
```

---

### Task 18: Full verification pass

**Files:** none (verification only).

- [ ] **Step 1: Run the full backend suite**

Run: `cd backend && python -m pytest -v`
Expected: all tests pass

- [ ] **Step 2: Run the full Flutter suite and analyzer**

Run: `flutter test`
Expected: all tests pass

Run: `flutter analyze`
Expected: no issues found

- [ ] **Step 3: Manually exercise the new flow**

Run: `cd backend && python app.py` (in one terminal) and `flutter run -d macos` (or your preferred device, in another). Upload a PDF that has no answer key at all, confirm the app navigates to the "Add answer key" page for the resulting quiz, type an answer for at least one question, save, and confirm that question's `answer_source` is no longer flagged as needing review. Then, on a question the AI had to guess (a partial-gap case), check/submit an answer, confirm the confidence badge appears, tap "Correct this", and confirm the corrected answer sticks on a subsequent check.

- [ ] **Step 4: Commit any final fixes found during manual verification**

If manual verification surfaces issues, fix them and commit:
```bash
git add -A
git commit -m "fix: address issues found in manual end-to-end verification"
```
