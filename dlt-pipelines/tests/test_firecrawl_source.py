"""Offline tests for the Firecrawl news source. No network, no SDK, no credentials.

A FakeFirecrawl stands in for the SDK client and records every call it receives, so
the tests assert on what would have been billed: which URLs reached batch_scrape and
with which formats. Feeds are canned RSS 2.0 / Atom documents served by a fake fetcher.
The pure helpers (gate, parse_feed, is_fresh, prune_seen, is_excluded) are tested on
their own because they are what the first drafts of this pipeline got wrong.
"""
from __future__ import annotations

import sys
from datetime import date, datetime, timedelta, timezone
from email.utils import format_datetime
from pathlib import Path
from types import SimpleNamespace
from typing import Any

import pytest

_ROOT = Path(__file__).parent.parent.resolve()
if str(_ROOT) not in sys.path:
    sys.path.insert(0, str(_ROOT))

pytest.importorskip("dlt")
pytest.importorskip("duckdb")
pytest.importorskip("feedparser")

import dlt  # noqa: E402

from pipelines.batch.firecrawl_source import (  # noqa: E402
    extract_mode_for,
    firecrawl_news,
    gate,
    is_excluded,
    is_fresh,
    parse_feed,
    prune_seen,
)

KEYWORDS = ["injury", "out", "IR", "depth chart"]
NOW = datetime.now(timezone.utc)


# ---------------------------------------------------------------------------
# Pure helpers
# ---------------------------------------------------------------------------


@pytest.mark.parametrize(
    "text, expected",
    [
        ("Chubb ruled out for Sunday", ["out"]),
        ("Nothing about the game without him", []),          # out inside about/without
        ("Placed on IR with a knee injury", ["injury", "IR"]),
        ("their first game of the third week", []),          # ir inside their/first/third
        ("Starting lineup and depth chart update", ["depth chart"]),
        ("Depth Chart shuffle", ["depth chart"]),            # case-insensitive phrase
        ("placed on ir", []),                                 # all-caps keyword is case-sensitive
        ("", []),
    ],
)
def test_gate_matches_whole_words_only(text: str, expected: list[str]) -> None:
    assert gate(text, None, KEYWORDS) == expected


def test_gate_reads_title_and_snippet() -> None:
    assert gate("Texans sign two WRs", "after Higgins injury", KEYWORDS) == ["injury"]
    assert gate(None, None, KEYWORDS) == []


def test_prune_seen_keeps_recent_and_drops_old_or_corrupt() -> None:
    today = date(2026, 8, 22)
    seen = {
        "https://a": "2026-08-22",
        "https://b": "2026-07-23",   # exactly 30 days: kept
        "https://c": "2026-07-22",   # 31 days: dropped
        "https://d": "not-a-date",   # dropped, never sticks
    }
    assert prune_seen(seen, today, 30) == {"https://a": "2026-08-22", "https://b": "2026-07-23"}


def test_is_excluded_matches_host_and_subdomains() -> None:
    assert is_excluded("https://theathletic.com/nfl/x", ["theathletic.com"])
    assert is_excluded("https://www.theathletic.com/x", ["theathletic.com"])
    assert not is_excluded("https://nottheathletic.com/x", ["theathletic.com"])
    assert not is_excluded("https://espn.com/x", [])


def test_is_fresh_keeps_undated_and_recent_drops_stale() -> None:
    assert is_fresh(None, NOW, 48)
    assert is_fresh(NOW - timedelta(hours=47), NOW, 48)
    assert not is_fresh(NOW - timedelta(hours=49), NOW, 48)


def test_extract_mode_defaults_to_gated_and_rejects_unknown() -> None:
    assert extract_mode_for({"name": "x"}) == "gated"
    assert extract_mode_for({"name": "x", "extract": "ALL"}) == "all"
    with pytest.raises(ValueError, match="extract must be one of"):
        extract_mode_for({"name": "x", "extract": "sometimes"})


# ---------------------------------------------------------------------------
# Canned feeds
# ---------------------------------------------------------------------------


def _rss(items: list[dict[str, Any]]) -> str:
    """RSS 2.0 with content:encoded; `age_hours` sets pubDate relative to now."""
    body = ""
    for it in items:
        pub = (
            f"<pubDate>{format_datetime(NOW - timedelta(hours=it['age_hours']))}</pubDate>"
            if it.get("age_hours") is not None
            else ""
        )
        content = (
            f"<content:encoded><![CDATA[{it['content']}]]></content:encoded>"
            if it.get("content")
            else ""
        )
        body += (
            f"<item><title>{it['title']}</title><link>{it['url']}</link>"
            f"<description><![CDATA[{it.get('summary', '')}]]></description>{content}{pub}</item>"
        )
    return (
        '<?xml version="1.0"?><rss version="2.0" '
        'xmlns:content="http://purl.org/rss/1.0/modules/content/">'
        f"<channel><title>t</title>{body}</channel></rss>"
    )


