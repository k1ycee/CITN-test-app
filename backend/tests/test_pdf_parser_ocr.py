class _FakePage:
    def __init__(self, text):
        self._text = text

    def get_text(self, mode):
        return self._text


def test_extract_page_text_uses_ocr_when_text_layer_is_sparse(monkeypatch):
    from pdf_parser import _extract_page_text

    monkeypatch.setattr("pdf_parser._ocr_page", lambda page: "ocr recovered text")

    text, used_ocr = _extract_page_text(_FakePage("  "))

    assert used_ocr is True
    assert text == "ocr recovered text"


def test_extract_page_text_keeps_existing_text_layer(monkeypatch):
    from pdf_parser import _extract_page_text

    def _fail(page):
        raise AssertionError("OCR should not run when a text layer exists")

    monkeypatch.setattr("pdf_parser._ocr_page", _fail)

    text, used_ocr = _extract_page_text(_FakePage("Plenty of real extracted text here."))

    assert used_ocr is False
    assert text == "Plenty of real extracted text here."
