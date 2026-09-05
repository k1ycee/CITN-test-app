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
