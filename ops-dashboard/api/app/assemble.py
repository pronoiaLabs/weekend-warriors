"""Payload assembly: raw registry rows + raw run rows -> page payloads.

Pure functions of their inputs (including `now`), so every derivation rule the
wireframe encodes (management by exception, absence as an incident, dual
verdicts, worst-of ranking) is testable against fixtures with no connector.

Timestamps: run rows carry ISO-8601 UTC strings with trailing Z (datasource
normalizes them); everything here parses and emits that same shape.
"""

from datetime import UTC, date, datetime, timedelta
from typing import Any

from app import derive, schedule

WINDOW_DAYS = 14


def _parse_ts(value: str) -> datetime:
    return datetime.fromisoformat(value)


def _iso(dt: datetime) -> str:
    return dt.astimezone(UTC).strftime("%Y-%m-%dT%H:%M:%S.%f")[:-3] + "Z"


def _run_state(run: dict[str, Any]) -> str:
    """Block/card state for one run: the worst anomaly, else succeeded."""
    kinds = derive.run_anomalies(run)
    if "missing" in kinds:
        return "missing"
    if "failure" in kinds:
        return "failure"
    if run.get("task_state") == "SUCCEEDED":
        return "succeeded"
    return (run.get("task_state") or "unknown").lower()


def _match_slots(
    slots: list[datetime], runs: list[dict[str, Any]], now: datetime
) -> tuple[dict[datetime, dict[str, Any] | None], list[datetime], list[datetime]]:
    """Slot -> matched run (or None); plus missed and pending slot lists."""
    matched: dict[datetime, dict[str, Any] | None] = {}
    missed: list[datetime] = []
    pending: list[datetime] = []
    for slot in slots:
        hit = None
        for run in runs:
            started = _parse_ts(run["run_started_at"])
            if slot <= started < slot + schedule.MATCH_WINDOW:
                hit = run
                break
        matched[slot] = hit
        if hit is None:
            state = schedule.slot_state(slot, False, now)
            (missed if state == "missed" else pending).append(slot)
    return matched, missed, pending


def _block_for_run(run: dict[str, Any]) -> dict[str, Any]:
    return {
        "kind": "run",
        "state": _run_state(run),
        "pipeline": run["pipeline"],
        "at": run["run_started_at"],
        "duration_s": run.get("duration_s"),
        "rows_loaded": run.get("rows_loaded"),
        "query_id": run.get("query_id"),
        "error_excerpt": (run.get("error_text") or "").split("\n")[0][:160] or None,
    }


def _day_states(cron: str, history: list[dict[str, Any]], now: datetime) -> list[dict[str, Any]]:
    """Worst state per day over the window, oldest first.

    `history` must be sorted newest-first. Shared by the detail heatmap and the
    index strips so the two can never disagree about what a day looked like.
    """
    today = now.date()
    cells: list[dict[str, Any]] = []
    for offset in range(WINDOW_DAYS - 1, -1, -1):
        day = today - timedelta(days=offset)
        day_start = datetime.combine(day, datetime.min.time(), tzinfo=UTC)
        day_runs = [
            r
            for r in history
            if day_start <= _parse_ts(r["run_started_at"]) < day_start + timedelta(days=1)
        ]
        slots = schedule.day_slots(cron, day)
        _, missed, pending = _match_slots(slots, day_runs, now)
        states = [_run_state(r) for r in day_runs] + ["missed"] * len(missed)
        if states:
            state = derive.worst([s if s in derive.SEVERITY_ORDER else "ok" for s in states])
            if state == "ok":
                state = "succeeded" if "succeeded" in states else states[0]
        elif pending:
            state = "scheduled"
        elif slots:
            state = "missed"
        else:
            state = "none"
        cells.append(
            {
                "date": day.isoformat(),
                "state": state,
                "query_id": day_runs[0]["query_id"] if day_runs else None,
            }
        )
    return cells


