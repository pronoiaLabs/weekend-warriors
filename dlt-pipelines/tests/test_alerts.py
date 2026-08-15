"""The alert path must ping on transitions, stay silent otherwise, and never raise.

WHY THIS EXISTS
    alerts.report() runs inside the failure handling of every scheduled pipeline,
    which is the worst possible place for a bug: an exception here would replace
    the error being reported, and a wrong transition decision either spams the
    channel until it gets muted (recreating the silent-outage problem with extra
    steps) or swallows the one ping that mattered.

    The decision logic is pure (`decide`, `format_message`), so the whole
    ping/no-ping matrix is asserted without a connection. The plumbing tests use
    a fake connection to pin the call sequence: state read first, send only on a
    transition, latch write after the send (a failed write may duplicate a ping;
    a failed send must never mark the latch as alerted).

    No dlt and no connector needed: alerts imports lazily, exactly so the DuckDB
    and YAML paths work on a machine without snowflake-connector-python.
"""
from __future__ import annotations

import sys
from pathlib import Path

import pytest

_ROOT = Path(__file__).parent.parent.resolve()
if str(_ROOT) not in sys.path:
    sys.path.insert(0, str(_ROOT))

from pipelines.common import alerts, snowflake_session  # noqa: E402

# ---------------------------------------------------------------------------
# The transition matrix, exhaustively. This IS the noise policy.
# ---------------------------------------------------------------------------


@pytest.mark.parametrize(
    ("prev", "ok", "expected"),
    [
        # A scope never seen before that fails must ping: "first failure ever"
        # is exactly a healthy->failing transition.
        (None, False, "fail"),
        ("ok", False, "fail"),
        # A streak stays silent after the first ping.
        ("failing", False, None),
        # Recovery pings once, and only from a failing state.
        ("failing", True, "recover"),
        ("ok", True, None),
        (None, True, None),
    ],
)
def test_decide_matrix(prev: str | None, ok: bool, expected: str | None) -> None:
    assert alerts.decide(prev, ok) == expected


def test_message_flattens_and_truncates() -> None:
    # A multi-line traceback would bury the scope name in Slack; a full one
    # would blow past what a phone notification shows. TASK_HISTORY keeps the
    # complete text, so the message only needs to identify and summarize.
    msg = alerts.format_message("nfl_stats", ok=False, error="a\nb\t c" + "x" * 1000)
    assert msg.startswith("FAILED nfl_stats: a b cx")
    assert len(msg) <= len("FAILED nfl_stats: ") + 400
    assert "\n" not in msg

    assert alerts.format_message("nfl_stats", ok=True) == "RECOVERED nfl_stats"
    assert alerts.format_message("runner", ok=False, error=None) == (
        "FAILED runner: unknown error"
    )


# ---------------------------------------------------------------------------
# Plumbing, against a fake connection
# ---------------------------------------------------------------------------


class _FakeCursor:
    def __init__(self, prev_status: str | None) -> None:
        self._prev = prev_status
        self.executed: list[tuple[str, tuple]] = []

    def execute(self, sql: str, params: tuple = ()) -> None:
        self.executed.append((sql, params))

    def fetchone(self):
        return (self._prev,) if self._prev is not None else None


class _FakeConn:
    def __init__(self, prev_status: str | None) -> None:
        self.cur = _FakeCursor(prev_status)
        self.committed = False
        self.closed = False

    def cursor(self) -> _FakeCursor:
        return self.cur

    def commit(self) -> None:
        self.committed = True

    def close(self) -> None:
        self.closed = True


def _sends(cur: _FakeCursor) -> list[str]:
    return [sql for sql, _ in cur.executed if "SEND_SNOWFLAKE_NOTIFICATION" in sql]


def _merges(cur: _FakeCursor) -> list[str]:
    return [sql for sql, _ in cur.executed if sql.startswith("MERGE")]


@pytest.fixture
def wired(monkeypatch: pytest.MonkeyPatch):
    """Enable alerting and route connect() at a fake; returns the factory."""
    monkeypatch.setenv("DLT_ALERTS", "1")

    def factory(prev_status: str | None) -> _FakeConn:
        conn = _FakeConn(prev_status)
        monkeypatch.setattr(snowflake_session, "connect", lambda: conn)
        return conn

    return factory


def test_disabled_never_touches_the_connection(monkeypatch: pytest.MonkeyPatch) -> None:
    # The default everywhere except the prod job template. A laptop run must not
    # even attempt a connection, let alone ping.
    monkeypatch.delenv("DLT_ALERTS", raising=False)

    def bomb() -> None:
        raise AssertionError("connect() must not be called when alerting is off")

    monkeypatch.setattr(snowflake_session, "connect", bomb)
    alerts.report("nfl_stats", ok=False, error="boom")


def test_report_never_raises(monkeypatch: pytest.MonkeyPatch) -> None:
    # The caller is inside an except block about to re-raise the REAL error;
    # anything escaping report() would replace it.
    monkeypatch.setenv("DLT_ALERTS", "1")

    def broken():
        raise RuntimeError("no network")

    monkeypatch.setattr(snowflake_session, "connect", broken)
    alerts.report("nfl_stats", ok=False, error="boom")  # must not raise


def test_first_failure_sends_then_latches(wired) -> None:
    conn = wired(None)
    alerts.report("nfl_stats", ok=False, error="HTTP 500")

    assert len(_sends(conn.cur)) == 1
    assert len(_merges(conn.cur)) == 1
    # Send BEFORE latch: a failed latch write duplicates a ping next run, which
    # beats a latch claiming a ping that never left.
    send_i = next(i for i, (s, _) in enumerate(conn.cur.executed) if "SEND" in s)
    merge_i = next(i for i, (s, _) in enumerate(conn.cur.executed) if s.startswith("MERGE"))
    assert send_i < merge_i
    assert conn.committed and conn.closed


def test_repeat_failure_latches_silently(wired) -> None:
    conn = wired("failing")
    alerts.report("nfl_stats", ok=False, error="HTTP 500 again")

    assert _sends(conn.cur) == []
    assert len(_merges(conn.cur)) == 1  # LAST_ERROR still refreshes


def test_recovery_sends_once(wired) -> None:
    conn = wired("failing")
    alerts.report("nfl_stats", ok=True)

    assert len(_sends(conn.cur)) == 1
    assert len(_merges(conn.cur)) == 1


def test_healthy_stays_untouched(wired) -> None:
    # No ping AND no row churn: 23 green runs a day should write nothing.
    conn = wired("ok")
    alerts.report("nfl_stats", ok=True)

    assert _sends(conn.cur) == []
    assert _merges(conn.cur) == []
    assert conn.closed


def test_message_rides_as_a_bind_never_inlined(wired) -> None:
    # Error text is arbitrary remote content; it must reach the SQL layer as a
    # bind parameter (and SANITIZE_WEBHOOK_CONTENT strips placeholder tokens
    # server-side), never by string concatenation into the statement.
    conn = wired(None)
    alerts.report("nfl_stats", ok=False, error="'); DROP TABLE x; --")

    send_sql, send_params = next(
        (s, p) for s, p in conn.cur.executed if "SEND_SNOWFLAKE_NOTIFICATION" in s
    )
    assert "DROP TABLE" not in send_sql
    assert any("DROP TABLE" in str(p) for p in send_params)
