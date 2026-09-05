from datetime import datetime, timezone

from flask_sqlalchemy import SQLAlchemy


db = SQLAlchemy()


class Course(db.Model):
    """A course/subject detected from uploaded PDFs."""

    __tablename__ = "courses"

    id = db.Column(db.Integer, primary_key=True)
    name = db.Column(db.String(255), nullable=False, unique=True)
    created_at = db.Column(
        db.DateTime, default=lambda: datetime.now(timezone.utc)
    )

    quizzes = db.relationship(
        "Quiz", backref="course", lazy=True, cascade="all, delete-orphan"
    )

    def to_dict(self):
        return {
            "id": self.id,
            "name": self.name,
            "quiz_count": len(self.quizzes),
            "created_at": self.created_at.isoformat(),
        }


class Quiz(db.Model):
    """A quiz parsed from a single PDF upload."""

    __tablename__ = "quizzes"

    id = db.Column(db.Integer, primary_key=True)
    course_id = db.Column(
        db.Integer, db.ForeignKey("courses.id"), nullable=False
    )
    title = db.Column(db.String(500), nullable=False)
    pdf_filename = db.Column(db.String(255), nullable=False)
    created_at = db.Column(
        db.DateTime, default=lambda: datetime.now(timezone.utc)
    )

    questions = db.relationship(
        "Question", backref="quiz", lazy=True, cascade="all, delete-orphan"
    )
    submissions = db.relationship(
        "Submission", backref="quiz", lazy=True, cascade="all, delete-orphan"
    )

    def to_dict(self, include_questions=False):
        data = {
            "id": self.id,
            "course_id": self.course_id,
            "course_name": self.course.name if self.course else None,
            "title": self.title,
            "pdf_filename": self.pdf_filename,
            "question_count": len(self.questions),
            "mcq_count": sum(
                1 for q in self.questions if q.question_type == "MCQ"
            ),
            "saq_count": sum(
                1 for q in self.questions if q.question_type == "SAQ"
            ),
            "seq_count": sum(
                1 for q in self.questions if q.question_type == "SEQ"
            ),
            "submission_count": len(self.submissions),
            "needs_answer_key": self.needs_answer_key,
            "created_at": self.created_at.isoformat(),
        }
        if include_questions:
            data["questions"] = [q.to_dict() for q in self.questions]
        return data

    @property
    def needs_answer_key(self) -> bool:
        if not self.questions:
            return False
        confirmed_sources = ("explicit_solution", "user_provided", "user_corrected")
        return not any(question.answer_source in confirmed_sources for question in self.questions)


class Question(db.Model):
    """A single question extracted from a PDF quiz."""

    __tablename__ = "questions"

    id = db.Column(db.Integer, primary_key=True)
    quiz_id = db.Column(
        db.Integer, db.ForeignKey("quizzes.id"), nullable=False
    )
    question_type = db.Column(db.String(10), nullable=False)
    section_label = db.Column(db.String(255), nullable=True)
    question_number = db.Column(db.Integer, nullable=False)
    question_text = db.Column(db.Text, nullable=False)

    option_a = db.Column(db.Text, nullable=True)
    option_b = db.Column(db.Text, nullable=True)
    option_c = db.Column(db.Text, nullable=True)
    option_d = db.Column(db.Text, nullable=True)

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
        if self.question_type == "MCQ":
            data["options"] = {
                "a": self.option_a,
                "b": self.option_b,
                "c": self.option_c,
                "d": self.option_d,
            }
        if include_answer:
            data["correct_answer"] = self.correct_answer
            data["has_correct_answer"] = bool(self.correct_answer.strip())
        return data


class Submission(db.Model):
    """A submit-all-at-once attempt for a quiz."""

    __tablename__ = "submissions"

    id = db.Column(db.Integer, primary_key=True)
    quiz_id = db.Column(
        db.Integer, db.ForeignKey("quizzes.id"), nullable=False
    )
    score = db.Column(db.Integer, nullable=False, default=0)
    total_questions = db.Column(db.Integer, nullable=False, default=0)
    created_at = db.Column(
        db.DateTime, default=lambda: datetime.now(timezone.utc)
    )

    answers = db.relationship(
        "SubmissionAnswer",
        backref="submission",
        lazy=True,
        cascade="all, delete-orphan",
    )

    def to_dict(self, include_answers=False):
        data = {
            "id": self.id,
            "quiz_id": self.quiz_id,
            "score": self.score,
            "total_questions": self.total_questions,
            "percentage": (
                round((self.score / self.total_questions) * 100, 2)
                if self.total_questions
                else 0
            ),
            "created_at": self.created_at.isoformat(),
        }
        if include_answers:
            data["answers"] = [answer.to_dict() for answer in self.answers]
        return data


class SubmissionAnswer(db.Model):
    """A graded answer belonging to a submission."""

    __tablename__ = "submission_answers"

    id = db.Column(db.Integer, primary_key=True)
    submission_id = db.Column(
        db.Integer, db.ForeignKey("submissions.id"), nullable=False
    )
    question_id = db.Column(
        db.Integer, db.ForeignKey("questions.id"), nullable=False
    )
    student_answer = db.Column(db.Text, nullable=False)
    is_correct = db.Column(db.Boolean, nullable=False, default=False)
    status = db.Column(db.String(32), nullable=False, default="incorrect")
    explanation = db.Column(db.Text, nullable=True)

    def to_dict(self):
        return {
            "id": self.id,
            "question_id": self.question_id,
            "student_answer": self.student_answer,
            "is_correct": self.is_correct,
            "status": self.status,
            "explanation": self.explanation,
            "question_number": self.question.question_number if self.question else None,
            "question_type": self.question.question_type if self.question else None,
        }


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
