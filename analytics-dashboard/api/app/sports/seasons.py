"""Resolving "which season type" from mart rows. Every season-grain mart
carries season_type, season_type_name and last_game_date, so the same two
helpers serve the standings, a team's page and the leaderboards."""

from typing import Any


def season_types(rows: list[dict[str, Any]]) -> list[str]:
    """The season types present, in calendar order (preseason first)."""
    seen: dict[str, int] = {}
    for r in rows:
        seen.setdefault(r["season_type_name"], r["season_type"])
    return sorted(seen, key=lambda name: seen[name])


def pick_season_type(rows: list[dict[str, Any]], name: str | None) -> str | None:
    """`name` when the rows have it; else the season type in progress, the one
    whose most recent game is latest; None when there is nothing."""
    if not rows:
        return None
    if name is not None:
        return name if any(r["season_type_name"] == name for r in rows) else None
    latest = max(rows, key=lambda r: (str(r.get("last_game_date") or ""), r["season_type"]))
    return latest["season_type_name"]
