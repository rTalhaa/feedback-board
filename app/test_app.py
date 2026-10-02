import app as dashboard

ITEMS = [
    {"id": "1", "message": "<b>fast</b>", "rating": 5, "created": 2},
    {"id": "2", "message": "slow", "rating": 2, "created": 1},
]


class FakeTable:
    def scan(self, **kw):
        return {"Items": ITEMS}


def client(monkeypatch):
    monkeypatch.setattr(dashboard, "table", lambda: FakeTable())
    return dashboard.app.test_client()


def test_health(monkeypatch):
    assert client(monkeypatch).get("/health").json["status"] == "ok"


def test_summary(monkeypatch):
    s = client(monkeypatch).get("/api/summary").json
    assert s["count"] == 2 and s["average"] == 3.5 and s["recent"][0]["id"] == "1"


def test_index_escapes_html(monkeypatch):
    html = client(monkeypatch).get("/").get_data(as_text=True)
    assert "&lt;b&gt;fast" in html and "<b>fast" not in html


def test_empty_table():
    assert dashboard.summary([]) == {"count": 0, "average": 0, "recent": []}
