{{ config(materialized='semantic_view') }}

/*
    sv_ncaaf_rankings -- the AP-style Top 25 poll, week by week.

    Grain: one row per season per week per ranked team (~375 rows per
    completed season, weeks 2-16). College football's signature dataset;
    no other sport in the account has a poll.

    ONE UNNAMED POLL: the source exposes a single poll with no identifier
    (66 first-place votes and 25 teams shape it like the AP poll). The view
    says "the poll" rather than promising AP specifically.

    is_latest_poll is the load-bearing dimension: it marks each season's
    most recent published week, so "the current top 25" is a flag filter
    rather than a max-week subquery the model would have to invent.
*/

tables (
    rankings as {{ ref('fact_ncaaf_ranking') }}
        primary key (ranking_key)
        with synonyms ('poll', 'top 25', 'AP poll', 'rankings')
        comment = 'One row per season, week and ranked team: the weekly Top 25 poll. Weeks run 2-16 (the week-2 poll is the preseason poll); week 1 has no poll. A rank tie can produce a 26th row.',

    teams as {{ ref('dim_ncaaf_team') }}
        primary key (team_key)
        with synonyms ('school', 'program')
        comment = 'The ranked team. Identified by college (the institution name).'
)

relationships (
    rankings_to_team as rankings (team_key) references teams (team_key)
)

dimensions (
    rankings.season as season
        comment = 'Poll season, 2024 onward. The 2026 season''s first poll (the preseason poll) publishes in mid-August 2026.',
    rankings.week as week
        comment = 'Poll week, 2-16. Week 2 is the preseason poll; there is no week-1 poll.',
    rankings.poll_rank as poll_rank
        with synonyms ('rank', 'ranking', 'position')
        comment = 'Position in the Top 25, 1 to 25. Ties are possible and produce two teams at one rank.',
    rankings.is_latest_poll as is_latest_poll
        with synonyms ('current poll', 'latest rankings')
        comment = 'True for each season''s most recent published week. THE definition of "current": filter this flag, never compute a max week.',
    rankings.trend_text as trend_text
        comment = 'Movement versus the prior week as the source spells it: ''+3'', ''-1'', or ''-'' for no move.',
    rankings.rank_change as rank_change
        comment = 'Movement as a signed integer; positive means the team moved UP. NULL for no move or a new entry.',
    rankings.record_text as record_text
        with synonyms ('record')
        comment = 'The team''s W-L record as published with the poll.',
    teams.college as college
        with synonyms ('team', 'school', 'program name')
        comment = 'The ranked institution, e.g. ''Ohio State''.'
        sample_values ('Ohio State', 'Alabama', 'Indiana', 'Georgia'),
    teams.team_full_name as team_full_name
        comment = 'Institution plus mascot.',
    teams.conference_name as conference_name
        with synonyms ('conference')
        comment = 'The team''s CURRENT conference (realignment history is not tracked on the team).'
)

metrics (
    rankings.appearances as count(rankings.ranking_key)
        with synonyms ('weeks ranked', 'poll appearances')
        comment = 'Number of poll rows. Grouped by team, the number of weeks that team was ranked.',
    rankings.best_rank as min(rankings.poll_rank)
        with synonyms ('highest ranking', 'peak rank')
        comment = 'Best (numerically lowest) rank achieved in the grouping.',
    rankings.average_rank as avg(rankings.poll_rank)
        comment = 'Average rank across the grouped poll rows.',
    rankings.total_first_place_votes as sum(rankings.first_place_votes)
        comment = 'First-place votes summed across the grouped rows.'
)

comment = 'The weekly Top 25 poll (AP-shaped, the source names no poll) for the 2024+ seasons: rank, movement, record and first-place votes per team per week. Use it for current rankings, a team''s poll history, best rank, weeks ranked and who is number one. The current poll is is_latest_poll = true. Carries no game results or schedules; those belong to the performance and schedule views.'

ai_sql_generation 'CURRENT MEANS is_latest_poll: for "the current top 25", "who is ranked", or "where is X ranked", filter is_latest_poll = true and the season in question (default the latest season present). Never compute max(week) yourself.
RANK DIRECTION: poll_rank 1 is best. "Higher ranked" means a LOWER poll_rank; order rankings ascending by poll_rank.
MOVEMENT: rank_change is signed, positive = moved up. trend_text ''-'' means no movement, and a NULL rank_change with a row present usually means a new entrant that week.
TEAMS ARE IDENTIFIED BY COLLEGE (''Ohio State''), not the mascot.
UNRANKED IS ABSENCE: a team outside the Top 25 has NO row that week. "Is X ranked" with no matching row means no; do not treat absence as an error.
WEEK 2 IS THE FIRST POLL of a season (the preseason poll); week 1 never has rows. Weeks run 2-16.
ONE POLL ONLY: the source exposes a single unnamed poll. If asked about the Coaches Poll or CFP rankings specifically, say the source does not distinguish polls.
TIES EXIST: two teams can share a rank, so a week can hold 26 rows and rank alone is not a unique key.'

ai_question_categorization 'Answer questions about the college football Top 25 poll: current rankings, who is number one, a team''s rank or poll history, movement week over week, first-place votes, weeks ranked and best rank.
If the question asks for game RESULTS, SCHEDULES, or player/team statistics, mark it out of scope and route it to the appropriate tool; this view holds poll rows only.
If the question names a season before 2024, say poll coverage starts at 2024.
If the question asks for the CFP selection committee rankings or the Coaches Poll specifically, say the source exposes one unnamed poll and does not distinguish them.'

ai_verified_queries (
    current_top_ten as (
        question 'Who is in the top 10 right now?'
        verified_at 1786320000
        onboarding_question true
        sql 'SELECT poll_rank, college, record_text, trend_text
             FROM SEMANTIC_VIEW({{ this }}
               DIMENSIONS rankings.poll_rank, teams.college,
                          rankings.record_text, rankings.trend_text,
                          rankings.is_latest_poll, rankings.season)
             WHERE is_latest_poll AND season = 2025
               AND poll_rank <= 10
             ORDER BY poll_rank'
    )
)
