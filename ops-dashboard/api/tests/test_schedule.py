"""Cron expansion rules. All fixed dates: 2026-08-08 is a Saturday."""

from datetime import UTC, date, datetime

from app import schedule

SAT = date(2026, 8, 8)


def test_daily_slot_lands_on_every_day() -> None:
    assert schedule.day_slots("0 10 * * *", SAT) == [datetime(2026, 8, 8, 10, tzinfo=UTC)]


def test_weekly_tuesday_absent_on_saturday_present_on_tuesday() -> None:
    assert schedule.day_slots("0 13 * * 2", SAT) == []
    tue = date(2026, 8, 4)
    assert schedule.day_slots("0 13 * * 2", tue) == [datetime(2026, 8, 4, 13, tzinfo=UTC)]


def test_slot_state_grace() -> None:
    slot = datetime(2026, 8, 8, 10, tzinfo=UTC)
    just_after = datetime(2026, 8, 8, 10, 10, tzinfo=UTC)
    past_grace = datetime(2026, 8, 8, 10, 20, tzinfo=UTC)
    assert schedule.slot_state(slot, False, just_after) == "pending"
    assert schedule.slot_state(slot, False, past_grace) == "missed"
    assert schedule.slot_state(slot, True, past_grace) == "matched"




def test_next_fire_is_tz_aware_and_future() -> None:
    now = datetime(2026, 8, 8, 12, tzinfo=UTC)
    nxt = schedule.next_fire("0 10 * * *", now)
    assert nxt == datetime(2026, 8, 9, 10, tzinfo=UTC)
