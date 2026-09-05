# OCR ingestion + AI-answer confidence + correction capture

Status: approved by user in brainstorming session. Ready for implementation planning.

## Problem

The current upload pipeline (`backend/pdf_parser.py`) is narrow in two ways:

1. **Text-only extraction.** `extract_pages_from_pdf` calls PyMuPDF's `get_text("text")`, which only reads a PDF's embedded text layer. A scanned/image-only PDF yields empty pages and produces no questions.
2. **Format-locked segmentation.** `extract_topic_segments_from_pdf` splits a document into topics via a regex on the literal heading `FOUNDATION: <name>`. Any other paper layout collapses into a single `"Unknown Course"` blob.

Separately, the parser already asks Gemini to classify each question's `answer_source` (`explicit_solution` / `ai_inferred` / `unknown`), but this is discarded rather than persisted, there is no confidence score, and there is no way for a user to review an AI-guessed answer, correct it, or supply an answer key when the document has none.

## Goals

- Any PDF (scanned or text-based) can be ingested and digitized.
- Topic segmentation is no longer tied to one document's heading format.
- Questions the AI had to guess an answer for carry a confidence score.
- When a whole quiz/topic has zero answers found in the source document, the uploader is prompted (on a dedicated page) to supply an answer key — by typing answers in or uploading a separate answer-key document.
- When only some of a quiz's questions are missing answers, the AI fills just those gaps silently (no prompt) — same as it filling isolated `ai_inferred` questions today.
- Any AI-guessed answer (`ai_inferred`/`unknown`) can be corrected later, inline, while a quiz is being taken. Every correction is persisted for future reference and immediately becomes the live grading answer.

## Non-goals

- Auth/user accounts (unchanged — still single shared instance, no login).
- Changing how MCQ/SAQ/SEQ grading logic itself compares an answer once `correct_answer` is set (unchanged).
- A UI to browse the correction ledger (`AnswerEvent` rows are stored for future reference, not surfaced in a screen yet).

## Design

### 1. OCR fallback (backend)

In `extract_pages_from_pdf`, for each page where `get_text("text").strip()` is under ~20 characters (no usable text layer), render the page via PyMuPDF's own `page.get_pixmap(dpi=300)` and run `pytesseract.image_to_string()` on it, using that as the page's text instead. No `poppler`/`pdf2image` needed — PyMuPDF already rasterizes the page.

New Python deps: `pytesseract`, `Pillow`. New system dependency: the `tesseract-ocr` binary + language data, which must be installed in the Docker image, documented in `README.md`, and added to the Windows PowerShell bootstrap script (`start-backend-windows.ps1`). OCR failure on a page (missing binary, decode error) is caught and logged; that page falls back to empty text exactly like today's "no text layer" case — it never blocks the rest of the upload.

### 2. AI-driven topic segmentation (backend)

Replace `TOPIC_HEADING_RE`/`extract_topic_segments_from_pdf`'s regex approach with `segment_topics_with_ai(pages: list[str]) -> list[dict]`: one Gemini call over the page-marked full text (reusing the existing `_join_pages` marker format) that returns topic boundaries as a JSON list of `{"topic_name", "start_page", "end_page"}`. The original per-page list is sliced by those page ranges into each topic's text, then handed to the existing `parse_topic_with_ai` unchanged.

If Gemini fails, times out, or returns something unparseable, fall back to today's safety net: treat the whole document as one `"Unknown Course"` segment. This removes the format-specific regex without adding a new failure mode.

### 3. Confidence in the parse prompt/schema (backend)

