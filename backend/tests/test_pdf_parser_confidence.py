def test_normalize_question_clamps_confidence_for_ai_inferred():
    from pdf_parser import _normalize_question

    result = _normalize_question(
        "SAQ",
        {
            "number": 3,
            "text": "Explain X",
            "correct_answer": "Because Y",
            "answer_source": "ai_inferred",
            "confidence": 150,
        },
    )

    assert result["answer_source"] == "ai_inferred"
    assert result["confidence"] == 100


def test_normalize_question_has_no_confidence_for_explicit_solution():
    from pdf_parser import _normalize_question

    result = _normalize_question(
        "SAQ",
        {
            "number": 1,
            "text": "Explain X",
            "correct_answer": "Because Y",
            "answer_source": "explicit_solution",
        },
    )

    assert result["confidence"] is None


def test_question_rank_prefers_higher_confidence_among_ai_inferred():
    from pdf_parser import _question_rank

    low_confidence = {"answer_source": "ai_inferred", "correct_answer": "A", "confidence": 40}
    high_confidence = {"answer_source": "ai_inferred", "correct_answer": "A", "confidence": 90}

    assert _question_rank(high_confidence) > _question_rank(low_confidence)


def test_merge_batch_results_carries_confidence_of_winning_answer():
    from pdf_parser import _merge_batch_results

    batch_one = {
        "course_name": "Econ",
        "quiz_title": "Econ Quiz",
        "sections": [
            {
                "type": "SAQ",
                "label": "SAQ",
                "questions": [
                    {
                        "number": 1,
                        "text": "Explain X",
                        "correct_answer": "guess A",
                        "answer_source": "ai_inferred",
                        "confidence": 30,
                    }
                ],
            }
        ],
    }
    batch_two = {
        "course_name": "Econ",
        "quiz_title": "Econ Quiz",
        "sections": [
            {
                "type": "SAQ",
                "label": "SAQ",
                "questions": [
                    {
                        "number": 1,
                        "text": "Explain X",
                        "correct_answer": "guess B",
                        "answer_source": "ai_inferred",
                        "confidence": 85,
                    }
                ],
            }
        ],
    }

    merged = _merge_batch_results([batch_one, batch_two], "Econ")

    question = merged["sections"][0]["questions"][0]
    assert question["correct_answer"] == "guess B"
    assert question["confidence"] == 85
