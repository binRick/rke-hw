"""Gunicorn entrypoint: ensure the schema exists, then expose the app."""
from app import app, init_db

init_db()  # idempotent; get_pool() retries while Postgres is starting

if __name__ == "__main__":
    app.run(host="0.0.0.0", port=8080)
