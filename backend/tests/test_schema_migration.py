"""Tests for the idempotent startup migration that adds new `Question`
columns to a pre-existing `questions` table (see `_ensure_question_columns`
in app.py). This covers the "upgrade an old quiz.db" scenario that
`db.create_all()` alone can't handle, since it only creates missing
tables and never ALTERs existing ones.
"""

import os
import sqlite3
import tempfile

from sqlalchemy import inspect, text

import config
from app import create_app
from models import db


def test_ensure_question_columns_migrates_pre_existing_table():
    fd, db_path = tempfile.mkstemp(suffix=".db")
    os.close(fd)
    try:
        # Simulate a pre-existing quiz.db from before `answer_source` and
        # `confidence` were added to the Question model: an old-style
        # `questions` table, with a real row of data so we can also assert
        # the migration leaves existing data untouched.
        connection = sqlite3.connect(db_path)
        connection.execute(
            """
            CREATE TABLE questions (
                id INTEGER PRIMARY KEY,
                quiz_id INTEGER NOT NULL,
                question_type VARCHAR(10) NOT NULL,
                section_label VARCHAR(255),
                question_number INTEGER NOT NULL,
                question_text TEXT NOT NULL,
                option_a TEXT,
                option_b TEXT,
                option_c TEXT,
                option_d TEXT,
                correct_answer TEXT NOT NULL
            )
            """
        )
        connection.execute(
            "INSERT INTO questions "
            "(id, quiz_id, question_type, question_number, question_text, correct_answer) "
            "VALUES (1, 1, 'SAQ', 1, 'What is 2+2?', '4')"
        )
        connection.commit()
        connection.close()

        original_uri = config.Config.SQLALCHEMY_DATABASE_URI
        config.Config.SQLALCHEMY_DATABASE_URI = f"sqlite:///{db_path}"
        try:
            app = create_app()
        finally:
            config.Config.SQLALCHEMY_DATABASE_URI = original_uri

        with app.app_context():
            inspector = inspect(db.engine)
            columns = {column["name"] for column in inspector.get_columns("questions")}
            assert "answer_source" in columns
            assert "confidence" in columns

            row = (
                db.session.execute(
                    text(
                        "SELECT question_text, correct_answer, answer_source, confidence "
                        "FROM questions WHERE id = 1"
                    )
                )
                .mappings()
                .first()
            )
            # Existing data is untouched...
            assert row["question_text"] == "What is 2+2?"
            assert row["correct_answer"] == "4"
            # ...and the new columns get the migration's defaults.
            assert row["answer_source"] == "unknown"
            assert row["confidence"] is None

            db.session.remove()
            db.drop_all()
    finally:
        os.remove(db_path)


def test_ensure_question_columns_is_idempotent_on_a_fresh_db():
    """Running the migration against a freshly created (already
    up-to-date) `questions` table must be a no-op, not an error -- this is
    the normal path every server start takes.
    """
    fd, db_path = tempfile.mkstemp(suffix=".db")
    os.close(fd)
    try:
        original_uri = config.Config.SQLALCHEMY_DATABASE_URI
        config.Config.SQLALCHEMY_DATABASE_URI = f"sqlite:///{db_path}"
        try:
            create_app()
            # Calling create_app() again re-runs db.create_all() and the
            # migration check against the now up-to-date schema.
            app = create_app()
        finally:
            config.Config.SQLALCHEMY_DATABASE_URI = original_uri

        with app.app_context():
            inspector = inspect(db.engine)
            columns = {column["name"] for column in inspector.get_columns("questions")}
            assert "answer_source" in columns
            assert "confidence" in columns
            db.session.remove()
            db.drop_all()
    finally:
        os.remove(db_path)
