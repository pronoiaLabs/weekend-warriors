"""Cron expansion over the registry schedules.

The run views only contain runs that happened. Every "should have happened"
question (missed slots, upcoming slots, not-scheduled-today, future heatmap
cells) is answered here by expanding the registry's cron strings. All crons are
UTC, matching the Snowflake Task definitions.
"""

from datetime import UTC, date, datetime, time, timedelta, tzinfo

from croniter import croniter

# A slot with no run this long after its fire time is treated as missed rather
# than pending. Tasks normally start within seconds; 15 minutes absorbs pool
# contention without hiding a genuinely dead schedule for long.
MISSED_GRACE = timedelta(minutes=15)

# A run is matched to the slot it follows if it starts within this window.
# Runs take 1 to 3 minutes and slots are at least an hour apart, so an hour
# cannot double-match while still absorbing a late Task start.
MATCH_WINDOW = timedelta(hours=1)


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


def day_bounds(day: date, tz: tzinfo = UTC) -> tuple[datetime, datetime]:
    """The UTC instants a calendar day spans in `tz`: local midnight to the next
    local midnight, so a DST day is 23 or 25 hours rather than a fixed 24."""
    start = datetime.combine(day, time.min, tzinfo=tz).astimezone(UTC)
    end = datetime.combine(day + timedelta(days=1), time.min, tzinfo=tz).astimezone(UTC)
    return start, end


def day_slots(schedule: str, day: date, tz: tzinfo = UTC) -> list[datetime]:
    """The cron's fire times on one calendar day of `tz`. The cron itself is
    UTC (the Task definition); only the day's edges move with the viewer."""
    start, end = day_bounds(day, tz)
    return slots_between(schedule, start, end)


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


# Cron-to-prose rendering lives in the frontend (utils/format.ts cronProse):
# schedules are UTC facts, but only the browser knows the viewer's timezone,
# and a weekly slot can land on a different local weekday than its UTC one.
# The payloads ship the raw cron string.
