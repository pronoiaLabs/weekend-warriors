{{ config(materialized='semantic_view') }}

/*
    sv_wnba_team_history -- final standings by season. Grain: team x season.

    235 rows: 17 franchises across the 19 seasons from 2008 to 2026.

    THIS IS THE ONLY MULTI-YEAR VIEW IN THE WNBA SET AND IT HAS NO NFL SIBLING.
    Every other WNBA source is 2026 only, so this is the one place a question
    like "how have the Aces done since 2019" can be answered at all. It is
    small on purpose: two tables and roughly 34 exposed columns, because the
    standings endpoint is all there is behind it.

    IT IS A SNAPSHOT FACT, not an event log. The measures are the state of each
    team''s record at the moment the standings endpoint was read. Wins sum
    across seasons; playoff_seed and games_behind do not.

    THE 2026 ROW IS MID-SEASON. The snapshot was taken at 2026-08-08 23:59 UTC
    while games keep landing daily, so aggregating the game log in
    sv_wnba_team_performance can give a team up to two more decided games than
    this view reports. The gap is expected and bounded, not a defect.

    ROW COUNTS PER SEASON ARE UNEVEN because the league changed size: 14 teams
    in 2008, 12 through most of the 2010s, 13 in 2025 and 15 in 2026. A
    "per team" average has to divide by that season''s team count, not by 15.
    The two folded franchises, the Sacramento Monarchs (last season 2009) and
    the Houston Comets (2008), explain the early gaps; the Golden State
    Valkyries (2025) and the two 2026 expansion clubs explain the late ones.

    NO CHAMPIONSHIPS. The source carries regular-season standings only. There
    is no finals result, no title count, no playoff series outcome and no
    postseason record anywhere in this view or in the warehouse behind it. A
    playoff seed is the furthest it goes.

    NO POINTS FOR OR AGAINST. The NFL standings source carries them and this
    one does not, so there is no season-grain scoring measure here at all.
*/

tables (
    team_seasons as {{ ref('fact_wnba_team_season') }}
        primary key (team_season_key)
        with synonyms ('standings', 'season records', 'team seasons', 'final standings')
        comment = 'One row per team per season, 2008 to 2026: overall record, home, away and conference splits, games behind and playoff seed. A snapshot of the standings, not a log of games.',

    teams as {{ ref('dim_wnba_team') }}
        primary key (team_key)
        comment = 'Team identity. Only the 17 franchises appear in standings; the All-Star and placeholder rows in this dimension never join here.'
)

relationships (
    team_seasons_to_team as team_seasons (team_key) references teams (team_key)
)

facts (
    -- overall record
    team_seasons.wins as wins
        comment = 'Regular season wins in this season.',
    team_seasons.losses as losses
        comment = 'Regular season losses in this season. There is no tie component: basketball has none.',
    team_seasons.games as games_played
        comment = 'Regular season games played in this season. For 2026 this is a mid-season count, not a full schedule.',
    team_seasons.win_pct_stored as win_pct
        comment = 'The source''s own winning percentage, a 0-1 fraction rounded to three decimal places. Passed through so the source stays authoritative. Do not sum it across seasons; use the career_win_pct metric instead.',

    -- position in the standings
    team_seasons.games_behind as games_behind
        comment = 'Games behind the conference leader at snapshot time. 0.0 for a leader. A within-season position, meaningless when summed across seasons.',
    team_seasons.playoff_seed as playoff_seed
        comment = 'Conference seed, 1 to 8, populated on every row. It is a position and NOT a qualification flag: the WNBA has changed the size of its playoff field several times over these 19 seasons, so no made-the-playoffs column is derived from it.',

    -- splits
    team_seasons.home_wins as home_wins comment = 'Wins in home games.',
    team_seasons.home_losses as home_losses comment = 'Losses in home games.',
    team_seasons.away_wins as away_wins comment = 'Wins in road games.',
    team_seasons.away_losses as away_losses comment = 'Losses in road games.',
    team_seasons.conference_wins as conference_wins comment = 'Wins against teams in the same conference.',
    team_seasons.conference_losses as conference_losses comment = 'Losses against teams in the same conference.'
)

