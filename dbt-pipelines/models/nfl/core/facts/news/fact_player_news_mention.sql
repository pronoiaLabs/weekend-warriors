{{
    config(
        materialized='table'
    )
}}

/*
    fact_player_news_mention -- what the news says about a player.
    Grain: article URL x player name as written (one extracted mention).

    The extraction hands us a name, not an id, so this model's job is identity.
    Each mention is resolved in a fixed order and the rule that fired is kept in
    resolution_method, so a consumer can choose how much trust to extend:

      team_not_player  the "name" is a team ("Tennessee Titans"). Not a miss.
      alias            seed_nfl_player_aliases knows the nickname ("Abe Lucas").
      exact            exactly one roster player has the normalized name.
      exact_team       several do, and the team the article names picks one.
      ambiguous        several do, and the article does not say which.
      unresolved       nobody on the roster has that name (coaches, retired
                       players, extraction noise).

    Unresolved and ambiguous rows STAY in the fact with player_key NULL. Dropping
    them would hide extraction quality; keeping them is what makes
    assert_news_mentions_resolve and the alias seed possible. Filter on
    player_key is not null for anything keyed.

    Names are compared after nfl_normalize_player_name on both sides (case,
    punctuation, Jr/III). The roster side is stg_nfl__players rather than
    dim_player because the team tiebreak needs each player's CURRENT team, which
    dim_player deliberately does not carry.

    No game_key: news is dated, not game-bound. Join through dim_date.
*/

with mentions as (

    select
        m.mention_key,
        m.article_key,
        m.url,
        m.player_name_text,
        m.player_name_normalized,
        m.team_text,
        upper(m.team_text)                                       as team_text_upper,
        m.context,
        m.detail,
        m.headline,
        coalesce(m.published_at, a.published_at_effective)       as published_at,
        coalesce(m.published_at, a.published_at_effective)::date as published_date,
        a.feed,
        a.extract_mode
    from {{ ref('stg_nfl__news_player_mentions') }} m
    inner join {{ ref('stg_nfl__news_articles') }} a
        on m.article_key = a.article_key

),

teams as (

    select
        team_key,
        team_id,
        upper(team_full_name)                                    as team_full_name_upper,
        upper(team_nickname)                                     as team_nickname_upper,
        {{ nfl_normalize_player_name('team_full_name') }}        as team_full_name_normalized,
        {{ nfl_normalize_player_name('team_nickname') }}         as team_nickname_normalized
    from {{ ref('dim_team') }}

),

players as (

    select
        p.player_key,
        p.player_id,
        {{ nfl_normalize_player_name('p.full_name') }}           as name_normalized,
        t.team_nickname_upper                                    as current_team_nickname_upper
    from {{ ref('stg_nfl__players') }} p
    left join teams t
        on p.current_team_id = t.team_id

),

aliases as (

    select
        {{ nfl_normalize_player_name('alias') }}                 as alias_normalized,
        player_id
    from {{ ref('seed_nfl_player_aliases') }}

),

-- Rule 1: the mention is a team name, not a person.
team_name_mentions as (

    select distinct m.mention_key
    from mentions m
    inner join teams t
        on m.player_name_normalized = t.team_full_name_normalized
        or m.player_name_normalized = t.team_nickname_normalized

),

-- Rule 2: the alias seed knows this spelling.
alias_hits as (

    select
        m.mention_key,
        p.player_key,
        p.player_id
    from mentions m
    inner join aliases a
        on m.player_name_normalized = a.alias_normalized
    inner join players p
        on a.player_id = p.player_id
    qualify row_number() over (partition by m.mention_key order by p.player_id) = 1

),

-- Rules 3 to 5: roster players sharing the normalized name, with a flag for
-- whether the team the article names is the candidate's current team.
candidates as (

    select
        m.mention_key,
        p.player_key,
        p.player_id,
        count(*) over (partition by m.mention_key)               as candidate_count,
        case
            when m.team_text_upper is not null
             and p.current_team_nickname_upper is not null
             and m.team_text_upper like '%' || p.current_team_nickname_upper || '%'
            then 1 else 0
        end                                                      as team_match
    from mentions m
    inner join players p
        on m.player_name_normalized = p.name_normalized

),

name_hits as (

    select
        mention_key,
        player_key,
        player_id,
        candidate_count,
        case
            when candidate_count = 1                             then 'exact'
            when team_match = 1 and team_match_count = 1         then 'exact_team'
            else 'ambiguous'
        end                                                      as method
    from (
        select
            c.*,
            sum(team_match) over (partition by mention_key)      as team_match_count
        from candidates c
    )
    qualify row_number() over (
        partition by mention_key order by team_match desc, player_id
    ) = 1

),

-- The team the article associates with the mention, when it is one we know.
-- Nickname containment covers "Cardinals" and "Arizona Cardinals" alike.
mention_teams as (

    select
        m.mention_key,
        t.team_key                                               as mention_team_key
    from mentions m
    inner join teams t
        on m.team_text_upper = t.team_full_name_upper
        or m.team_text_upper like '%' || t.team_nickname_upper || '%'
    qualify row_number() over (partition by m.mention_key order by t.team_id) = 1

),

resolved as (

    select
        m.*,
        mt.mention_team_key,
        case
            when tn.mention_key is not null                      then 'team_not_player'
            when ah.mention_key is not null                      then 'alias'
            when nh.method in ('exact', 'exact_team')            then nh.method
            when nh.method = 'ambiguous'                         then 'ambiguous'
            else 'unresolved'
        end                                                      as resolution_method,
        case
            when tn.mention_key is not null                      then null
            when ah.mention_key is not null                      then ah.player_key
            when nh.method in ('exact', 'exact_team')            then nh.player_key
        end                                                      as player_key,
        case
            when tn.mention_key is not null                      then null
            when ah.mention_key is not null                      then ah.player_id
            when nh.method in ('exact', 'exact_team')            then nh.player_id
        end                                                      as player_id,
        coalesce(nh.candidate_count, 0)                          as candidate_count
    from mentions m
    left join team_name_mentions tn on m.mention_key = tn.mention_key
    left join alias_hits ah         on m.mention_key = ah.mention_key
    left join name_hits nh          on m.mention_key = nh.mention_key
    left join mention_teams mt      on m.mention_key = mt.mention_key

)

select
    -- keys
    mention_key,
    article_key,
    player_key,
    player_id,
    mention_team_key,
    {{ dbt_utils.generate_surrogate_key(['published_date']) }}   as date_key,

    -- when
    published_at,
    published_date,

    -- what
    context,
    detail,
    headline,
    player_name_text,
    team_text,
    feed,
    url,
    extract_mode,

    -- how the name was matched
    resolution_method,
    candidate_count

from resolved
