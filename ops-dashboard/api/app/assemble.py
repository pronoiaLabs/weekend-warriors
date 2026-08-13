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


def overview(
    pipelines: list[dict[str, Any]],
    runs_window: list[dict[str, Any]],
    now: datetime,
    day: date,
) -> dict[str, Any]:
    day_start = datetime.combine(day, datetime.min.time(), tzinfo=UTC)
    day_end = day_start + timedelta(days=1)

    sports = sorted({p["sport"] for p in pipelines})
    by_pipeline: dict[str, list[dict[str, Any]]] = {}
    for run in runs_window:
        by_pipeline.setdefault(run["pipeline"], []).append(run)
    for runs in by_pipeline.values():
        runs.sort(key=lambda r: r["run_started_at"], reverse=True)

    summary = {
        "pipelines": len(pipelines),
        "sports": len(sports),
        "slots_today": 0,
        "succeeded_today": 0,
        "failed_today": 0,
        "missing_today": 0,
        "missed_today": 0,
        "upcoming_today": 0,
    }
    board_sports: list[dict[str, Any]] = []
    panel_sports: list[dict[str, Any]] = []
    window_points: list[datetime] = [now]

    for sport in sports:
        sport_pipes = [p for p in pipelines if p["sport"] == sport]
        blocks: list[dict[str, Any]] = []
        sublanes: list[dict[str, Any]] = []
        sport_missed_today = 0
        cards: list[dict[str, Any]] = []

        for pipe in sport_pipes:
            name, cron = pipe["name"], pipe["schedule"]
            history = by_pipeline.get(name, [])
            today_runs = [
                r for r in history if day_start <= _parse_ts(r["run_started_at"]) < day_end
            ]
            slots = schedule.day_slots(cron, day)
            _, missed, pending = _match_slots(slots, today_runs, now)
            window_points += slots
            window_points += [_parse_ts(r["run_started_at"]) for r in today_runs]

            summary["slots_today"] += len(slots)
            summary["missed_today"] += len(missed)
            summary["upcoming_today"] += len(pending)
            sport_missed_today += len(missed)
            for run in today_runs:
                state = _run_state(run)
                if state == "succeeded":
                    summary["succeeded_today"] += 1
                elif state == "failure":
                    summary["failed_today"] += 1
                elif state == "missing":
                    summary["missing_today"] += 1

            pipe_blocks = [_block_for_run(r) for r in today_runs]
            pipe_blocks += [
                {"kind": "missed", "state": "missed", "pipeline": name, "at": _iso(s)}
                for s in missed
            ]
            pipe_blocks += [
                {"kind": "upcoming", "state": "upcoming", "pipeline": name, "at": _iso(s)}
                for s in pending
            ]
            blocks += pipe_blocks

            latest = history[0] if history else None
            sublanes.append(
                {
                    "pipeline": name,
                    "schedule": schedule.prose(cron),
                    "cron": cron,
                    "not_scheduled_today": not slots,
                    "next_fire": _iso(schedule.next_fire(cron, now)),
                    "last_duration_s": latest.get("duration_s") if latest else None,
                    "last_rows_loaded": latest.get("rows_loaded") if latest else None,
                    "blocks": pipe_blocks,
                }
            )

            # Management by exception: a card exists only for an active anomaly,
            # meaning the latest run is anomalous or a slot was missed today.
            latest_kinds = derive.run_anomalies(latest) if latest else []
            if latest_kinds or missed:
                missing_14d = sum(1 for r in history if r.get("dlt_record_missing"))
                disagrees = [r for r in history if r.get("outcome_disagrees")]
                badges: list[dict[str, Any]] = []
                if missing_14d:
                    badges.append({"kind": "missing", "count": missing_14d, "window_days": WINDOW_DAYS})
                if disagrees:
                    badges.append(
                        {
                            "kind": "disagree",
                            "count": len(disagrees),
                            "window_days": WINDOW_DAYS,
                            "last_at": disagrees[0]["run_started_at"],
                        }
                    )
                cards.append(
                    {
                        "pipeline": name,
                        "state": derive.worst(latest_kinds + (["missed"] if missed else [])),
                        "last_run": _block_for_run(latest) if latest else None,
                        "task_state": latest.get("task_state") if latest else None,
                        "dlt_status": latest.get("dlt_status") if latest else None,
                        "missed_slots_today": len(missed),
                        "badges": badges,
                    }
                )

        rows_today = sum(
            r.get("rows_loaded") or 0
            for r in runs_window
            if r["sport"] == sport and day_start <= _parse_ts(r["run_started_at"]) < day_end
        )
        anomaly_kinds = [c["state"] for c in cards]
        panel_sports.append(
            {
                "sport": sport,
                "pipelines": len(sport_pipes),
                "worst": derive.worst(anomaly_kinds),
                "missed_slots_today": sport_missed_today,
                "rows_today": rows_today,
                "anomaly_count": len(cards),
                "healthy_count": len(sport_pipes) - len(cards),
                "cards": cards,
            }
        )
        board_sports.append({"sport": sport, "blocks": blocks, "sublanes": sublanes})

    pad = timedelta(minutes=45)
    win_start = min(window_points) - pad
    win_end = max(window_points) + pad
    return {
        "date": day.isoformat(),
        "now": _iso(now),
        "summary": summary,
        "board": {"window": {"start": _iso(win_start), "end": _iso(win_end)}, "sports": board_sports},
        "sports": panel_sports,
    }


