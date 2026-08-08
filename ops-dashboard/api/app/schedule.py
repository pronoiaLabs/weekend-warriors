"""Cron expansion over the registry schedules.

The run views only contain runs that happened. Every "should have happened"
question (missed slots, upcoming slots, not-scheduled-today, future heatmap
cells) is answered here by expanding the registry's cron strings. All crons are
UTC, matching the Snowflake Task definitions.
"""

from datetime import UTC, date, datetime, time, timedelta

from croniter import croniter

# A slot with no run this long after its fire time is treated as missed rather
# than pending. Tasks normally start within seconds; 15 minutes absorbs pool
# contention without hiding a genuinely dead schedule for long.
MISSED_GRACE = timedelta(minutes=15)

# A run is matched to the slot it follows if it starts within this window.
# Runs take 1 to 3 minutes and slots are at least an hour apart, so an hour
# cannot double-match while still absorbing a late Task start.
MATCH_WINDOW = timedelta(hours=1)

_DOW = ["Mon", "Tue", "Wed", "Thu", "Fri", "Sat", "Sun"]


def slots_between(schedule: str, start: datetime, end: datetime) -> list[datetime]:
    """Fire times in [start, end), timezone-aware UTC."""
    it = croniter(schedule, start - timedelta(seconds=1))
    out: list[datetime] = []
    while True:
        nxt = it.get_next(datetime)
        if nxt.tzinfo is None:
            nxt = nxt.replace(tzinfo=UTC)
        if nxt >= end:
            return out
        if nxt >= start:
            out.append(nxt)


def day_slots(schedule: str, day: date) -> list[datetime]:
    start = datetime.combine(day, time.min, tzinfo=UTC)
    return slots_between(schedule, start, start + timedelta(days=1))


def next_fire(schedule: str, after: datetime) -> datetime:
    nxt = croniter(schedule, after).get_next(datetime)
    return nxt if nxt.tzinfo else nxt.replace(tzinfo=UTC)


def slot_state(slot: datetime, has_run: bool, now: datetime) -> str:
    """One of matched / missed / pending for an expanded slot."""
    if has_run:
        return "matched"
    if now >= slot + MISSED_GRACE:
        return "missed"
    return "pending"


def prose(schedule: str) -> str:
    """Cron to a human string, e.g. 'daily 10:00 UTC' or 'weekly Tue 13:00 UTC'.

    Only the shapes the registry actually uses (fixed minute/hour, * or single
    day-of-week); anything else falls back to the raw cron string.
    """
    parts = schedule.split()
    if len(parts) != 5:
        return schedule
    minute, hour, dom, month, dow = parts
    if not (minute.isdigit() and hour.isdigit() and dom == "*" and month == "*"):
        return schedule
    at = f"{int(hour):02d}:{int(minute):02d} UTC"
    if dow == "*":
        return f"daily {at}"
    if dow.isdigit():
        return f"weekly {_DOW[(int(dow) - 1) % 7]} {at}"
    return schedule
