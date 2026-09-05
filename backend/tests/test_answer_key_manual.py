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
