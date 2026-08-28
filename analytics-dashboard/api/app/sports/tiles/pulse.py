"""The Pulse: the home screen's one fetch, five known-column selects composed.

news (a short window, injury-first sorting is the page's), status, trending and
movers come from their tiles; the slate strip reuses the slate tile whole --
week resolution, vendor default and the vendor collapse included -- so the
Pulse's "this week" is the same week the board would show. Read-only
composition: no new query semantics live here.
"""

import datetime as dt

from pydantic import BaseModel

from app import config
from app.sports import source
from app.sports.capabilities import Capability as C
from app.sports.profile import SportProfile
from app.sports.tiles import movers, news, slate, status_board, trending

DEFAULT_DAYS = 2  # the wireframe's "last 48h"
MAX_DAYS = news.MAX_DAYS


class PulsePayload(BaseModel):
    sport: str
    season: int
    as_of: dt.datetime
    season_type_name: str
    week: int
    days: int
    vendor: str | None
    weeks: list[slate.WeekRef]
    slate: list[slate.SlateRow]
    news: list[news.MentionRow]
    status: list[status_board.StatusRow]
    trending: list[trending.TrendingRow]
    # bare annotation on purpose: an `= default` here would bind the class-local
    # name before the annotation resolves, shadowing the movers module
    movers: movers.MoversSection
    query: str | None = None


def load(
    profile: SportProfile,
    *,
    days: int,
    season: int | None,
    season_type_name: str | None,
    week: int | None,
    vendor: str | None,
) -> PulsePayload | None:
    """The digest. None when the season has no games at all (mirrors the slate)."""
    season = season or profile.default_season
    refs, weeks_sql = slate.weeks(profile, season, tag="pulse_weeks")
    chosen = slate.pick_week(refs, season_type_name, week, config.now())
    if chosen is None:
        return None
    book = vendor if vendor is not None else profile.default_vendor

    slate_params = {
        "season": season,
        "season_type_name": chosen.season_type_name,
        "week": chosen.week,
    }
    slate_rows, slate_sql = source.select(
        profile,
        C.SCHEDULE,
        slate.COLUMNS,
        where="season = %(season)s and season_type_name = %(season_type_name)s and week = %(week)s",
        params=slate_params,
        matches=lambda r: (
            r["season"] == season
            and r["season_type_name"] == chosen.season_type_name
            and r["week"] == chosen.week
        ),
        order=("game_datetime_et", "game_key", "vendor"),
        tag="pulse_slate",
    )

    now = config.now()
    since = (now - dt.timedelta(days=days)).date()
    news_rows, news_sql = source.select(
        profile,
        C.NEWS,
        news.COLUMNS,
        where="published_date >= %(since)s",
        params={"since": since},
        matches=lambda r: str(r["published_date"]) >= since.isoformat(),
        order=("published_at desc", "mention_key"),
        tag="pulse_news",
    )

    status_rows, status_sql = status_board.load(profile)
    trending_rows, trending_sql = trending.load(profile)
    movers_section, movers_sql = movers.load(
        profile,
        season=season,
        season_type_name=chosen.season_type_name,
        week=chosen.week,
        vendor=book or "",
    )

    return PulsePayload(
        sport=profile.key,
        season=season,
        as_of=now,
        season_type_name=chosen.season_type_name,
        week=chosen.week,
        days=days,
        vendor=book,
        weeks=refs,
        slate=slate.collapse(slate_rows, book),
        news=[news.MentionRow(**r) for r in news_rows],
        status=status_rows,
        trending=trending_rows,
        movers=movers_section,
        query=(
            f"{weeks_sql}\n\n{slate_sql}\n\n{news_sql}\n\n"
            f"{status_sql}\n\n{trending_sql}\n\n{movers_sql}"
        ),
    )
