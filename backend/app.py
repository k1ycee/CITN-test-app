import logging
import os
import threading
from pathlib import Path
from uuid import uuid4

from flask import Flask, jsonify, request
from flask_cors import CORS
from sqlalchemy import inspect, text
from werkzeug.utils import secure_filename

from config import Config
from models import Course, Question, Quiz, Submission, SubmissionAnswer, db, set_question_answer
from pdf_parser import (
    extract_topic_segments_from_pdf,
    grade_answer_with_ai,
    parse_answer_key_document,
    parse_pdf_with_ai,
    parse_topic_with_ai,
)

ALLOWED_EXTENSIONS = {"pdf"}
PROCESSING_JOBS: dict[str, dict] = {}
PROCESSING_LOCK = threading.Lock()

logging.basicConfig(
    level=logging.INFO,
    format="%(asctime)s %(levelname)s %(name)s: %(message)s",
)
logger = logging.getLogger(__name__)


def create_app() -> Flask:
    app = Flask(__name__)
    app.config.from_object(Config)

    CORS(app)
    db.init_app(app)

    Path(app.instance_path).mkdir(parents=True, exist_ok=True)
    upload_dir = Path(app.config["UPLOAD_FOLDER"])
    upload_dir.mkdir(parents=True, exist_ok=True)

    with app.app_context():
        db.create_all()
        _ensure_question_columns()

    register_routes(app)
    return app



def _ensure_question_columns() -> None:
    """Idempotently adds columns to a pre-existing `questions` table.

    `db.create_all()` only creates TABLES that are missing; it never ALTERs
    a table that already exists. Anyone upgrading with a pre-existing
    quiz.db (created before `answer_source`/`confidence` were added to the
    `Question` model) would otherwise hit `OperationalError: no such
    column: questions.answer_source` on the very first request. This is a
    small SQLite-oriented dev app, so a full migration framework (Alembic)
    is overkill here -- this minimal, idempotent check is enough.
    """
    inspector = inspect(db.engine)
    if "questions" not in inspector.get_table_names():
        # Table doesn't exist yet; db.create_all() above already created it
        # (if at all) with every column the current models define.
        return

    existing_columns = {column["name"] for column in inspector.get_columns("questions")}
    with db.engine.begin() as connection:
        if "answer_source" not in existing_columns:
            connection.execute(
                text(
                    "ALTER TABLE questions ADD COLUMN answer_source "
                    "VARCHAR(20) NOT NULL DEFAULT 'unknown'"
                )
            )
        if "confidence" not in existing_columns:
            connection.execute(
                text("ALTER TABLE questions ADD COLUMN confidence INTEGER")
            )



