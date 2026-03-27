# PDF Quiz System

Flutter frontend + Flask backend for uploading exam PDFs, parsing questions with Gemini, and grading a submit-all-at-once quiz flow.

## Implemented

- Flask API with SQLite persistence
- PDF upload endpoint
- PyMuPDF + Gemini parsing pipeline
- MCQ / SAQ / SEQ question storage
- Submit-all-at-once grading flow
- Flutter desktop/mobile UI for quiz browsing, answering, and submission
- Dockerfile + docker-compose setup
- `task.md` progress tracker

## Project Structure

- `backend/` Flask app, models, parser, config
- `lib/main.dart` Flutter UI and API client
- `task.md` execution progress against the agreed plan

## Backend Setup

```bash
cd backend
python3 -m venv .venv
source .venv/bin/activate
pip install -r requirements.txt
cp .env.example .env
python app.py
```

Backend runs on `http://127.0.0.1:5000` by default.

Required env vars:

- `GEMINI_API_KEY`
- `GEMINI_MODEL` optional, defaults to `gemini-2.0-flash`
- `DATABASE_URL` optional, defaults to SQLite `quiz.db`

## Flutter Setup

```bash
flutter pub get
flutter run -d macos
```

The Flutter app expects the backend at `http://127.0.0.1:5000/api`.

## API Endpoints

- `GET /api/health`
- `GET /api/courses`
- `GET /api/quizzes`
- `GET /api/quizzes/<id>`
- `POST /api/upload`
- `POST /api/quizzes/<id>/submit`

## Docker

```bash
docker compose up --build
```

Services:

- `backend`: Flask API on port `5000`
- `flutter`: optional Flutter web/dev container on port `3000`

## Notes

- SAQ/SEQ grading uses Gemini semantic evaluation with an exact-match fallback.
- Uploaded PDFs are stored in `backend/uploads/`.
- SQLite data persists in `backend/quiz.db` unless you override `DATABASE_URL`.
