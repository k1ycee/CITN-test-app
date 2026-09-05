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
