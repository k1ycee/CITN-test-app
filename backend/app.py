import logging
import os
from pathlib import Path

from flask import Flask, jsonify, request
from flask_cors import CORS
from werkzeug.utils import secure_filename

from config import Config
from models import Course, Question, Quiz, Submission, SubmissionAnswer, db
from pdf_parser import grade_answer_with_ai, parse_pdf_with_ai

ALLOWED_EXTENSIONS = {"pdf"}

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

    upload_dir = Path(app.config["UPLOAD_FOLDER"])
    upload_dir.mkdir(parents=True, exist_ok=True)

    with app.app_context():
        db.create_all()

    register_routes(app)
    return app


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

        try:
            parsed = parse_pdf_with_ai(str(destination))
            quiz = _store_parsed_quiz(filename=filename, parsed=parsed)
        except Exception as exc:  # pragma: no cover - defensive API guard
            logger.exception("Failed to parse uploaded PDF")
            return jsonify({"error": str(exc)}), 500

        return jsonify(quiz.to_dict(include_questions=True)), 201

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
            grading = _grade_question(question, student_answer)
            if grading["is_correct"]:
                score += 1

            submission_answer = SubmissionAnswer(
                submission=submission,
                question=question,
                student_answer=student_answer,
                is_correct=grading["is_correct"],
                status=grading["status"],
                explanation=grading.get("explanation", ""),
            )
            db.session.add(submission_answer)

            results.append(
                {
                    "question_id": question.id,
                    "question_number": question.question_number,
                    "question_type": question.question_type,
                    "student_answer": student_answer,
                    "is_correct": grading["is_correct"],
                    "status": grading["status"],
                    "explanation": grading.get("explanation", ""),
                }
            )

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


def _allowed_file(filename: str) -> bool:
    return "." in filename and filename.rsplit(".", 1)[1].lower() in ALLOWED_EXTENSIONS


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
        for question_data in section.get("questions", []):
            options = question_data.get("options") or {}
            question = Question(
                quiz=quiz,
                question_type=question_type,
                section_label=label,
                question_number=int(question_data.get("number", 0)),
                question_text=(question_data.get("text") or "").strip(),
                option_a=options.get("a"),
                option_b=options.get("b"),
                option_c=options.get("c"),
                option_d=options.get("d"),
                correct_answer=str(question_data.get("correct_answer", "")).strip(),
            )
            db.session.add(question)

    db.session.commit()
    return quiz


def _grade_question(question: Question, student_answer: str) -> dict:
    student_answer = student_answer.strip()

    if question.question_type == "MCQ":
        normalized_student = student_answer.upper()
        normalized_correct = question.correct_answer.strip().upper()
        is_correct = normalized_student == normalized_correct
        return {
            "is_correct": is_correct,
            "status": "correct" if is_correct else "incorrect",
            "explanation": (
                "Matched the correct option."
                if is_correct
                else f"Expected option {normalized_correct}."
            ),
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
            correct_answer=question.correct_answer,
            student_answer=student_answer,
        )
    except Exception as exc:  # pragma: no cover - external dependency guard
        logger.warning("AI grading failed, falling back to exact compare: %s", exc)
        is_correct = student_answer.lower() == question.correct_answer.strip().lower()
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
    port = int(os.getenv("PORT", "5000"))
    app.run(host="0.0.0.0", port=port, debug=True)