def register_routes(app: Flask) -> None:
    @app.get("/api/health")
    def health_check():
        return jsonify({"status": "ok"})

    @app.get("/api/courses")
    def list_courses():
        courses = Course.query.order_by(Course.name.asc()).all()
        return jsonify([course.to_dict() for course in courses])

    @app.get("/api/quizzes")
    def list_quizzes():
        quizzes = Quiz.query.order_by(Quiz.created_at.desc()).all()
        return jsonify([quiz.to_dict() for quiz in quizzes])

    @app.get("/api/quizzes/<int:quiz_id>")
    def get_quiz(quiz_id: int):
        quiz = Quiz.query.get_or_404(quiz_id)
        return jsonify(quiz.to_dict(include_questions=True))

    @app.get("/api/uploads/<job_id>")
    def get_upload_job(job_id: str):
        with PROCESSING_LOCK:
            job = PROCESSING_JOBS.get(job_id)
        if job is None:
            return jsonify({"error": "Upload job not found"}), 404
        return jsonify(job)

    @app.post("/api/upload")
    def upload_pdf():
        if "file" not in request.files:
            return jsonify({"error": "Missing uploaded file under 'file'"}), 400

        file = request.files["file"]
        if not file or file.filename == "":
            return jsonify({"error": "No file selected"}), 400

        if not _allowed_file(file.filename):
            return jsonify({"error": "Only PDF uploads are supported"}), 400

        filename = secure_filename(file.filename)
        destination = Path(app.config["UPLOAD_FOLDER"]) / filename
        file.save(destination)

        async_requested = str(request.form.get("async", "true")).lower() in {
            "1",
            "true",
            "yes",
        }

        if async_requested:
            topic_segments = extract_topic_segments_from_pdf(str(destination))
            job_id = uuid4().hex
            _create_upload_job(job_id, filename, topic_segments)
            thread = threading.Thread(
                target=_process_upload_job,
                args=(app, job_id, str(destination), filename, topic_segments),
                daemon=True,
            )
            thread.start()
            return jsonify({"job_id": job_id, "status": "processing"}), 202

        try:
            topic_segments = extract_topic_segments_from_pdf(str(destination))
            created_quizzes = _process_topic_segments(filename, topic_segments)
        except Exception as exc:  # pragma: no cover
            logger.exception("Failed to parse uploaded PDF")
            return jsonify({"error": str(exc)}), 500

        if len(created_quizzes) == 1:
            return jsonify(created_quizzes[0]), 201

        return jsonify({"quizzes": created_quizzes, "count": len(created_quizzes)}), 201

    @app.post("/api/quizzes/<int:quiz_id>/submit")
    def submit_quiz(quiz_id: int):
        quiz = Quiz.query.get_or_404(quiz_id)
        payload = request.get_json(silent=True) or {}
        answers_payload = payload.get("answers")

        if not isinstance(answers_payload, list):
            return jsonify({"error": "'answers' must be a list"}), 400

        answers_by_question = {}
        for item in answers_payload:
            question_id = item.get("question_id")
            student_answer = str(item.get("answer", "")).strip()
            if question_id is None:
                return jsonify({"error": "Every answer needs a question_id"}), 400
            answers_by_question[int(question_id)] = student_answer

        submission = Submission(quiz_id=quiz.id, total_questions=len(quiz.questions))
        db.session.add(submission)

        score = 0
        results = []

        for question in sorted(quiz.questions, key=lambda q: q.question_number):
            student_answer = answers_by_question.get(question.id, "")
            result = _build_question_result(question, student_answer)
            if result["is_correct"]:
                score += 1

            submission_answer = SubmissionAnswer(
                submission=submission,
                question=question,
                student_answer=student_answer,
                is_correct=result["is_correct"],
                status=result["status"],
                explanation=result.get("explanation", ""),
            )
            db.session.add(submission_answer)
            results.append(result)

        submission.score = score
        db.session.commit()

        return jsonify(
            {
                "submission": submission.to_dict(),
                "results": results,
                "summary": {
                    "score": score,
                    "total_questions": len(quiz.questions),
                    "percentage": round((score / len(quiz.questions)) * 100, 2)
                    if quiz.questions
                    else 0,
                },
            }
        )

    @app.post("/api/questions/<int:question_id>/submit")
    def submit_single_question(question_id: int):
        question = Question.query.get_or_404(question_id)
        payload = request.get_json(silent=True) or {}
        student_answer = str(payload.get("answer", "")).strip()
        return jsonify({"quiz_id": question.quiz_id, "result": _build_question_result(question, student_answer)})

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

    @app.post("/api/quizzes/<int:quiz_id>/answer-key/manual")
    def submit_manual_answer_key(quiz_id: int):
        quiz = Quiz.query.get_or_404(quiz_id)
        payload = request.get_json(silent=True) or {}
        answers_payload = payload.get("answers")

        if not isinstance(answers_payload, list):
            return jsonify({"error": "'answers' must be a list"}), 400

        # Keyed by question_id (not question_number): a quiz can have an
        # MCQ section and an SAQ section that both number their questions
        # 1..N, so question_number is not unique within a quiz. The
        # document-upload answer-key path below has no question ids to
        # reference and must keep matching by number; this manual path has
        # real question ids from the client, so use those instead.
        applied = 0
        for item in answers_payload:
            question_id = item.get("question_id")
            answer = str(item.get("answer", "")).strip()
            if question_id is None or not answer:
                continue
            question = Question.query.get(int(question_id))
            if question is None or question.quiz_id != quiz.id:
                continue
            set_question_answer(question, answer, "user_provided")
            applied += 1

        db.session.commit()
        db.session.expunge_all()
        quiz = Quiz.query.get_or_404(quiz_id)
        return jsonify({"applied": applied, "quiz": quiz.to_dict(include_questions=True)})

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



def _allowed_file(filename: str) -> bool:
    return "." in filename and filename.rsplit(".", 1)[1].lower() in ALLOWED_EXTENSIONS



def _build_question_result(question: Question, student_answer: str) -> dict:
    correct_answer = question.correct_answer.strip()
    grading = _grade_question(question, student_answer)
    return {
        "question_id": question.id,
        "question_number": question.question_number,
        "question_type": question.question_type,
        "question_text": question.question_text,
        "student_answer": student_answer,
        "correct_answer": correct_answer,
        "has_correct_answer": bool(correct_answer),
        "is_correct": grading["is_correct"],
        "status": grading["status"],
        "explanation": grading.get("explanation", ""),
        "answer_source": question.answer_source,
        "confidence": question.confidence,
    }



