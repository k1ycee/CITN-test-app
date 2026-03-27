# Task Progress

## Goal
Build the agreed PDF Quiz System with a Flask backend and Flutter frontend using Gemini for parsing and AI grading.

## Status

- [x] Define data model for courses, quizzes, questions, submissions, and answers
- [x] Add Flask app entrypoint and REST API routes
- [x] Persist parsed quiz data in SQLite
- [x] Support PDF uploads and Gemini-based parsing
- [x] Implement submit-all-at-once grading flow
- [x] Replace Flutter starter app with quiz workflow UI
- [x] Add project setup documentation
- [x] Add Docker deployment files
- [ ] Add automated backend tests
- [ ] Add richer frontend state management / offline handling
- [ ] Add auth / user profiles if multi-user usage is required

## Current Scope Decisions

- Single shared SQLite database
- No authentication yet
- Flutter app targets local backend at `127.0.0.1:5000`
- File selection is implemented for desktop/mobile supported by `file_selector`
