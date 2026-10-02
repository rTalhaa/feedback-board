"""Feedback dashboard: summary of the feedback table, served from ECS Fargate behind an ALB."""
import json
import logging
import os
import time
from html import escape

import boto3
from flask import Flask, g, request

VERSION = os.environ.get("APP_VERSION", "dev")
TABLE = os.environ.get("TABLE_NAME", "feedback")

app = Flask(__name__)
logging.getLogger("werkzeug").disabled = True
_table = None


def table():
    global _table
    if _table is None:
        _table = boto3.resource("dynamodb").Table(TABLE)
    return _table


_db = None


def visits():
    """Count dashboard visits in RDS. EC2 track only: skipped when DB_SECRET_ARN is unset (ECS/EKS)."""
    global _db
    arn = os.environ.get("DB_SECRET_ARN")
    if not arn:
        return None
    try:
        if _db is None:
            import psycopg
            secret = json.loads(boto3.client("secretsmanager").get_secret_value(SecretId=arn)["SecretString"])
            _db = psycopg.connect(host=os.environ["DB_HOST"], dbname="postgres", user=secret["username"],
                                  password=secret["password"], sslmode="require", autocommit=True)
            _db.execute("CREATE TABLE IF NOT EXISTS visits (at timestamptz NOT NULL DEFAULT now())")
        _db.execute("INSERT INTO visits DEFAULT VALUES")
        return _db.execute("SELECT count(*) FROM visits").fetchone()[0]
    except Exception:
        _db = None  # reconnect on next request
        raise


def summary(items):
    ratings = [int(i["rating"]) for i in items]
    return {
        "count": len(ratings),
        "average": round(sum(ratings) / len(ratings), 2) if ratings else 0,
        "recent": sorted(items, key=lambda i: int(i["created"]), reverse=True)[:10],
    }


@app.before_request
def _start():
    g.start = time.time()


@app.after_request
def _log(resp):
    # JSON access log -> CloudWatch metric filters on status/latency.
    print(json.dumps({"level": "ERROR" if resp.status_code >= 500 else "INFO", "msg": "request",
                      "path": request.path, "status": resp.status_code,
                      "latency_ms": round((time.time() - g.start) * 1000), "version": VERSION}), flush=True)
    return resp


@app.get("/health")
def health():
    return {"status": "ok", "version": VERSION}


@app.get("/api/summary")
def api_summary():
    s = summary(table().scan(Limit=500)["Items"])
    s["recent"] = [{**i, "rating": int(i["rating"]), "created": int(i["created"])} for i in s["recent"]]
    return s


@app.get("/")
def index():
    s = summary(table().scan(Limit=500)["Items"])
    n = visits()
    seen = f" &middot; dashboard visits <b>{n}</b> (RDS)" if n is not None else ""
    rows = "".join(f"<tr><td>{'★' * int(i['rating'])}</td><td>{escape(i['message'])}</td></tr>" for i in s["recent"])
    return f"""<!doctype html><meta charset="utf-8"><title>Feedback Dashboard</title>
<style>body{{font-family:system-ui;max-width:720px;margin:40px auto;padding:0 16px}}
td{{padding:6px 10px;border-bottom:1px solid #ddd}}.v{{color:#888;font-size:12px}}</style>
<h1>Feedback Dashboard</h1>
<p><b>{s['count']}</b> responses &middot; average rating <b>{s['average']}</b>{seen}</p>
<table>{rows or '<tr><td>No feedback yet</td></tr>'}</table>
<p class="v">version {escape(VERSION)}</p>"""


@app.errorhandler(Exception)
def _err(e):
    print(json.dumps({"level": "ERROR", "msg": "unhandled", "error": str(e), "path": request.path}), flush=True)
    return {"error": "internal error"}, 500