def pipelines_index(
    pipelines: list[dict[str, Any]],
    runs_window: list[dict[str, Any]],
    now: datetime,
) -> dict[str, Any]:
    """One row per registered pipeline, including ones that never ran.

    The per-row `days` strip costs no extra I/O: `runs_window` is already the
    whole fleet's window in one query, so each pipeline's day states are a pure
    re-bucketing of rows this function was grouping anyway.
    """
    by_pipeline: dict[str, list[dict[str, Any]]] = {}
    for run in runs_window:
        by_pipeline.setdefault(run["pipeline"], []).append(run)
    for runs in by_pipeline.values():
        runs.sort(key=lambda r: r["run_started_at"], reverse=True)

    rows = []
    for pipe in pipelines:
        history = by_pipeline.get(pipe["name"], [])
        latest = history[0] if history else None
        form, record = form_and_record(pipe["schedule"], history, now)
        durations = [
            r["duration_s"]
            for r in history
            if r.get("task_state") == "SUCCEEDED" and r.get("duration_s") is not None
        ]
        rows.append(
            {
                "pipeline": pipe["name"],
                "sport": pipe["sport"],
                "enabled": pipe["enabled"],
                "schedule": schedule.prose(pipe["schedule"]),
                "cron": pipe["schedule"],
                "next_fire": _iso(schedule.next_fire(pipe["schedule"], now)),
                "latest": _block_for_run(latest) if latest else None,
                "succeeded": sum(1 for r in history if r.get("task_state") == "SUCCEEDED"),
                "runs_in_window": len(history),
                "window_days": WINDOW_DAYS,
                "days": _day_states(pipe["schedule"], history, now),
                "record": record,
                "form": form,
                "avg_duration_s": round(sum(durations) / len(durations), 1)
                if durations
                else None,
            }
        )
    return {"now": _iso(now), "window_days": WINDOW_DAYS, "pipelines": rows}