dimensions (
    -- who
    teams.team_abbreviation as team_abbreviation
        comment = 'Short team code, two or three letters, e.g. LV, NY, MIN.'
        sample_values ('LV', 'NY', 'MIN', 'PHX', 'SEA', 'IND', 'CON', 'SAC', 'HOU'),
    teams.team_full_name as team_full_name
        comment = 'Full team name. The two 2026 expansion clubs read as just Fire and Tempo, without a city, because that is how the source spells them.'
        sample_values ('Las Vegas Aces', 'New York Liberty', 'Minnesota Lynx', 'Seattle Storm', 'Sacramento Monarchs', 'Houston Comets'),
    teams.team_city as team_city
        comment = 'City or region. NULL for the two 2026 expansion clubs.'
        sample_values ('Las Vegas', 'New York', 'Minnesota', 'Seattle', 'Indiana'),
    teams.team_nickname as team_nickname
        comment = 'Nickname only, without the city, e.g. Aces, Liberty, Lynx.'
        sample_values ('Aces', 'Liberty', 'Lynx', 'Storm', 'Fever', 'Monarchs', 'Comets'),
    teams.is_franchise as is_franchise
        comment = 'True for all 17 teams that appear in standings. False rows in the dimension are All-Star squads and placeholders and never join to a season row.',
    teams.is_defunct as is_defunct
        comment = 'True for the two folded franchises, the Sacramento Monarchs (last season 2009) and the Houston Comets (2008). Their season rows are real history, not bad data. A question about how many teams there are wants is_franchise = true and is_defunct = false together.',

    -- when and where
    team_seasons.season as season
        with synonyms ('year', 'campaign')
        comment = 'WNBA season, 2008 through 2026. 2026 is in progress. Coverage per season is uneven because the league expanded and two franchises folded.',
    team_seasons.conference as conference
        with synonyms ('east or west', 'league conference')
        comment = 'The conference this team sat in THAT SEASON, taken from the standings row rather than from the team dimension, which knows only the current one. Populated on all 235 rows.'
        sample_values ('Eastern Conference', 'Western Conference') is_enum
)

metrics (
    -- coverage
    team_seasons.seasons_counted as count(team_seasons.team_season_key)
        with synonyms ('seasons', 'number of seasons', 'years')
        comment = 'Number of team-seasons. Grouped by team this is how many seasons that franchise has in the data, which is not the same as how many seasons it has existed.',

    -- totals across seasons
    team_seasons.total_wins as sum(team_seasons.wins)
        with synonyms ('all time wins', 'career wins')
        comment = 'Wins summed across the selected seasons. All time only within 2008 to 2026, which is the whole of this data.',
    team_seasons.total_losses as sum(team_seasons.losses)
        comment = 'Losses summed across the selected seasons.',
    team_seasons.total_games as sum(team_seasons.games)
        comment = 'Games played summed across the selected seasons.',
    team_seasons.career_win_pct as sum(team_seasons.wins)
                                   / nullif(sum(team_seasons.wins) + sum(team_seasons.losses), 0)
        with synonyms ('all time winning percentage', 'overall win rate', 'combined win percentage')
        comment = 'Wins over wins plus losses across the selected seasons, a 0-1 fraction. Computed from the components rather than by averaging the stored per-season win_pct, which would weight a 34 game season the same as a 44 game one. No tie term: basketball has none.',

    -- per season
    team_seasons.avg_wins_per_season as avg(team_seasons.wins)
        comment = 'Mean wins per season. Compare across eras with care: the schedule has grown from 34 games to 44.',
    team_seasons.avg_win_pct as avg(team_seasons.win_pct_stored)
        comment = 'Mean of the stored per-season winning percentages, a 0-1 fraction. Use this for "typical season" questions and career_win_pct for "overall record" questions.',
    team_seasons.best_win_pct as max(team_seasons.win_pct_stored)
        with synonyms ('best season', 'peak win percentage')
        comment = 'Highest single-season winning percentage in the selection, a 0-1 fraction.',
    team_seasons.worst_win_pct as min(team_seasons.win_pct_stored)
        comment = 'Lowest single-season winning percentage in the selection, a 0-1 fraction.',
    team_seasons.most_wins_in_a_season as max(team_seasons.wins)
        comment = 'Highest single-season win total in the selection.',

    -- position
    team_seasons.best_playoff_seed as min(team_seasons.playoff_seed)
        with synonyms ('highest seed', 'top seed')
        comment = 'Best conference seed achieved, where 1 is best. MIN is the right aggregate because a lower seed number is a better finish.',
    team_seasons.avg_playoff_seed as avg(team_seasons.playoff_seed)
        comment = 'Mean conference seed across the selected seasons. Lower is better.',

    -- splits
    team_seasons.total_home_wins as sum(team_seasons.home_wins)
        comment = 'Home wins across the selected seasons.',
    team_seasons.total_away_wins as sum(team_seasons.away_wins)
        comment = 'Road wins across the selected seasons.',
    team_seasons.home_win_pct as sum(team_seasons.home_wins)
                                 / nullif(sum(team_seasons.home_wins) + sum(team_seasons.home_losses), 0)
        with synonyms ('home record', 'record at home')
        comment = 'Home wins over home games, a 0-1 fraction.',
    team_seasons.away_win_pct as sum(team_seasons.away_wins)
                                 / nullif(sum(team_seasons.away_wins) + sum(team_seasons.away_losses), 0)
        with synonyms ('road record', 'record on the road')
        comment = 'Road wins over road games, a 0-1 fraction.',
    team_seasons.conference_win_pct as sum(team_seasons.conference_wins)
                                       / nullif(sum(team_seasons.conference_wins) + sum(team_seasons.conference_losses), 0)
        with synonyms ('conference record', 'record in conference')
        comment = 'Wins over games against same-conference opponents, a 0-1 fraction.'
)

