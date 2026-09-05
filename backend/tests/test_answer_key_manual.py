def _create_quiz_with_gap(course_name="Test Course"):
    from models import Course, Question, Quiz, db

    course = Course(name=course_name)
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
        correct_answer="",
        answer_source="unknown",
    )
    db.session.add(question)
    db.session.commit()
    return quiz.id, question.id


def test_manual_answer_key_updates_question(app, client):
    quiz_id, question_id = _create_quiz_with_gap()

    response = client.post(
        f"/api/quizzes/{quiz_id}/answer-key/manual",
        json={"answers": [{"question_id": question_id, "answer": "42"}]},
    )

    assert response.status_code == 200
    body = response.get_json()
    assert body["applied"] == 1
    assert body["quiz"]["needs_answer_key"] is False
    assert body["quiz"]["questions"][0]["answer_source"] == "user_provided"


def test_manual_answer_key_ignores_unknown_question_ids(app, client):
    quiz_id, _question_id = _create_quiz_with_gap()

    response = client.post(
        f"/api/quizzes/{quiz_id}/answer-key/manual",
        json={"answers": [{"question_id": 99999, "answer": "42"}]},
    )

    assert response.status_code == 200
    assert response.get_json()["applied"] == 0


def test_manual_answer_key_ignores_question_ids_from_other_quizzes(app, client):
    quiz_id, _question_id = _create_quiz_with_gap("Test Course A")
    _other_quiz_id, other_question_id = _create_quiz_with_gap("Test Course B")

    response = client.post(
        f"/api/quizzes/{quiz_id}/answer-key/manual",
        json={"answers": [{"question_id": other_question_id, "answer": "42"}]},
    )

    assert response.status_code == 200
    assert response.get_json()["applied"] == 0


def test_manual_answer_key_disambiguates_same_question_number_across_sections(app, client):
    from models import Course, Question, Quiz, db

    course = Course(name="Test Course")
    db.session.add(course)
    db.session.flush()
    quiz = Quiz(course=course, title="Quiz", pdf_filename="f.pdf")
    db.session.add(quiz)
    db.session.flush()
    mcq_question = Question(
        quiz=quiz,
        question_type="MCQ",
        section_label="Section A",
        question_number=1,
        question_text="MCQ Q1",
        correct_answer="",
        answer_source="unknown",
    )
    saq_question = Question(
        quiz=quiz,
        question_type="SAQ",
        section_label="Section B",
        question_number=1,
        question_text="SAQ Q1",
        correct_answer="",
        answer_source="unknown",
    )
    db.session.add(mcq_question)
    db.session.add(saq_question)
    db.session.commit()
    quiz_id = quiz.id
    mcq_question_id = mcq_question.id
    saq_question_id = saq_question.id

    response = client.post(
        f"/api/quizzes/{quiz_id}/answer-key/manual",
        json={"answers": [{"question_id": saq_question_id, "answer": "The answer"}]},
    )

    assert response.status_code == 200
    body = response.get_json()
    assert body["applied"] == 1

    questions_by_id = {q["id"]: q for q in body["quiz"]["questions"]}
    assert questions_by_id[saq_question_id]["answer_source"] == "user_provided"
    assert questions_by_id[mcq_question_id]["answer_source"] == "unknown"
