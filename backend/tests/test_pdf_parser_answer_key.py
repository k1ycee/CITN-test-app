import json


def test_parse_answer_key_document_extracts_answers_by_number(monkeypatch):
    from pdf_parser import parse_answer_key_document

    monkeypatch.setattr("pdf_parser._ensure_gemini", lambda: None)
    monkeypatch.setattr(
        "pdf_parser.extract_pages_from_pdf", lambda path: ["1. B\n2. Supply and demand"]
    )

    class _FakeResponse:
        text = json.dumps(
            {
                "answers": [
                    {"question_number": 1, "answer": "B"},
                    {"question_number": 2, "answer": "Supply and demand"},
                ]
            }
        )

    class _FakeModel:
        def generate_content(self, prompt, request_options=None):
            return _FakeResponse()

    monkeypatch.setattr("pdf_parser._build_model", lambda: _FakeModel())

    assert parse_answer_key_document("fake.pdf") == {1: "B", 2: "Supply and demand"}


def test_parse_answer_key_document_returns_empty_on_failure(monkeypatch):
    from pdf_parser import parse_answer_key_document

    monkeypatch.setattr("pdf_parser._ensure_gemini", lambda: None)
    monkeypatch.setattr("pdf_parser.extract_pages_from_pdf", lambda path: ["garbled ocr text"])

    class _FailingModel:
        def generate_content(self, prompt, request_options=None):
            raise RuntimeError("gemini down")

    monkeypatch.setattr("pdf_parser._build_model", lambda: _FailingModel())

    assert parse_answer_key_document("fake.pdf") == {}
