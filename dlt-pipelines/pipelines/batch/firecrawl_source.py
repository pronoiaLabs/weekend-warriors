"""Firecrawl news source: curated-feed discovery, scrape and player-mention extraction.

WHY THIS EXISTS
    The rest_api source cannot express this pipeline. Discovery reads a list of RSS/Atom
    feeds whose items decide which URLs to fetch; the fetch is a Firecrawl batch job
    that has to be polled; and only some pages are worth the 5x-cost JSON extraction.
    Those are three calls with control flow between them, which is exactly the case
    AGENTS.md reserves custom source types for.

    Vendor and content are different axes here, a first for this repo: the source
    type, secret and env var are named for the vendor (`firecrawl`), the pipeline and
    its tables for the content (`nfl_news`).

CONTENTS
    1. Extraction schema ..... MENTION_SCHEMA, EXTRACT_PROMPT
    2. Pure helpers .......... parse_feed, is_fresh, extract_mode_for, gate,
                               prune_seen, is_excluded
    3. The source ............ firecrawl_news

WHAT ONE RUN DOES
    fetch each feed  ->  drop stale, excluded and seen items  ->  decide extraction
    per feed (all / gated / none)  ->  newest first, cap at max_scrapes_per_run
      ->  batch_scrape extracted URLs with markdown + json, the rest markdown only
      ->  yield one `news_articles` row per returned document
      ->  flatten extraction.player_mentions into `news_player_mentions`

WHY FEEDS, NOT SEARCH
    The first draft discovered URLs with Firecrawl's news search. It worked, and it was
    not deterministic: the same query returned different outlets on different days and
    "NFL depth chart change" surfaced college depth charts and fantasy rankings. A feed
    is the opposite: a source we chose, read the same way every run, with the outlet's
    own publish timestamp. Firecrawl stays for what it is good at, rendering the page
    and extracting a schema from it. We own the source list, not the parsing.

    Measured live (Aug 2026, firecrawl-py 4.38): one batch_scrape call with
    formats=["markdown", {"type": "json", ...}] returns both at 5 credits per URL,
    markdown alone is 1. Feeds cost nothing, so the per-feed `extract` mode is what
    decides the bill.

THREE THINGS THE FIRST DRAFT GOT WRONG, ENCODED HERE
    - The gate is a whole-word match. A substring test lets `out` match "about" and
      `IR` match "first", so every article passed and extraction ran at 100%.
    - A URL is marked seen ONLY when its document came back. A scrape that times out is
      retried next run instead of being remembered as done with a NULL markdown.
    - There is no second fetch. Extraction rides in the same batch_scrape call.

WHERE IT LIVES
    Under `pipelines/` deliberately. The Dockerfile copies that package into the image,
    so this source ships with the runner. Code placed outside it works locally and
    vanishes inside the container. `firecrawl` and `feedparser` are imported inside the
    functions that need them so importing this module needs neither (CI import-checks
    with a minimal set).
"""

from __future__ import annotations

import html
import logging
import re
from datetime import date, datetime, timedelta, timezone
from typing import Any, Callable, Iterator
from urllib.parse import urlparse

import dlt

log = logging.getLogger("dlt_pipeline.firecrawl")

# ---------------------------------------------------------------------------
# 1. Extraction schema
#
# What the JSON pass asks Firecrawl for. Deliberately small: headline, publish date and
# the player mentions. Team is free text AS THE ARTICLE SAYS IT ("Cardinals", "Arizona
# Cardinals"); resolving it, and the player name, to keys is dbt's job, where the join
# doubles as a continuous accuracy check on the extraction.
# ---------------------------------------------------------------------------

MENTION_SCHEMA: dict[str, Any] = {
    "type": "object",
    "properties": {
        "headline": {"type": "string"},
        "author": {"type": "string"},
        "published_at": {
            "type": "string",
            "description": "ISO 8601 publish timestamp if the article states one",
        },
        "player_mentions": {
            "type": "array",
            "items": {
                "type": "object",
                "properties": {
                    "player_name": {"type": "string"},
                    "team": {"type": "string"},
                    "context": {
                        "type": "string",
                        "description": "one of: injury, lineup, transaction, suspension, other",
                    },
                    "detail": {"type": "string"},
                },
                "required": ["player_name", "context"],
            },
        },
    },
    "required": ["headline", "player_mentions"],
}

