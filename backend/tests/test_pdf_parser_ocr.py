class _FakePage:
    def __init__(self, text, raise_on_pixmap=False):
        self._text = text
        self._raise_on_pixmap = raise_on_pixmap

    def get_text(self, mode):
        return self._text

    def get_pixmap(self, dpi=None):
        if self._raise_on_pixmap:
            raise RuntimeError("Failed to render page (corrupt PDF or MuPDF error)")
        raise NotImplementedError("Should not be called in tests with mocked _ocr_page")


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


def test_extract_page_text_gracefully_handles_render_failure(monkeypatch):
    """Verifies that when page rendering fails inside _ocr_page (e.g. corrupt page or MuPDF error), the exception is caught and _extract_page_text falls back to the original text instead of propagating."""
    from pdf_parser import _extract_page_text

    # Mock pytesseract so it's not actually called
    monkeypatch.setattr("pdf_parser.pytesseract.image_to_string", lambda img: "should not reach here")

    # Use a fake page that raises when get_pixmap is called (simulating render failure)
    # This tests that the try/except in _ocr_page catches the rendering error
    fake_page = _FakePage("  ", raise_on_pixmap=True)

    # Should not raise, should fall back to original sparse text
    text, used_ocr = _extract_page_text(fake_page)

    assert used_ocr is False
    assert text == ""