Add a `confidence` field (integer 0-100) to the per-question JSON schema in `PARSE_PROMPT_TEMPLATE`, required whenever `answer_source` is `ai_inferred`. The prompt instructs Gemini to always attempt a best-effort guess rather than defaulting to `unknown` too eagerly; `unknown` (empty `correct_answer`, no confidence) remains valid for genuinely unanswerable questions (e.g. one that references an image that isn't available).

Confidence is not requested/shown for `explicit_solution` answers — those are treated as ground truth.

### 4. Data model changes (backend)

`Question` gains two columns:
- `answer_source`: `explicit_solution` / `ai_inferred` / `unknown` / `user_provided` / `user_corrected`
- `confidence`: nullable integer 0-100

New table `AnswerEvent`:
- `id`, `question_id` (FK), `previous_answer`, `previous_source`, `new_answer`, `new_source`, `confidence_at_time` (nullable), `created_at`

Both the gap-fill flow and the inline-correction flow call one shared helper, `set_question_answer(question, new_answer, new_source)`, which updates `Question.correct_answer`/`answer_source` and inserts one `AnswerEvent` row. This is the durable "store it for future reference" ledger the user asked for, and it's the single mechanism behind both entry points.

`Quiz.to_dict()` gains `needs_answer_key: bool` — true iff the quiz has at least one question and zero of its questions have `answer_source == explicit_solution`. This is computed live from stored questions (not a one-time flag), so it stays correct if the user revisits later. This is evaluated **per quiz/topic**, not aggregated across an upload job — a 3-topic upload where 2 topics have full answer keys and 1 doesn't flags only that one topic.

Partial gaps (some questions in a quiz have `explicit_solution`, others don't) never set `needs_answer_key` — the missing ones are simply `ai_inferred` (or `unknown`) with a confidence score, exactly like an isolated AI guess, and are only ever fixed later via inline correction.

### 5. New/changed API surface (backend)

New endpoints:
- `POST /api/quizzes/<id>/answer-key/manual` — body `{"answers": [{"question_number": 1, "answer": "..."}]}`. Applies each via `set_question_answer(..., new_source="user_provided")`.
- `POST /api/quizzes/<id>/answer-key/upload` — multipart file. Parsed the same way as a main upload (text/OCR extraction) with a lighter prompt that extracts `{question_number: answer}` pairs, matched onto that quiz's existing questions by number via `set_question_answer`. Any question numbers that don't match are left as gaps and flow into the same auto-infer path as isolated `ai_inferred` questions — this endpoint has no distinct failure branch; a low match rate just means more of the quiz ends up AI-inferred, which is visible via each question's `answer_source`/`confidence` and correctable inline.
- `POST /api/questions/<id>/correct` — body `{"answer": "..."}`. Calls `set_question_answer(..., new_source="user_corrected")`. Not gated server-side by current `answer_source` (no reason to forbid fixing an explicit answer if it's ever wrong) — the UI only shows the affordance for `ai_inferred`/`unknown`.

Changed responses:
- `Quiz.to_dict()` → adds `needs_answer_key`. This rides along for free in `GET /api/quizzes`, `GET /api/quizzes/<id>`, and each entry of `GET /api/uploads/<job_id>`'s `quizzes` list.
- Question serialization (quiz-detail, and the per-question result of both submit endpoints) → adds `answer_source` and `confidence`. `correct_answer` itself continues to be withheld pre-attempt, exactly as today.

### 6. Flutter upload flow

Upload itself is unchanged (`vm.upload()` still just picks a file, POSTs, and polls the job). The only new behavior is what happens once the job completes: if any created quiz has `needs_answer_key == true`, the app navigates to a **dedicated "Add answer key" page** for that quiz (one at a time if more than one is flagged) instead of going straight to the quiz. That page offers:
- **Upload a document** → `file_selector` again, posts to `answer-key/upload`.
- **Type them in** → a form with one answer field per question (reusing the existing MCQ/text rendering from `QuestionCard` in a "here's the question, give the answer" mode), posts to `answer-key/manual`.
- **Skip** → dismiss, proceed with the AI's guesses as-is.

Because `needs_answer_key` is a durable, live-computed quiz property (not a one-time upload signal), the same page is reachable later via an "Add answer key" action on any quiz that still needs one, not only right after upload.

### 7. Inline correction UI

`QuestionCheckResultModel` and the submit-result models gain `answerSource`/`confidence`. In `QuestionCard`, whenever a check/submit result shows `answerSource == ai_inferred` (or `unknown`), render a small badge (*"AI's best guess · 68% confidence"*, or *"AI couldn't determine an answer"* for `unknown`) next to the existing correct-answer text, with an inline "Correct this" affordance (an editable field + save button) that posts to `POST /api/questions/<id>/correct` and re-renders that question's result with the corrected answer.

## Error handling summary

| Failure | Behavior |
|---|---|
| OCR fails on a page (missing tesseract binary, decode error) | Log, treat page as empty text — same as no text layer today |
| AI segmentation fails/unparseable | Fall back to single "Unknown Course" segment |
| Answer-key doc upload has a low/no match rate | Unmatched questions flow into normal auto-infer; no distinct error state |
| Correction/gap-fill endpoints | Not source-gated server-side; UI controls when the affordance is shown |

## Testing approach

- Backend: OCR fallback triggers on low-text pages (mocked `pytesseract`); segmentation fallback on Gemini failure; `set_question_answer`/`AnswerEvent` correctness; `needs_answer_key` computation (zero-explicit vs partial vs fully-explicit); the three new/changed endpoints.
- Flutter: the "Add answer key" page's typed-form and doc-upload paths; the confidence badge/correction affordance in `QuestionCard`.

Detailed task-level test breakdown belongs in the implementation plan, not this spec.