EXTRACT_PROMPT = (
    "Extract every NFL player mentioned in this article. For each, give the player's "
    "full name as written, the team the article associates them with, a context tag "
    "(injury, lineup, transaction, suspension, or other) and a one-sentence detail. "
    "Include the headline, author and the publish date as ISO 8601 if stated."
)

EXTRACT_MODES: tuple[str, ...] = ("all", "gated", "none")

_DEFAULTS: dict[str, Any] = {
    "extract_keywords": [],
    "exclude_domains": [],
    "max_age_hours": 48,
    "max_scrapes_per_run": 40,
    "seen_retention_days": 30,
    "wait_timeout": 300,
    "feed_timeout": 15,
}

_USER_AGENT = "weekend-warriors-nfl-news/0.1 (+dlt feed reader)"
_TAG_RE = re.compile(r"<[^>]+>")
_WS_RE = re.compile(r"\s+")


# ---------------------------------------------------------------------------
# 2. Pure helpers, kept free of dlt and the SDKs so they test in microseconds.
# ---------------------------------------------------------------------------


def strip_html(text: str | None) -> str | None:
    """Feed summaries arrive as HTML fragments; the gate wants words."""
    if not text:
        return None
    return _WS_RE.sub(" ", html.unescape(_TAG_RE.sub(" ", text))).strip() or None


def _entry_datetime(entry: Any) -> datetime | None:
    # feedparser normalizes every date format it understands to a UTC struct_time.
    for key in ("published_parsed", "updated_parsed"):
        t = entry.get(key)
        if t:
            return datetime(*t[:6], tzinfo=timezone.utc)
    return None


def parse_feed(xml: str, feed_name: str) -> list[dict[str, Any]]:
    """Parse one RSS/Atom document into hits: url, title, snippet, published_at, content.

    Entries without a link are dropped; everything else is kept, dates included as
    None when absent, so freshness decisions happen in the caller with the run's clock.
    """
    import feedparser  # noqa: PLC0415

    parsed = feedparser.parse(xml)
    hits: list[dict[str, Any]] = []
    for entry in parsed.entries:
        url = entry.get("link")
        if not url:
            continue
        content = None
        for block in entry.get("content") or []:
            if block.get("value"):
                content = block["value"]
                break
        hits.append(
            {
                "url": url,
                "title": strip_html(entry.get("title")),
                "snippet": strip_html(entry.get("summary") or entry.get("description")),
                "published_at": _entry_datetime(entry),
                "feed_content": content,
                "feed": feed_name,
            }
        )
    return hits


def is_fresh(published_at: datetime | None, now: datetime, max_age_hours: int) -> bool:
    """Undated items are kept: a missing date is the feed's fault, not a reason to skip."""
    if published_at is None:
        return True
    return published_at >= now - timedelta(hours=max_age_hours)


def extract_mode_for(feed: dict[str, Any]) -> str:
    """Validate a feed entry's `extract` (default `gated`) at build time, not at 09:00 UTC."""
    mode = str(feed.get("extract", "gated")).lower()
    if mode not in EXTRACT_MODES:
        raise ValueError(
            f"feed '{feed.get('name')}': extract must be one of {', '.join(EXTRACT_MODES)}, "
            f"got {feed.get('extract')!r}"
        )
    return mode


def gate(title: str | None, snippet: str | None, keywords: list[str]) -> list[str]:
    """Return the keywords that appear as whole words in `title + snippet`.

    Case-insensitive, except that an all-caps keyword (`IR`) must match in its own case:
    lowercased `ir` is a fragment of "first", "their" and "third", and with a
    case-insensitive match it would fire on nearly every article.
    """
    text = f"{title or ''} {snippet or ''}"
    hits: list[str] = []
    for kw in keywords:
        flags = 0 if kw.isupper() else re.IGNORECASE
        if re.search(r"\b" + re.escape(kw) + r"\b", text, flags):
            hits.append(kw)
    return hits


def prune_seen(seen: dict[str, str], today: date, retention_days: int) -> dict[str, str]:
    """Drop seen-URL entries first seen more than `retention_days` before `today`.

    Values are ISO dates. An unparseable value is dropped too, so a corrupt entry can
    only cost one re-scrape rather than sticking forever.
    """
    cutoff = today - timedelta(days=retention_days)
    kept: dict[str, str] = {}
    for url, first_seen in seen.items():
        try:
            if date.fromisoformat(first_seen) >= cutoff:
                kept[url] = first_seen
        except (TypeError, ValueError):
            continue
    return kept