comment = 'WNBA regular season standings at team-by-season grain, 2008 through 2026. 235 rows covering 17 franchises, including the two that folded. This is the ONLY multi-season WNBA view: use it for franchise history, year-over-year trends, all time records, home, road and conference splits by season, games behind and playoff seeding. Does NOT contain championships, finals results, playoff series outcomes or postseason records; individual game results; points scored or allowed; player statistics; or any measure of a team at a grain finer than a season.'

ai_sql_generation 'STANDINGS DERIVED: every row here is one team in one season as the standings endpoint reported it, not a roll-up of games. The measures are regular season only. There is exactly one row per team per season, so counting rows counts team-seasons.
SEASON COVERAGE: 2008 through 2026, and 2026 is IN PROGRESS. Its row is a live snapshot taken at 2026-08-08 and can trail the game log by a day or two, so a 2026 record here may show up to two fewer decided games than the team performance view reports. Say so when a 2026 record is part of the answer, and do not treat the difference as an error.
COMMISSIONER''S CUP: Commissioner''s Cup group-stage games count toward these regular-season records and are not separable from them in this source.
NO CHAMPIONSHIPS: this data has NO championship, finals, title or playoff series information of any kind, and no postseason record. If the user asks how many titles a franchise has won, who won the finals, or how a team did in the playoffs, say plainly that the source carries regular-season standings and playoff seeds only, and do not infer a title from a top seed or a high win percentage.
PLAYOFF SEED IS NOT QUALIFICATION: playoff_seed is a conference position from 1 to 8 and is populated for every team in every season, including teams that missed the playoffs. It is NOT a made-the-playoffs flag. The size of the playoff field has changed several times across these 19 seasons, so do not apply a fixed cutoff to derive qualification.
SEED DIRECTION: a LOWER seed number is a BETTER finish. Use MIN, not MAX, for a best seed, and order ascending when ranking by seed.
RECORDS: express a record as wins-losses, for example 27-17. NEVER append a third number for ties: basketball has none and no tie column exists.
PERCENTAGE SCALE: win_pct and every computed rate metric here are 0 to 1 fractions. Multiply by 100 and round to one decimal place when presenting as a percentage, or present as a three-decimal winning percentage in the .750 style, but be consistent within one answer.
RATE COMPUTATION: for an overall record across several seasons use career_win_pct, which divides summed wins by summed games. Do not average the per-season win_pct, because season length has grown from 34 games to 44 and the seasons are not equally weighted.
UNEVEN LEAGUE SIZE: the league had 14 teams in 2008, 12 through most of the 2010s, 13 in 2025 and 15 in 2026. Any league average per team must divide by that season''s team count, so group by season rather than dividing by a constant.
COVERAGE GAPS ARE REAL HISTORY: the Sacramento Monarchs have no seasons after 2009 and the Houston Comets none after 2008 because both franchises folded, is_defunct = true. The Golden State Valkyries begin in 2025 and the two 2026 expansion clubs, Fire and Tempo, begin in 2026. When a franchise is missing from a season range, say why rather than reporting a zero.
NO SCORING DATA: this source carries no points for, points against or point differential at season grain. If the user asks about season scoring, say it must come from the game-level view.'

ai_question_categorization 'Answer questions about WNBA franchise history and season records from 2008 to 2026: wins, losses, winning percentage, year-over-year trends, all time records, home, road and conference splits, games behind, playoff seeding, and which franchises existed in which seasons.
If the question is about an INDIVIDUAL GAME, a game log, a scoring average, shooting efficiency, rebounding or any box score measure in the current season, mark it out of scope and route it to WNBATeamPerformanceAnalytics.
If the question is about an INDIVIDUAL PLAYER at any grain, mark it out of scope and route it to WNBAPlayerPerformanceAnalytics for box score production or WNBAPlayerAdvancedAnalytics for efficiency and usage.
If the question asks about CHAMPIONSHIPS, finals, titles, playoff series results or postseason records, do not attempt an answer. State that the source holds regular-season standings and playoff seeds only, and that no championship data exists anywhere in this warehouse.
If the question asks about SHOT LOCATION or zone shooting, explain that the data exists in the warehouse but is not exposed in any semantic view.
If the question asks for a PLAYER''s history across seasons, explain that only team standings go back to 2008; every player-level source covers the 2026 season only.
If a franchise is named by a relocated or former identity, ask the user to confirm which team they mean, since this source tracks teams by current identity and does not model relocations.'
