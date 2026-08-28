{{ config(materialized='semantic_view') }}

/*
    What the news is saying about NFL players, at mention grain: one row per
    article x player, resolved to dim_player by name where possible. Reported
    text with a source and a timestamp. Deliberately NOT the official injury
    report and carries no statistics.
*/

tables (
    news_mentions as {{ ref('fact_player_news_mention') }}
        primary key (mention_key)
        with synonyms ('news', 'player news', 'reports', 'mentions', 'headlines')
        comment = 'One extracted player mention per news article, resolved to a player by name where possible. Reported text, not official status.',

    players as {{ ref('dim_player') }}
        primary key (player_key)
        comment = 'NFL player identity and position. Joined only for resolved mentions.',

    teams as {{ ref('dim_team') }}
        primary key (team_key)
        comment = 'The team the article associates with the mention, when recognized.'
)

relationships (
    mention_to_player as news_mentions (player_key) references players (player_key),
    mention_to_team as news_mentions (mention_team_key) references teams (team_key)
)

facts (
    news_mentions.candidate_count as candidate_count
        comment = 'Roster players sharing the mentioned name. Above 1 means the team named in the article decided the match.'
)

dimensions (
    players.full_name as full_name
        with synonyms ('player', 'player name')
        comment = 'Resolved player full name. NULL when the mention did not resolve to a roster player.',
    players.position_name as position_name
        comment = 'Normalized player position.',
    teams.team_full_name as team_full_name
        with synonyms ('team')
        comment = 'Team the article names for this mention, when recognized.',
    news_mentions.context as context
        with synonyms ('type of news', 'category')
        comment = 'What the article says about the player: injury, lineup, transaction, suspension, or other.'
        sample_values ('injury', 'lineup', 'transaction', 'suspension', 'other') is_enum,
    news_mentions.published_at as published_at
        with synonyms ('reported at', 'time', 'when')
        comment = 'When the article was published: the outlet timestamp, else the feed timestamp, else fetch time.',
    news_mentions.published_date as published_date
        comment = 'Calendar date of published_at.',
    news_mentions.feed as feed
        with synonyms ('source', 'outlet')
        comment = 'Source feed: pft (ProFootballTalk), pfr (Pro Football Rumors), cbs, espn, or club_<abbr> for a team site.',
    news_mentions.headline as headline
        comment = 'Article headline.',
    news_mentions.detail as detail
        with synonyms ('what was reported', 'summary')
        comment = 'One-sentence extracted detail about the player, as reported. Quote or paraphrase with the source and time.',
    news_mentions.url as url
        comment = 'Article URL.',
    news_mentions.player_name_text as player_name_text
        comment = 'Player name exactly as the article wrote it. Use when full_name is NULL.',
    news_mentions.resolution_method as resolution_method
        comment = 'How the name was matched to a roster player.'
        sample_values ('alias', 'exact', 'exact_team', 'ambiguous', 'unresolved', 'team_not_player') is_enum
)

metrics (
    news_mentions.mention_count as count(news_mentions.mention_key)
        comment = 'Number of player mentions.',
    news_mentions.article_count as count(distinct news_mentions.article_key)
        comment = 'Number of distinct articles.'
)

comment = 'What NFL news outlets and team sites are reporting about players, one row per article and player, with the outlet, publish time, a context tag and the reported detail. Mentions are matched to players by name. This is reported text, not the official injury report, and it carries no statistics or betting lines.'

ai_sql_generation 'REPORTED, NOT OFFICIAL: every row is text extracted from a news article. Never present a mention as an official injury designation (Questionable, Doubtful, Out) or as a statistic.
DEFAULT WINDOW: unless the user gives a period, filter published_date to the last 7 days and ORDER BY published_at DESC.
ALWAYS SHOW published_at, feed and detail with any mention, so the reader knows who said it and when.
RESOLVED ONLY BY DEFAULT: filter full_name IS NOT NULL when the question names a player. Use player_name_text only when asked for raw or unresolved mentions.
CONTEXT is a tag: injury, lineup, transaction, suspension, other. Filter on it when the question is about one kind of news.
NAME COLLISIONS: if a player name is ambiguous, use position and ask the user to disambiguate.'

ai_question_categorization 'Answer questions about what is being reported or written about an NFL player or team: latest news, injury chatter, practice notes, signings, cuts, suspensions as reported, and which outlets reported them.
If the question asks for an official injury designation, the filed injury report, practice participation or depth charts, route it to NFLAvailabilityAnalytics: news covers the reporting, availability covers the report.
If the question asks for statistics, results or records, route it to the performance tools.
If the question asks about betting lines or props, route it to NFLGameOddsAnalytics or NFLPlayerPropsAnalytics.'

ai_verified_queries (
    latest_player_news as (
        question 'What is the latest being reported about Patrick Mahomes?'
        verified_at 1787356800
        onboarding_question true
        sql 'SELECT full_name, published_at, feed, context, headline, detail, url
             FROM SEMANTIC_VIEW({{ this }}
               DIMENSIONS players.full_name, news_mentions.published_at,
                          news_mentions.feed, news_mentions.context,
                          news_mentions.headline, news_mentions.detail,
                          news_mentions.url)
             WHERE full_name = ''Patrick Mahomes''
             ORDER BY published_at DESC
             LIMIT 20'
    )
)