def pipeline_detail(
    pipe: dict[str, Any],
    history: list[dict[str, Any]],
    now: datetime,
    limit: int,
) -> dict[str, Any]:
    """Header facts, 14-day heatmap, and run history for one pipeline."""
    history = sorted(history, key=lambda r: r["run_started_at"], reverse=True)
    cron = pipe["schedule"]

    succeeded = [r for r in history if r.get("task_state") == "SUCCEEDED"]
    durations = sorted(r["duration_s"] for r in succeeded if r.get("duration_s") is not None)
    median = durations[len(durations) // 2] if durations else None

    heatmap = _day_states(cron, history, now)

    latest = history[0] if history else None
    runs_out = []
    for run in history[:limit]:
        row = dict(run)
        row["anomalies"] = derive.run_anomalies(run)
        row["state"] = _run_state(run)
        row["error_provenance"] = derive.error_provenance(run)
        runs_out.append(row)

    return {
        "pipeline": pipe["name"],
        "sport": pipe["sport"],
        "schedule": schedule.prose(cron),
        "cron": cron,
        "next_fire": _iso(schedule.next_fire(cron, now)),
        "task_name": latest.get("task_name") if latest else None,
        "compute_pool": latest.get("compute_pool") if latest else None,
        "window_days": WINDOW_DAYS,
        "succeeded": len(succeeded),
        "runs_in_window": len(history),
        "median_duration_s": median,
        "last_success_at": succeeded[0]["run_started_at"] if succeeded else None,
        "heatmap": heatmap,
        "runs": runs_out,
    }


def run_detail(run: dict[str, Any], history: list[dict[str, Any]]) -> dict[str, Any]:
    """One run plus its context strip and previous populated row counts.

    `history` is the pipeline's runs up to and including this one, newest first.
    """
    prior = [r for r in history if r["run_started_at"] < run["run_started_at"]]
    prev_counts = next((r["row_counts"] for r in prior if r.get("row_counts")), None)
    out = dict(run)
    out["anomalies"] = derive.run_anomalies(run)
    out["state"] = _run_state(run)
    out["error_provenance"] = derive.error_provenance(run)
    out["prev_row_counts"] = prev_counts
    out["prior_runs"] = [
        {"query_id": r.get("query_id"), "at": r["run_started_at"], "state": _run_state(r)}
        for r in prior[:WINDOW_DAYS]
    ]
    return out


def headlines(rows: list[dict[str, Any]], requested_day: date) -> dict[str, Any]:
    """Shape the AI wire payload from the day's HEADLINES rows.

    `stale` is informational, never an error: the wire regenerates at 12:00
    UTC, so a morning request legitimately serves yesterday's edition, and a
    day the proc skipped serves the newest one before it. The panel renders
    the fact; nothing downstream should branch on it.
    """
    served = rows[0]["day"] if rows else None
    return {
        "requested_date": requested_day.isoformat(),
        "served_date": served,
        "stale": served != requested_day.isoformat(),
        "generated_at": rows[0].get("generated_at") if rows else None,
        "model": rows[0].get("model") if rows else None,
        "headlines": [
            {
                "seq": r["seq"],
                "severity": r["severity"],
                "kind": r["kind"],
                "entity": r["entity"],
                "headline": r["headline"],
                "detail": r["detail"],
            }
            for r in rows
        ],
    }


def _slate_day(
    pipelines: list[dict[str, Any]],
    by_pipe: dict[str, list[dict[str, Any]]],
    day_: date,
    now: datetime,
) -> tuple[list[dict[str, Any]], dict[str, int]]:
    """Cards + tallies for one day over an already-filtered pipeline set.

    The strip and the card lanes share this one function, which is what keeps
    a day tab's "1 failed" and its slate's upset cards from ever disagreeing.
    """
    cards: list[dict[str, Any]] = []
    tally = {"ran": 0, "failed": 0, "missed": 0, "upcoming": 0, "slots": 0}

    def _prev(name: str, before_iso: str) -> dict[str, Any] | None:
        for r in by_pipe.get(name, []):
            if r["run_started_at"] < before_iso:
                return {
                    "at": r["run_started_at"],
                    "state": _run_state(r),
                    "rows_loaded": r.get("rows_loaded"),
                    "duration_s": r.get("duration_s"),
                }
        return None

    for pipe in pipelines:
        cron = pipe.get("schedule")
        if not cron:
            continue
        slots = schedule.day_slots(cron, day_)
        tally["slots"] += len(slots)
        matched, missed, _pending = _match_slots(slots, by_pipe.get(pipe["name"], []), now)
        for slot in slots:
            run = matched.get(slot)
            if run is not None:
                card = _block_for_run(run)
                card["schedule"] = schedule.prose(cron)
                card["cron"] = cron
                card["prev"] = _prev(pipe["name"], run["run_started_at"])
                cards.append(card)
                if card["state"] == "succeeded":
                    tally["ran"] += 1
                else:
                    tally["failed"] += 1
                continue
            kind = "missed" if slot in missed else "upcoming"
            tally[kind if kind == "missed" else "upcoming"] += 1
            slot_iso = _iso(slot)
            cards.append(
                {
                    "kind": kind,
                    "state": kind,
                    "pipeline": pipe["name"],
                    "at": slot_iso,
                    "duration_s": None,
                    "rows_loaded": None,
                    "query_id": None,
                    "error_excerpt": None,
                    "schedule": schedule.prose(cron),
                    "cron": cron,
                    "prev": _prev(pipe["name"], slot_iso),
                }
            )
    cards.sort(key=lambda c: c["at"])
    return cards, tally


def slate(
    pipelines: list[dict[str, Any]],
    runs: list[dict[str, Any]],
    builds: list[dict[str, Any]],
    now: datetime,
    day_: date,
    radius: int = 3,
) -> dict[str, Any]:
    """The day's slate: league-grouped score cards + a +/-radius day strip."""
    by_pipe: dict[str, list[dict[str, Any]]] = {}
    for r in sorted(runs, key=lambda r: r["run_started_at"], reverse=True):
        by_pipe.setdefault(r["pipeline"], []).append(r)

    days: list[dict[str, Any]] = []
    for off in range(-radius, radius + 1):
        d = day_ + timedelta(days=off)
        _cards, tally = _slate_day(pipelines, by_pipe, d, now)
        days.append(
            {
                "date": d.isoformat(),
                "dow": d.strftime("%a"),
                "is_today": d == now.date(),
                **tally,
            }
        )

    leagues: list[dict[str, Any]] = []
    for sport in sorted({p["sport"] for p in pipelines}):
        sport_pipes = [p for p in pipelines if p["sport"] == sport]
        cards, tally = _slate_day(sport_pipes, by_pipe, day_, now)
        if not cards:
            continue
        leagues.append(
            {
                "sport": sport,
                "kind": "ingestion",
                "rows_loaded": sum(c.get("rows_loaded") or 0 for c in cards),
                **tally,
                "cards": cards,
            }
        )

    day_iso = day_.isoformat()
    build_cards = [
        {
            "kind": "build",
            "state": "succeeded" if b.get("state") == "SUCCEEDED" else "failure",
            "sport": b.get("sport"),
            "args": b.get("args"),
            "build_id": b.get("build_id"),
            "at": b.get("started_at"),
            "duration_s": b.get("duration_s"),
            "n_queries": b.get("n_queries"),
            "n_failed_queries": b.get("n_failed_queries"),
            "drained_loads": b.get("drained_loads"),
        }
        for b in builds
        if (b.get("started_at") or "").startswith(day_iso)
    ]
    if build_cards:
        build_cards.sort(key=lambda c: c["at"])
        leagues.append({"sport": "dbt", "kind": "dbt", "cards": build_cards})

    return {"date": day_iso, "now": _iso(now), "window_days": WINDOW_DAYS, "days": days, "leagues": leagues}


_RECORD_STATES = ("SUCCEEDED", "FAILED", "FAILED_AND_AUTO_SUSPENDED")


def form_and_record(
    cron: str, history: list[dict[str, Any]], now: datetime
) -> tuple[list[dict[str, Any]], dict[str, Any]]:
    """Last-14 form cells + W-L record, the Python port of form_guide_14d.

    Mirrors the SQL leg in dlt-pipelines/sql/ops/10_headlines.sql: W/L only
    from decisive task states, streak = the latest result's run length.
    Missed slots appear as M cells in the form (a no-show should occupy
    space) but stay OUT of the record and the streak, exactly as the SQL,
    which never sees them, behaves.
    """
    outcomes: list[dict[str, Any]] = []
    for r in history:
        state = r.get("task_state")
        if state in _RECORD_STATES:
            outcomes.append(
                {
                    "at": r["run_started_at"],
                    "result": "W" if state == "SUCCEEDED" else "L",
                    "query_id": r.get("query_id"),
                }
            )

    slots = schedule.slots_between(cron, now - timedelta(days=WINDOW_DAYS), now)
    _matched, missed, _pending = _match_slots(slots, history, now)
    outcomes.extend({"at": _iso(s), "result": "M", "query_id": None} for s in missed)

    outcomes.sort(key=lambda o: o["at"])
    form = outcomes[-WINDOW_DAYS:]

    decisive = [o["result"] for o in outcomes if o["result"] != "M"]
    wins = decisive.count("W")
    losses = decisive.count("L")
    streak = None
    if decisive:
        last = decisive[-1]
        n = 0
        for res in reversed(decisive):
            if res != last:
                break
            n += 1
        streak = f"{last}{n}"
    record = {
        "wins": wins,
        "losses": losses,
        "pct": round(wins / (wins + losses), 3) if wins + losses else None,
        "streak": streak,
    }
    return form, record
