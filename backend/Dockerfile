FROM python:3.12-slim

WORKDIR /app

ENV PYTHONDONTWRITEBYTECODE=1
ENV PYTHONUNBUFFERED=1
ENV PORT=3000
ENV GUNICORN_WORKERS=2
ENV GUNICORN_TIMEOUT=300
ENV GUNICORN_GRACEFUL_TIMEOUT=30

COPY requirements.txt ./
RUN pip install --no-cache-dir -r requirements.txt

COPY . .

EXPOSE 3000

CMD ["sh", "-c", "gunicorn --bind 0.0.0.0:${PORT} --workers ${GUNICORN_WORKERS} --timeout ${GUNICORN_TIMEOUT} --graceful-timeout ${GUNICORN_GRACEFUL_TIMEOUT} app:app"]
