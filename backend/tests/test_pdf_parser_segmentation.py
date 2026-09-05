import json


def test_segment_topics_with_ai_returns_ai_boundaries(monkeypatch):
    from pdf_parser import segment_topics_with_ai

    monkeypatch.setattr("pdf_parser._ensure_gemini", lambda: None)

    class _FakeResponse:
        text = json.dumps(
            [
                {"topic_name": "Business Law", "start_page": 1, "end_page": 2},
                {"topic_name": "Economics", "start_page": 3, "end_page": 3},
            ]
        )

    class _FakeModel:
        def generate_content(self, prompt, request_options=None):
            return _FakeResponse()

    monkeypatch.setattr("pdf_parser._build_model", lambda: _FakeModel())

    segments = segment_topics_with_ai(["page one", "page two", "page three"])

    assert segments == [
        {"topic_name": "Business Law", "start_page": 1, "end_page": 2},
        {"topic_name": "Economics", "start_page": 3, "end_page": 3},
    ]


def test_segment_topics_with_ai_falls_back_to_empty_on_failure(monkeypatch):
    from pdf_parser import segment_topics_with_ai

    monkeypatch.setattr("pdf_parser._ensure_gemini", lambda: None)

    class _FailingModel:
        def generate_content(self, prompt, request_options=None):
            raise RuntimeError("gemini is down")

    monkeypatch.setattr("pdf_parser._build_model", lambda: _FailingModel())

    assert segment_topics_with_ai(["page one"]) == []


def test_extract_topic_segments_from_pdf_falls_back_to_single_segment(monkeypatch):
    from pdf_parser import extract_topic_segments_from_pdf

    monkeypatch.setattr("pdf_parser.extract_pages_from_pdf", lambda path: ["p1 text", "p2 text"])
    monkeypatch.setattr("pdf_parser.segment_topics_with_ai", lambda pages: [])

    segments = extract_topic_segments_from_pdf("fake.pdf")

    assert len(segments) == 1
    assert segments[0]["topic_name"] == "Unknown Course"
    assert "p1 text" in segments[0]["text"]
    assert "p2 text" in segments[0]["text"]


def test_extract_topic_segments_from_pdf_slices_by_ai_page_ranges(monkeypatch):
    from pdf_parser import extract_topic_segments_from_pdf

    monkeypatch.setattr(
        "pdf_parser.extract_pages_from_pdf", lambda path: ["law text", "law text 2", "econ text"]
    )
    monkeypatch.setattr(
        "pdf_parser.segment_topics_with_ai",
        lambda pages: [
            {"topic_name": "Business Law", "start_page": 1, "end_page": 2},
            {"topic_name": "Economics", "start_page": 3, "end_page": 3},
        ],
    )

    segments = extract_topic_segments_from_pdf("fake.pdf")

    assert [segment["topic_name"] for segment in segments] == ["Business Law", "Economics"]
    assert "law text" in segments[0]["text"]
    assert "law text 2" in segments[0]["text"]
    assert "econ text" not in segments[0]["text"]
    assert "econ text" in segments[1]["text"]