def _atom(items: list[dict[str, Any]]) -> str:
    body = ""
    for it in items:
        upd = (NOW - timedelta(hours=it["age_hours"])).strftime("%Y-%m-%dT%H:%M:%SZ")
        body += (
            f"<entry><title>{it['title']}</title><link href=\"{it['url']}\"/>"
            f"<id>{it['url']}</id><updated>{upd}</updated>"
            f"<summary type=\"html\">{it.get('summary', '')}</summary></entry>"
        )
    return f'<?xml version="1.0"?><feed xmlns="http://www.w3.org/2005/Atom"><title>t</title>{body}</feed>'


def test_parse_feed_rss_strips_html_and_keeps_content() -> None:
    xml = _rss([{
        "url": "https://a.com/1", "title": "Chubb ruled out",
        "summary": "<p>injury &amp; <b>news</b></p>", "content": "<p>full post</p>", "age_hours": 1,
    }])
    [hit] = parse_feed(xml, "pft")
    assert hit["url"] == "https://a.com/1"
    assert hit["title"] == "Chubb ruled out"
    assert hit["snippet"] == "injury & news"
    assert hit["feed_content"] == "<p>full post</p>"
    assert hit["feed"] == "pft"
    assert hit["published_at"].tzinfo is not None
    assert abs((NOW - timedelta(hours=1)) - hit["published_at"]) < timedelta(seconds=2)


def test_parse_feed_atom_and_undated_entries() -> None:
    [hit] = parse_feed(_atom([{"url": "https://a.com/2", "title": "T", "age_hours": 2}]), "club")
    assert hit["url"] == "https://a.com/2" and hit["feed_content"] is None
    assert abs((NOW - timedelta(hours=2)) - hit["published_at"]) < timedelta(seconds=2)

    [undated] = parse_feed(_rss([{"url": "https://a.com/3", "title": "U"}]), "x")
    assert undated["published_at"] is None
    assert parse_feed(_rss([{"url": "", "title": "no link"}]), "x") == []


# ---------------------------------------------------------------------------
# Fakes
# ---------------------------------------------------------------------------


def _doc(url: str, markdown: str = "# body", extraction: dict[str, Any] | None = None) -> Any:
    return SimpleNamespace(
        markdown=markdown,
        json=extraction,
        metadata=SimpleNamespace(
            source_url=url, url=url, published_time="2026-08-22T10:00:00Z",
            credits_used=5 if extraction else 1,
        ),
    )


class FakeFirecrawl:
    """Serves scrape documents from `docs`; records calls."""

    def __init__(self, docs: dict[str, Any]) -> None:
        self.docs = docs
        self.scrape_calls: list[dict[str, Any]] = []

    def batch_scrape(self, urls: list[str], **kwargs: Any) -> Any:
        self.scrape_calls.append({"urls": list(urls), **kwargs})
        return SimpleNamespace(data=[self.docs[u] for u in urls if u in self.docs])

    def scraped(self) -> list[str]:
        return [u for call in self.scrape_calls for u in call["urls"]]


def _fetcher(feeds: dict[str, str]):
    def fetch(url: str) -> str:
        if url not in feeds:
            raise RuntimeError(f"503 for {url}")
        return feeds[url]
    return fetch


def _run(
    client: FakeFirecrawl,
    fetch: Any,
    config: dict[str, Any],
    tmp_path: Path,
    name: str = "news_test",
) -> dlt.Pipeline:
    """Extract through a real dlt pipeline into DuckDB so resource_state is live."""
    cfg = {"api_key": "fc-test", "extract_keywords": KEYWORDS, **config}
    pipeline = dlt.pipeline(
        pipeline_name=name,
        destination=dlt.destinations.duckdb(str(tmp_path / f"{name}.duckdb")),
        dataset_name="raw_test",
        pipelines_dir=str(tmp_path / "pipelines"),
    )
    pipeline.run(firecrawl_news(name, cfg, client=client, fetch_feed=fetch))
    return pipeline