def incidents(
    pipelines: list[dict[str, Any]],
    runs_window: list[dict[str, Any]],
    now: datetime,
    days: int,
) -> dict[str, Any]:
    since = now - timedelta(days=days)
    by_pipeline: dict[str, list[dict[str, Any]]] = {}
    for run in runs_window:
        by_pipeline.setdefault(run["pipeline"], []).append(run)
    for runs in by_pipeline.values():
        runs.sort(key=lambda r: r["run_started_at"])

    entries: list[dict[str, Any]] = []
    for run in runs_window:
        at = _parse_ts(run["run_started_at"])
        if at < since:
            continue
        history = by_pipeline[run["pipeline"]]
        idx = history.index(run)
        nxt = history[idx + 1] if idx + 1 < len(history) else None
        for kind in derive.run_anomalies(run):
            entries.append(
                {
                    "kind": kind,
                    "sport": run["sport"],
                    "pipeline": run["pipeline"],
                    "at": run["run_started_at"],
                    "query_id": run.get("query_id"),
                    "duration_s": run.get("duration_s"),
                    "rows_loaded": run.get("rows_loaded"),
                    "load_id": run.get("load_id"),
                    "task_state": run.get("task_state"),
                    "dlt_status": run.get("dlt_status"),
                    "error_text": run.get("error_text"),
                    "error_provenance": derive.error_provenance(run),
                    "error_lines": run.get("error_lines"),
                    "log_lines": run.get("log_lines"),
                    "container_never_started": run.get("container_never_started"),
                    "next_outcome": (
                        {"task_state": nxt.get("task_state"), "at": nxt["run_started_at"]}
                        if nxt
                        else None
                    ),
                }
            )

    for pipe in pipelines:
        name, cron = pipe["name"], pipe["schedule"]
        history = by_pipeline.get(name, [])
        slots = schedule.slots_between(cron, since, now)
        _, missed, _ = _match_slots(slots, history, now)
        for slot in missed:
            prior = [r for r in history if _parse_ts(r["run_started_at"]) < slot][-4:]
            entries.append(
                {
                    "kind": "missed",
                    "sport": pipe["sport"],
                    "pipeline": name,
                    "at": _iso(slot),
                    "noticed": _iso(slot + schedule.MISSED_GRACE),
                    "query_id": None,
                    "schedule": schedule.prose(cron),
                    "slot_strip": [
                        {"at": r["run_started_at"], "state": _run_state(r)} for r in prior
                    ],
                }
            )

    entries.sort(key=lambda e: e["at"], reverse=True)
    counts = {k: sum(1 for e in entries if e["kind"] == k) for k in ("failure", "missing", "disagree", "missed")}
    return {"days": days, "now": _iso(now), "counts": counts, "incidents": entries}


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