def is_excluded(url: str, domains: list[str]) -> bool:
    """True if the URL's host is one of `domains` or a subdomain of one."""
    host = (urlparse(url).netloc or "").lower()
    for d in domains:
        d = d.lower().lstrip(".")
        if host == d or host.endswith("." + d):
            return True
    return False


def _parse_iso(value: Any) -> datetime | None:
    """Scrape metadata gives publish time as an ISO string; keep the column one type."""
    if not isinstance(value, str) or not value:
        return None
    try:
        parsed = datetime.fromisoformat(value.replace("Z", "+00:00"))
    except ValueError:
        return None
    return parsed if parsed.tzinfo else parsed.replace(tzinfo=timezone.utc)


# ---------------------------------------------------------------------------
# 3. The source
# ---------------------------------------------------------------------------


def firecrawl_news(
    name: str,
    config: dict[str, Any],
    client: Any = None,
    fetch_feed: Callable[[str], str] | None = None,
) -> Any:
    """Build the source. `name` becomes the dlt schema name; pass the pipeline name.

    `client` (Firecrawl) and `fetch_feed` (url -> feed text) are injected by tests. In
    a real run the client is built from `config["api_key"]`, which run.py has already
    resolved from its `secret:` reference, and feeds are fetched with dlt's retrying
    requests helper.
    """
    feeds: list[dict[str, Any]] = [dict(f) for f in (config.get("feeds") or [])]
    if not feeds:
        raise ValueError(f"{name}: config.feeds must list at least one feed")
    for feed in feeds:
        if not feed.get("name") or not feed.get("url"):
            raise ValueError(f"{name}: every feed needs a name and a url, got {feed!r}")
        feed["extract"] = extract_mode_for(feed)

    cfg = {**_DEFAULTS, **config}
    keywords: list[str] = list(cfg["extract_keywords"])
    exclude: list[str] = list(cfg["exclude_domains"])
    max_age_hours = int(cfg["max_age_hours"])
    max_scrapes = int(cfg["max_scrapes_per_run"])
    retention = int(cfg["seen_retention_days"])
    wait_timeout = int(cfg["wait_timeout"])
    feed_timeout = int(cfg["feed_timeout"])

    if client is None:
        from firecrawl import Firecrawl  # noqa: PLC0415

        client = Firecrawl(api_key=cfg["api_key"])

    if fetch_feed is None:
        from dlt.sources.helpers import requests as dlt_requests  # noqa: PLC0415

        def _default_fetch(url: str) -> str:
            response = dlt_requests.get(
                url, timeout=feed_timeout, headers={"User-Agent": _USER_AGENT}
            )
            response.raise_for_status()
            return response.text

        fetch_feed = _default_fetch

    json_format = {"type": "json", "schema": MENTION_SCHEMA, "prompt": EXTRACT_PROMPT}

    def _scrape(urls: list[str], formats: list[Any]) -> dict[str, Any]:
        """batch_scrape `urls`; return {requested_url: document} for those that came back."""
        if not urls:
            return {}
        job = client.batch_scrape(
            urls,
            formats=formats,
            only_main_content=True,
            wait_timeout=wait_timeout,
        )
        docs: dict[str, Any] = {}
        for doc in getattr(job, "data", None) or []:
            meta = doc.metadata
            key = getattr(meta, "source_url", None) or getattr(meta, "url", None)
            if key:
                docs[key] = doc
        return docs

    # max_table_nesting=0 keeps `extraction` (a dict) and `matched_keywords` (a list)
    # as JSON columns on the article row instead of fanning out into child tables.
    # The mentions get their own flat table through the transformer below, keyed on
    # (url, player_name) rather than on dlt's parent id.
    @dlt.source(name=name, max_table_nesting=0)
    def _source() -> Any:
        @dlt.resource(name="news_articles", primary_key="url", write_disposition="merge")
        def news_articles() -> Iterator[dict[str, Any]]:
            now = datetime.now(timezone.utc)
            today = now.date()
            state = dlt.current.resource_state()
            seen: dict[str, str] = prune_seen(state.get("seen") or {}, today, retention)
            state["seen"] = seen

            # Discovery. Feeds are free, so every one is read every run; nothing below
            # spends a scrape credit on a URL that is stale, excluded, already seen,
            # or repeated across feeds. A feed that fails is skipped, never fatal.
            fresh: list[dict[str, Any]] = []
            in_run: set[str] = set()
            n_hits = n_stale = n_excluded = n_seen = n_failed = 0
            for feed in feeds:
                try:
                    hits = parse_feed(fetch_feed(feed["url"]), feed["name"])
                except Exception as exc:  # noqa: BLE001
                    n_failed += 1
                    log.warning("%s: feed %s skipped: %s", name, feed["name"], exc)
                    continue
                n_feed_fresh = 0
                for d in hits:
                    n_hits += 1
                    url = d["url"]
                    if not is_fresh(d["published_at"], now, max_age_hours):
                        n_stale += 1
                        continue
                    if is_excluded(url, exclude):
                        n_excluded += 1
                        continue
                    if url in seen:
                        n_seen += 1
                        continue
                    if url in in_run:
                        continue
                    in_run.add(url)
                    mode = feed["extract"]
                    d["extract_mode"] = mode
                    d["matched_keywords"] = (
                        gate(d["title"], d["snippet"], keywords) if mode == "gated" else []
                    )
                    d["extract"] = mode == "all" or (mode == "gated" and bool(d["matched_keywords"]))
                    fresh.append(d)
                    n_feed_fresh += 1
                log.info("%s: feed %s: %d items, %d fresh", name, feed["name"], len(hits), n_feed_fresh)

            # Newest first, so the cap sheds the oldest backlog rather than the latest news.
            floor = datetime.min.replace(tzinfo=timezone.utc)
            fresh.sort(key=lambda d: d["published_at"] or floor, reverse=True)
            dropped = max(0, len(fresh) - max_scrapes)
            fresh = fresh[:max_scrapes]
            log.info(
                "%s: %d items from %d feeds (%d failed), %d stale, %d excluded, "
                "%d already seen, %d fresh, %d dropped by cap",
                name, n_hits, len(feeds), n_failed, n_stale, n_excluded, n_seen,
                len(fresh), dropped,
            )
            if dropped:
                log.warning(
                    "%s: max_scrapes_per_run=%d left %d fresh URLs unscraped; they are "
                    "retried next run while the feeds and max_age_hours still cover them",
                    name, max_scrapes, dropped,
                )

            extracted = [d["url"] for d in fresh if d["extract"]]
            plain = [d["url"] for d in fresh if not d["extract"]]
            docs = _scrape(extracted, ["markdown", json_format])
            docs.update(_scrape(plain, ["markdown"]))
            log.info(
                "%s: scraped %d of %d (%d with extraction)",
                name, len(docs), len(fresh), len(extracted),
            )

            fetched_at = datetime.now(timezone.utc)
            for d in fresh:
                doc = docs.get(d["url"])
                if doc is None:
                    # Left out of `seen` on purpose: the next run retries it.
                    log.warning("%s: no document returned for %s", name, d["url"])
                    continue
                meta = doc.metadata
                extraction = getattr(doc, "json", None)
                yield {
                    "url": d["url"],
                    "title": d["title"],
                    "snippet": d["snippet"],
                    "feed": d["feed"],
                    "feed_published_at": d["published_at"],
                    "feed_content": d["feed_content"],
                    "matched_keywords": d["matched_keywords"],
                    "extract_mode": d["extract_mode"],
                    "is_extracted": d["extract"],
                    "markdown": getattr(doc, "markdown", None),
                    "published_at": d["published_at"]
                    or _parse_iso(getattr(meta, "published_time", None)),
                    "fetched_at": fetched_at,
                    "credits_used": getattr(meta, "credits_used", None),
                    "extraction": extraction if isinstance(extraction, dict) else None,
                }
                seen[d["url"]] = today.isoformat()

        @dlt.transformer(
            data_from=news_articles,
            name="news_player_mentions",
            primary_key=["url", "player_name"],
            write_disposition="merge",
        )
        def news_player_mentions(article: dict[str, Any]) -> Iterator[dict[str, Any]]:
            extraction = article.get("extraction") or {}
            emitted: set[str] = set()
            for m in extraction.get("player_mentions") or []:
                player_name = (m.get("player_name") or "").strip()
                if not player_name or player_name.lower() in emitted:
                    continue
                emitted.add(player_name.lower())
                yield {
                    "url": article["url"],
                    "player_name": player_name,
                    "team": m.get("team"),
                    "context": m.get("context"),
                    "detail": m.get("detail"),
                    "headline": extraction.get("headline"),
                    "published_at": _parse_iso(extraction.get("published_at"))
                    or article.get("published_at"),
                }

        return news_articles, news_player_mentions

    return _source()
