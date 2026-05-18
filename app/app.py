"""
hello-db — a tiny Flask guestbook backed by PostgreSQL.

Everything is configured via environment variables (set by the Helm chart):
  DB_HOST, DB_PORT, DB_NAME, DB_USER, DB_PASSWORD

Routes:
  GET  /            HTML page: visit count + last messages + a form
  POST /add         add a guestbook message (form field: message)
  GET  /healthz     liveness  (process is up)        -> 200
  GET  /readyz      readiness (DB reachable + ready)  -> 200/503
  GET  /api/messages  JSON list of messages
"""
import os
import time

import psycopg2
from flask import Flask, jsonify, redirect, request
from psycopg2.pool import SimpleConnectionPool

DB_CONFIG = {
    "host": os.environ.get("DB_HOST", "localhost"),
    "port": int(os.environ.get("DB_PORT", "5432")),
    "dbname": os.environ.get("DB_NAME", "hello"),
    "user": os.environ.get("DB_USER", "hello"),
    "password": os.environ.get("DB_PASSWORD", "hello"),
}

app = Flask(__name__)
_pool = None


def get_pool():
    """Lazily build a small connection pool, retrying while PG starts up."""
    global _pool
    if _pool is None:
        last_err = None
        for _ in range(30):
            try:
                _pool = SimpleConnectionPool(1, 5, **DB_CONFIG)
                break
            except psycopg2.OperationalError as exc:  # PG not ready yet
                last_err = exc
                time.sleep(2)
        if _pool is None:
            raise RuntimeError(f"could not connect to Postgres: {last_err}")
    return _pool


def init_db():
    pool = get_pool()
    conn = pool.getconn()
    try:
        with conn, conn.cursor() as cur:
            cur.execute(
                """
                CREATE TABLE IF NOT EXISTS messages (
                    id      SERIAL PRIMARY KEY,
                    body    TEXT NOT NULL,
                    created TIMESTAMPTZ NOT NULL DEFAULT now()
                );
                CREATE TABLE IF NOT EXISTS visits (
                    id    INT PRIMARY KEY DEFAULT 1,
                    count BIGINT NOT NULL DEFAULT 0
                );
                INSERT INTO visits (id, count) VALUES (1, 0)
                    ON CONFLICT (id) DO NOTHING;
                """
            )
    finally:
        pool.putconn(conn)


PAGE = """<!doctype html>
<title>hello-db</title>
<style>
 body{{font-family:system-ui,sans-serif;max-width:40rem;margin:3rem auto;padding:0 1rem}}
 li{{margin:.3rem 0}} input[type=text]{{width:70%;padding:.4rem}}
 button{{padding:.4rem .8rem}} small{{color:#666}}
</style>
<h1>hello-db &#128075;</h1>
<p>This page has been served <b>{visits}</b> times — all from RKE2,
fully offline (Flask + PostgreSQL).</p>
<form method="post" action="/add">
  <input type="text" name="message" placeholder="leave a message" required>
  <button>Sign</button>
</form>
<h2>Guestbook</h2>
<ul>{items}</ul>
<small>{host}</small>
"""


@app.route("/")
def index():
    pool = get_pool()
    conn = pool.getconn()
    try:
        with conn, conn.cursor() as cur:
            cur.execute("UPDATE visits SET count = count + 1 WHERE id = 1 RETURNING count;")
            visits = cur.fetchone()[0]
            cur.execute("SELECT body, created FROM messages ORDER BY id DESC LIMIT 20;")
            rows = cur.fetchall()
    finally:
        pool.putconn(conn)
    items = "".join(
        f"<li>{_esc(body)} <small>{created:%Y-%m-%d %H:%M}</small></li>"
        for body, created in rows
    ) or "<li><small>no messages yet — be the first!</small></li>"
    return PAGE.format(visits=visits, items=items, host=os.environ.get("HOSTNAME", "?"))


@app.route("/add", methods=["POST"])
def add():
    body = (request.form.get("message") or "").strip()[:280]
    if body:
        pool = get_pool()
        conn = pool.getconn()
        try:
            with conn, conn.cursor() as cur:
                cur.execute("INSERT INTO messages (body) VALUES (%s);", (body,))
        finally:
            pool.putconn(conn)
    return redirect("/")


@app.route("/api/messages")
def api_messages():
    pool = get_pool()
    conn = pool.getconn()
    try:
        with conn, conn.cursor() as cur:
            cur.execute("SELECT id, body, created FROM messages ORDER BY id DESC LIMIT 100;")
            rows = cur.fetchall()
    finally:
        pool.putconn(conn)
    return jsonify([{"id": i, "body": b, "created": c.isoformat()} for i, b, c in rows])


@app.route("/healthz")
def healthz():
    return "ok", 200


@app.route("/readyz")
def readyz():
    try:
        pool = get_pool()
        conn = pool.getconn()
        try:
            with conn.cursor() as cur:
                cur.execute("SELECT 1;")
        finally:
            pool.putconn(conn)
        return "ready", 200
    except Exception as exc:  # noqa: BLE001 - report any DB failure as not-ready
        return f"not ready: {exc}", 503


def _esc(s: str) -> str:
    return (
        s.replace("&", "&amp;")
        .replace("<", "&lt;")
        .replace(">", "&gt;")
        .replace('"', "&quot;")
    )


if __name__ == "__main__":
    init_db()
    app.run(host="0.0.0.0", port=8080)
