import os
from dotenv import load_dotenv

load_dotenv()


BASE_DIR = os.path.dirname(os.path.abspath(__file__))
INSTANCE_DIR = os.path.join(BASE_DIR, "instance")
DEFAULT_SQLITE_PATH = os.path.join(INSTANCE_DIR, "quiz.db")


def _normalize_database_url(database_url: str) -> str:
    if database_url == "sqlite:///quiz.db":
        return f"sqlite:///{DEFAULT_SQLITE_PATH}"
    return database_url


class Config:
    """Application configuration loaded from environment variables."""

    SECRET_KEY = os.getenv("SECRET_KEY", "dev-secret-key-change-in-production")
    SQLALCHEMY_DATABASE_URI = _normalize_database_url(
        os.getenv("DATABASE_URL", f"sqlite:///{DEFAULT_SQLITE_PATH}")
    )
    SQLALCHEMY_TRACK_MODIFICATIONS = False

    UPLOAD_FOLDER = os.path.join(
        os.path.dirname(os.path.abspath(__file__)), "uploads"
    )
    MAX_CONTENT_LENGTH = 50 * 1024 * 1024  # 50MB max upload

    GEMINI_API_KEY = os.getenv("GEMINI_API_KEY", "")
    GEMINI_MODEL = os.getenv("GEMINI_MODEL", "gemini-3-flash-preview")
    GEMINI_PARSE_BATCH_CHARS = int(
        os.getenv("GEMINI_PARSE_BATCH_CHARS", "6000")
    )
    GEMINI_REQUEST_TIMEOUT = int(
        os.getenv("GEMINI_REQUEST_TIMEOUT", "30")
    )
    TESSERACT_CMD = os.getenv("TESSERACT_CMD", "")
