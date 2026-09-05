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