def _count(pipeline: dlt.Pipeline, table: str) -> int:
    with pipeline.sql_client() as c:
        return c.execute_sql(f"SELECT COUNT(*) FROM {table}")[0][0]


def _query(pipeline: dlt.Pipeline, sql: str) -> list[tuple[Any, ...]]:
    with pipeline.sql_client() as c:
        return c.execute_sql(sql)


# ---------------------------------------------------------------------------
# The source
# ---------------------------------------------------------------------------

EXTRACTION = {
    "headline": "Chubb out",
    "published_at": "2026-08-21T20:00:00Z",
    "player_mentions": [
        {"player_name": "Nick Chubb", "team": "Texans", "context": "injury", "detail": "x"},
        {"player_name": "nick chubb", "team": "Texans", "context": "injury", "detail": "dup"},
        {"player_name": "Joe Mixon", "team": "Texans", "context": "lineup", "detail": "y"},
        {"player_name": "", "team": "Texans", "context": "other", "detail": "nameless"},
    ],
}

WIRE = "https://wire.example/feed"
ARTICLES = "https://articles.example/rss"


def test_extract_modes_route_urls_and_rows_land(tmp_path: Path) -> None:
    fetch = _fetcher({
        WIRE: _rss([{"url": "https://a.com/1", "title": "Roster move", "content": "<p>full</p>", "age_hours": 1}]),
        ARTICLES: _rss([
            {"url": "https://b.com/2", "title": "Chubb ruled out", "summary": "injury news", "age_hours": 2},
            {"url": "https://b.com/3", "title": "Camp notebook", "summary": "nothing to see", "age_hours": 3},
        ]),
    })
    docs = {
        "https://a.com/1": _doc("https://a.com/1", extraction=EXTRACTION),
        "https://b.com/2": _doc("https://b.com/2", extraction={"headline": "h", "player_mentions": []}),
        "https://b.com/3": _doc("https://b.com/3"),
    }
    client = FakeFirecrawl(docs)
    feeds = [
        {"name": "wire", "url": WIRE, "extract": "all"},
        {"name": "articles", "url": ARTICLES},   # default: gated
    ]

    pipeline = _run(client, fetch, {"feeds": feeds}, tmp_path)

    assert len(client.scrape_calls) == 2
    extracted, plain = client.scrape_calls
    # wire item extracted without keywords; gated item extracted on "out"/"injury"
    assert extracted["urls"] == ["https://a.com/1", "https://b.com/2"]
    assert extracted["formats"][0] == "markdown" and extracted["formats"][1]["type"] == "json"
    assert plain["urls"] == ["https://b.com/3"] and plain["formats"] == ["markdown"]
    assert extracted["only_main_content"] is True and extracted["wait_timeout"] == 300

    assert _count(pipeline, "news_articles") == 3
    rows = _query(
        pipeline,
        "SELECT url, feed, extract_mode, is_extracted, feed_content, "
        "feed_published_at IS NOT NULL, published_at IS NOT NULL "
        "FROM news_articles ORDER BY url",
    )
    assert rows == [
        ("https://a.com/1", "wire", "all", True, "<p>full</p>", True, True),
        ("https://b.com/2", "articles", "gated", True, None, True, True),
        ("https://b.com/3", "articles", "gated", False, None, True, True),
    ]
    # two distinct names; the case-duplicate and the nameless mention are dropped
    mentions = _query(pipeline, "SELECT player_name, headline FROM news_player_mentions ORDER BY 1")
    assert mentions == [("Joe Mixon", "Chubb out"), ("Nick Chubb", "Chubb out")]
    tables = {r[0] for r in _query(pipeline, "SELECT table_name FROM information_schema.tables")}
    assert not any(t.startswith("news_articles__") for t in tables)


def test_extract_none_never_sends_json(tmp_path: Path) -> None:
    fetch = _fetcher({WIRE: _rss([{"url": "https://a.com/1", "title": "Chubb out injury", "age_hours": 1}])})
    client = FakeFirecrawl({"https://a.com/1": _doc("https://a.com/1")})

    _run(client, fetch, {"feeds": [{"name": "w", "url": WIRE, "extract": "none"}]}, tmp_path)

    assert len(client.scrape_calls) == 1
    assert client.scrape_calls[0]["formats"] == ["markdown"]


