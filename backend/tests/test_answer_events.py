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
