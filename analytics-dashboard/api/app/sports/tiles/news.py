"""News: player mentions in a window, newest first.

One select on the mentions mart for the days before the clock, optionally one
team. Everything else the page filters on (position, feed, whether the name
resolved to a player) is a column on the row, and a window is a few hundred
rows, so those filters stay client-side and switch without a round trip.
"""

import datetime as dt

from pydantic import BaseModel

from app import config
from app.sports import source
from app.sports.capabilities import Capability as C
from app.sports.payloads import Envelope
from app.sports.profile import SportProfile

DEFAULT_DAYS = 7
MAX_DAYS = 90


class MentionRow(BaseModel):
    app_news_mentions_key: str
    mention_key: str
    article_key: str
    player_key: str | None = None
    player_id: int | None = None
    is_player_resolved: bool
    player_name: str | None = None
    position: str | None = None
    position_name: str | None = None
    position_group: str | None = None
    team_key: str | None = None
    team_label: str | None = None
    team_name: str | None = None
    published_at: dt.datetime
    published_date: dt.date
    feed: str
    headline: str | None = None
    context: str | None = None
    detail: str | None = None
    url: str | None = None
    player_name_in_article: str | None = None
    team_in_article: str | None = None
    extract_mode: str | None = None
    resolution_method: str | None = None
    candidate_count: int | None = None
    next_game_key: str | None = None
    next_game_datetime_et: dt.datetime | None = None
    next_game_season: int | None = None
    next_game_week: int | None = None
    next_game_season_type_name: str | None = None
    next_opponent_team_key: str | None = None
    next_opponent_label: str | None = None
    next_opponent_name: str | None = None
    next_game_is_home: bool | None = None
    days_to_next_game: int | None = None


COLUMNS: tuple[str, ...] = tuple(MentionRow.model_fields)


class NewsPayload(Envelope[MentionRow]):
    since: dt.date
    days: int
    team: str | None
    feeds: list[str]
    teams: list[str]


def load(profile: SportProfile, *, days: int, team: str | None) -> NewsPayload:
    """Mentions published on or after `days` days before the clock."""
    now = config.now()
    since = (now - dt.timedelta(days=days)).date()
    label = team.upper() if team else None
    params: dict[str, object] = {"since": since}
    where = "published_date >= %(since)s"
    if label is not None:
        params["team"] = label
        where += " and team_label = %(team)s"
    rows, sql = source.select(
        profile,
        C.NEWS,
        COLUMNS,
        where=where,
        params=params,
        matches=lambda r: (
            str(r["published_date"]) >= since.isoformat()
            and (label is None or r["team_label"] == label)
        ),
        order=("published_at desc", "mention_key"),
        tag="news",
    )
    return NewsPayload(
        sport=profile.key,
        season=profile.default_season,
        as_of=now,
        since=since,
        days=days,
        team=label,
        feeds=sorted({r["feed"] for r in rows}),
        teams=sorted({r["team_label"] for r in rows if r["team_label"]}),
        rows=[MentionRow(**r) for r in rows],
        query=sql,
    )