def test_stale_excluded_and_repeated_items_never_reach_scrape(tmp_path: Path) -> None:
    fetch = _fetcher({
        WIRE: _rss([
            {"url": "https://old.com/1", "title": "Old", "age_hours": 49},
            {"url": "https://theathletic.com/x", "title": "Paywalled", "age_hours": 1},
            {"url": "https://a.com/1", "title": "Fresh", "age_hours": 1},
        ]),
        ARTICLES: _rss([{"url": "https://a.com/1", "title": "Fresh (again, other feed)", "age_hours": 1}]),
    })
    client = FakeFirecrawl({"https://a.com/1": _doc("https://a.com/1")})
    feeds = [{"name": "w", "url": WIRE}, {"name": "a", "url": ARTICLES}]

    _run(client, fetch, {"feeds": feeds, "exclude_domains": ["theathletic.com"]}, tmp_path)

    assert client.scraped() == ["https://a.com/1"]


def test_failing_feed_is_skipped_and_others_still_load(tmp_path: Path) -> None:
    fetch = _fetcher({ARTICLES: _rss([{"url": "https://a.com/1", "title": "Fresh", "age_hours": 1}])})
    client = FakeFirecrawl({"https://a.com/1": _doc("https://a.com/1")})
    feeds = [{"name": "dead", "url": "https://dead.example/feed"}, {"name": "a", "url": ARTICLES}]

    pipeline = _run(client, fetch, {"feeds": feeds}, tmp_path)

    assert client.scraped() == ["https://a.com/1"]
    assert _count(pipeline, "news_articles") == 1


def test_seen_urls_are_skipped_on_the_next_run(tmp_path: Path) -> None:
    fetch = _fetcher({WIRE: _rss([
        {"url": "https://a.com/1", "title": "One", "age_hours": 1},
        {"url": "https://b.com/2", "title": "Two", "age_hours": 2},
    ])})
    client = FakeFirecrawl({"https://a.com/1": _doc("https://a.com/1"), "https://b.com/2": _doc("https://b.com/2")})
    feeds = [{"name": "w", "url": WIRE}]

    pipeline = _run(client, fetch, {"feeds": feeds}, tmp_path)
    assert sorted(client.scraped()) == ["https://a.com/1", "https://b.com/2"]

    client.scrape_calls.clear()
    pipeline = _run(client, fetch, {"feeds": feeds}, tmp_path)
    assert client.scrape_calls == [], "a seen URL must not spend a scrape credit"
    assert _count(pipeline, "news_articles") == 2  # merge on url, no growth


def test_url_with_no_document_is_retried_next_run(tmp_path: Path) -> None:
    fetch = _fetcher({WIRE: _rss([
        {"url": "https://a.com/1", "title": "One", "age_hours": 1},
        {"url": "https://b.com/2", "title": "Two", "age_hours": 2},
    ])})
    # b times out this run: the fake returns no document for it
    client = FakeFirecrawl({"https://a.com/1": _doc("https://a.com/1")})
    feeds = [{"name": "w", "url": WIRE}]

    pipeline = _run(client, fetch, {"feeds": feeds}, tmp_path)
    assert _count(pipeline, "news_articles") == 1

    client.docs["https://b.com/2"] = _doc("https://b.com/2")
    client.scrape_calls.clear()
    pipeline = _run(client, fetch, {"feeds": feeds}, tmp_path)
    assert client.scraped() == ["https://b.com/2"]
    assert _count(pipeline, "news_articles") == 2


def test_cap_keeps_the_newest_items(tmp_path: Path) -> None:
    # listed oldest first in the feed; the cap must still pick the two newest
    fetch = _fetcher({WIRE: _rss([
        {"url": f"https://a.com/{i}", "title": f"story {i}", "age_hours": 10 - i} for i in range(5)
    ])})
    client = FakeFirecrawl({f"https://a.com/{i}": _doc(f"https://a.com/{i}") for i in range(5)})

    _run(client, fetch, {"feeds": [{"name": "w", "url": WIRE}], "max_scrapes_per_run": 2}, tmp_path)

    assert client.scraped() == ["https://a.com/4", "https://a.com/3"]


@pytest.mark.parametrize(
    "config, match",
    [
        ({"feeds": []}, "feeds"),
        ({"feeds": [{"name": "x"}]}, "name and a url"),
        ({"feeds": [{"name": "x", "url": "https://f", "extract": "maybe"}]}, "extract must be"),
    ],
)
def test_bad_feed_config_is_rejected_before_any_call(config: dict[str, Any], match: str) -> None:
    with pytest.raises(ValueError, match=match):
        firecrawl_news("news_test", {"api_key": "x", **config}, client=FakeFirecrawl({}), fetch_feed=lambda u: "")
