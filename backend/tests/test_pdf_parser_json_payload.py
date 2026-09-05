import json


def test_extract_json_payload_parses_top_level_array():
    """Mirrors segment_topics_with_ai's Gemini response shape: a top-level
    JSON array. The full list must be returned, not just its first element."""
    from pdf_parser import _extract_json_payload

    raw_text = json.dumps(
        [
            {"topic_name": "Business Law", "start_page": 1, "end_page": 2},
            {"topic_name": "Economics", "start_page": 3, "end_page": 3},
        ]
    )

    payload = _extract_json_payload(raw_text)

    assert payload == [
        {"topic_name": "Business Law", "start_page": 1, "end_page": 2},
        {"topic_name": "Economics", "start_page": 3, "end_page": 3},
    ]


def test_extract_json_payload_parses_top_level_object_with_nested_array():
    """Mirrors _parse_batch's Gemini response shape: a top-level JSON object
    whose only array-valued field is "sections". The full object must be
    returned intact, not collapsed to just the nested "sections" array."""
    from pdf_parser import _extract_json_payload

    raw_text = json.dumps(
        {
            "course_name": "Business Law",
            "quiz_title": "Foundations of Business Law",
            "sections": [
                {
                    "type": "MCQ",
                    "label": "SECTION A",
                    "questions": [{"number": 1, "text": "Q1", "correct_answer": "A"}],
                }
            ],
        }
    )

    payload = _extract_json_payload(raw_text)

    assert isinstance(payload, dict)
    assert payload["course_name"] == "Business Law"
    assert payload["quiz_title"] == "Foundations of Business Law"
    assert len(payload["sections"]) == 1
    assert payload["sections"][0]["type"] == "MCQ"
