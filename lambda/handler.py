"""Feedback API: GET/POST /api/feedback behind API Gateway (HTTP API, payload v2)."""
import json
import os
import time
import uuid

import boto3

TABLE = os.environ.get("TABLE_NAME", "feedback")
_table = None


def table():
    global _table
    if _table is None:
        _table = boto3.resource("dynamodb").Table(TABLE)
    return _table


def log(level, msg, **kw):
    # One JSON line per event, so CloudWatch metric filters can match on fields.
    print(json.dumps({"level": level, "msg": msg, **kw}))


def reply(status, body):
    return {"statusCode": status, "headers": {"content-type": "application/json"}, "body": json.dumps(body)}


def validate(body):
    """Return (item, error). Trust boundary: everything from the client is checked here."""
    try:
        data = json.loads(body or "{}")
    except json.JSONDecodeError:
        return None, "body must be JSON"
    message = str(data.get("message", "")).strip()
    rating = data.get("rating")
    if not message or len(message) > 500:
        return None, "message is required (1-500 chars)"
    if not isinstance(rating, int) or not 1 <= rating <= 5:
        return None, "rating must be an integer 1-5"
    return {"id": str(uuid.uuid4()), "message": message, "rating": rating, "created": int(time.time())}, None


def handler(event, context):
    start = time.time()
    method = event.get("requestContext", {}).get("http", {}).get("method", "GET")
    try:
        if method == "POST":
            item, err = validate(event.get("body"))
            if err:
                log("WARN", "validation failed", error=err)
                return reply(400, {"error": err})
            table().put_item(Item=item)
            status, body = 201, item
        else:
            # NOTE: full scan, fine for a demo table; switch to a GSI query past a few thousand items.
            items = table().scan(Limit=100)["Items"]
            for i in items:
                i["rating"], i["created"] = int(i["rating"]), int(i["created"])
            status, body = 200, sorted(items, key=lambda i: i["created"], reverse=True)
        log("INFO", "request", method=method, status=status, latency_ms=round((time.time() - start) * 1000))
        return reply(status, body)
    except Exception as e:
        log("ERROR", "request failed", method=method, error=str(e))
        return reply(500, {"error": "internal error"})


if __name__ == "__main__":
    assert validate('{"message":"great","rating":5}')[1] is None
    assert validate('{"message":"","rating":5}')[1]
    assert validate('{"message":"ok","rating":9}')[1]
    assert validate('{"message":"ok","rating":"5"}')[1]
    assert validate("not json")[1]
    assert validate('{"message":"' + "x" * 501 + '","rating":1}')[1]
    print("handler self-check ok")