def _store_parsed_quiz(filename: str, parsed: dict) -> Quiz:
    course_name = (parsed.get("course_name") or "Unknown Course").strip()
    quiz_title = (parsed.get("quiz_title") or filename).strip()

    course = Course.query.filter_by(name=course_name).first()
    if course is None:
        course = Course(name=course_name)
        db.session.add(course)
        db.session.flush()

    quiz = Quiz(course=course, title=quiz_title, pdf_filename=filename)
    db.session.add(quiz)
    db.session.flush()

    for section in parsed.get("sections", []):
        question_type = str(section.get("type", "")).upper()
        label = section.get("label")
        if question_type not in {"MCQ", "SAQ", "SEQ"}:
            continue
        for question_data in section.get("questions", []):
            question_number = int(question_data.get("number", 0))
            question_text = (question_data.get("text") or "").strip()
            if question_number <= 0 or not question_text:
                continue
            options = question_data.get("options") or {}
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
            db.session.add(question)

    db.session.commit()
    return quiz



def _process_topic_segments(filename: str, topic_segments: list[dict]) -> list[dict]:
    created_quizzes = []
    for topic in topic_segments:
        parsed_topic = parse_topic_with_ai(
            topic_name=topic["topic_name"],
            topic_text=topic["text"],
        )
        quiz = _store_parsed_quiz(filename=filename, parsed=parsed_topic)
        created_quizzes.append(quiz.to_dict(include_questions=True))
    return created_quizzes



def _create_upload_job(job_id: str, filename: str, topic_segments: list[dict]) -> None:
    with PROCESSING_LOCK:
        PROCESSING_JOBS[job_id] = {
            "job_id": job_id,
            "filename": filename,
            "status": "processing",
            "total_topics": len(topic_segments),
            "completed_topics": 0,
            "topics": [topic["topic_name"] for topic in topic_segments],
            "quizzes": [],
            "errors": [],
        }



def _update_upload_job(job_id: str, **updates) -> None:
    with PROCESSING_LOCK:
        job = PROCESSING_JOBS.get(job_id)
        if job is not None:
            job.update(updates)



def _append_upload_job_quiz(job_id: str, quiz_data: dict) -> None:
    with PROCESSING_LOCK:
        job = PROCESSING_JOBS.get(job_id)
        if job is not None:
            job["quizzes"].append(quiz_data)
            job["completed_topics"] += 1



def _append_upload_job_error(job_id: str, topic_name: str, error: str) -> None:
    with PROCESSING_LOCK:
        job = PROCESSING_JOBS.get(job_id)
        if job is not None:
            job["errors"].append({"topic": topic_name, "error": error})



def _process_upload_job(app: Flask, job_id: str, pdf_path: str, filename: str, topic_segments: list[dict]) -> None:
    with app.app_context():
        try:
            for topic in topic_segments:
                try:
                    parsed_topic = parse_topic_with_ai(
                        topic_name=topic["topic_name"],
                        topic_text=topic["text"],
                    )
                    quiz = _store_parsed_quiz(filename=filename, parsed=parsed_topic)
                    _append_upload_job_quiz(job_id, quiz.to_dict(include_questions=True))
                except Exception as exc:  # pragma: no cover
                    logger.exception("Failed topic '%s' in upload job %s", topic["topic_name"], job_id)
                    _append_upload_job_error(job_id, topic["topic_name"], str(exc))
            _update_upload_job(job_id, status="completed")
        except Exception as exc:  # pragma: no cover
            logger.exception("Upload job %s failed", job_id)
            _update_upload_job(job_id, status="failed")
            _append_upload_job_error(job_id, "job", str(exc))



def _grade_question(question: Question, student_answer: str) -> dict:
    student_answer = student_answer.strip()
    correct_answer = question.correct_answer.strip()

    if not correct_answer:
        return {
            "is_correct": False,
            "status": "incorrect",
            "explanation": "No reliable correct answer was extracted for this question.",
        }

    if question.question_type == "MCQ":
        normalized_student = student_answer.upper()
        normalized_correct = correct_answer.upper()
        is_correct = normalized_student == normalized_correct
        return {
            "is_correct": is_correct,
            "status": "correct" if is_correct else "incorrect",
            "explanation": "Matched the correct option." if is_correct else f"Expected option {normalized_correct}.",
        }

    if not student_answer:
        return {
            "is_correct": False,
            "status": "incorrect",
            "explanation": "No answer was submitted.",
        }

    try:
        grading = grade_answer_with_ai(
            question_text=question.question_text,
            correct_answer=correct_answer,
            student_answer=student_answer,
        )
    except Exception as exc:  # pragma: no cover
        logger.warning("AI grading failed, falling back to exact compare: %s", exc)
        is_correct = student_answer.lower() == correct_answer.lower()
        grading = {
            "is_correct": is_correct,
            "status": "correct" if is_correct else "incorrect",
            "explanation": "Fallback exact match comparison was used.",
        }

    grading.setdefault("is_correct", False)
    grading.setdefault("status", "incorrect")
    grading.setdefault("explanation", "No explanation returned.")
    return grading


app = create_app()


if __name__ == "__main__":
    port = int(os.getenv("PORT", "3000"))
    app.run(host="0.0.0.0", port=port, debug=True)
