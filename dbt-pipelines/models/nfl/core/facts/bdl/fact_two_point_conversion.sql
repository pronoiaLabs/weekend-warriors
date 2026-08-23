{{
    config(
        materialized='table'
    )
}}

/*
    fact_two_point_conversion -- two-point conversion attempts, credited to
    the players who ran, threw or caught them.
    Grain: play x role x participant. One play can yield two rows (passer and
    receiver); a failed attempt yields its participants with is_success false.

    WHY THIS EXISTS
    The box score (RAW.STATS, 116 columns) has no two-point conversion column
    at all, and FanDuel pays 2 points for one. The only record of a conversion
    is the text of the touchdown play it followed, in RAW.PLAYS, which names
    the players but carries no player id. So this fact parses the text and
    resolves the names against the roster that actually appeared in that game
    for that team (stg_nfl__player_stats), where an abbreviated name is almost
    always unique. fact_player_game_offense folds the successful rows into
    fanduel_points; nothing else needs to know the text was ever parsed.

    TWO TEXT FORMATS, measured 2026-08-22 over 2023 to 2026:
      GSIS (441 attempts, 208 successes), embedded after the touchdown:
        "...TOUCHDOWN. TWO-POINT CONVERSION ATTEMPT. G.Smith pass to T.Lockett
         is complete. ATTEMPT SUCCEEDS."
        "...TWO-POINT CONVERSION ATTEMPT. S.Barkley rushes right tackle.
         ATTEMPT SUCCEEDS."
      ESPN (44 attempts, 16 successes), a parenthetical on the scoring line:
        "Courtland Sutton 11 Yd pass from Russell Wilson (Javonte Williams Run
         for Two-Point Conversion)"
        "(Devin Singletary Pass to Darius Slayton for Two-Point Conversion)"
        failures: "(Two-Point Run Conversion Failed)", no names.
    GSIS names are abbreviated ("Der.Brown", "Mi.Wilson", "M.Alie-Cox",
    "R.O'Neal"): the text before the first period is a first-name prefix, the
    rest is the last name. ESPN names are full.

    RESOLUTION, recorded in resolution_method so misses stay visible:
      exact        one player who appeared in that game for that team matched
      exact_role   several did, and only one played the role the text names
                   (the passer is the one with pass attempts that day)
      alias        seed_nfl_player_aliases knew the spelling
      team_roster  nobody with a box-score line matched; the team's current
                   roster did, uniquely. No stats row means no offense-fact
                   row either, so the 2 points have nowhere to land yet.
      ambiguous    more than one matched and the role did not decide it
      unresolved   nobody matched
    role 'unparsed' marks a play whose attempt text matched no pattern, so
    tests/nfl/assert_two_point_plays_are_all_parsed.sql can fail on it rather
    than a scoring play vanishing.

    Regex escapes are doubled ('\\s') because dbt renders the file before
    Snowflake sees it; stg_nfl__players.sql uses the same convention. No lazy
    quantifiers: the GSIS segment is cut with split_part and a greedy trailing
    replace instead.
*/

with plays as (

    -- cheap prefilter: ~500 of 180k plays mention a two-point attempt
    select
        play_key,
        game_key,
        game_id,
        team_key,
        team_id,
        play_description
    from {{ ref('stg_nfl__plays') }}
    where play_description like '%TWO-POINT CONVERSION ATTEMPT%'
       or play_description like '%Two-Point%'

),

games as (

    select game_key, date_key, season, week, season_type
    from {{ ref('dim_game') }}

),

attempts as (

    select
        p.*,
        case
            when play_description like '%TWO-POINT CONVERSION ATTEMPT%' then 'gsis'
            else 'espn'
        end                                                             as text_format,

        -- GSIS: the text after the marker, with the outcome clause removed.
        -- The outcome is read from the OFFENSIVE clause only (see
        -- nfl_two_point_success): a defensive two-point return that follows
        -- a failed try also ends "ATTEMPT SUCCEEDS" and credits no one here.
        trim(regexp_replace(
            split_part(play_description, 'TWO-POINT CONVERSION ATTEMPT.', 2),
            '\\s*ATTEMPT (SUCCEEDS|FAILS).*$', ''
        ))                                                              as gsis_segment,
        {{ nfl_two_point_success('play_description') }}                 as gsis_success,

        -- ESPN: the parenthetical names the participants; a failure names none
        regexp_substr(play_description,
            '\\(([^()]+) Run for Two-Point Conversion\\)', 1, 1, 'e', 1) as espn_rusher,
        regexp_substr(play_description,
            '\\(([^()]+) Pass to ([^()]+) for Two-Point Conversion\\)', 1, 1, 'e', 1)
                                                                        as espn_passer,
        regexp_substr(play_description,
            '\\(([^()]+) Pass to ([^()]+) for Two-Point Conversion\\)', 1, 1, 'e', 2)
                                                                        as espn_receiver,
        play_description not ilike '%Conversion Failed)%'                as espn_success
    from plays p

),

parsed as (

    select
        a.*,
        regexp_substr(gsis_segment, '^(\\S+) pass to (\\S+) is (complete|incomplete|intercepted)', 1, 1, 'e', 1)
                                                                        as gsis_passer,
        regexp_substr(gsis_segment, '^(\\S+) pass to (\\S+) is (complete|incomplete|intercepted)', 1, 1, 'e', 2)
                                                                        as gsis_receiver,
        regexp_substr(gsis_segment, '^(\\S+) (rushes|scrambles|runs)', 1, 1, 'e', 1)
                                                                        as gsis_rusher
    from attempts a

),

-- one row per participant, or one 'unparsed' row when the text matched nothing
participants as (

    select play_key, game_key, game_id, team_key, team_id, play_description, text_format,
           gsis_success as is_success, 'pass' as role, gsis_passer as participant_text
    from parsed where text_format = 'gsis' and gsis_passer is not null
    union all
    select play_key, game_key, game_id, team_key, team_id, play_description, text_format,
           gsis_success, 'receive', gsis_receiver
    from parsed where text_format = 'gsis' and gsis_receiver is not null
    union all
    select play_key, game_key, game_id, team_key, team_id, play_description, text_format,
           gsis_success, 'rush', gsis_rusher
    from parsed where text_format = 'gsis' and gsis_rusher is not null
    union all
    select play_key, game_key, game_id, team_key, team_id, play_description, text_format,
           gsis_success, 'unparsed', null
    from parsed where text_format = 'gsis' and gsis_passer is null and gsis_rusher is null

    union all
    select play_key, game_key, game_id, team_key, team_id, play_description, text_format,
           espn_success, 'rush', espn_rusher
    from parsed where text_format = 'espn' and espn_rusher is not null
    union all
    select play_key, game_key, game_id, team_key, team_id, play_description, text_format,
           espn_success, 'pass', espn_passer
    from parsed where text_format = 'espn' and espn_passer is not null
    union all
    select play_key, game_key, game_id, team_key, team_id, play_description, text_format,
           espn_success, 'receive', espn_receiver
    from parsed where text_format = 'espn' and espn_receiver is not null
    union all
    select play_key, game_key, game_id, team_key, team_id, play_description, text_format,
           espn_success, 'unparsed', null
    from parsed where text_format = 'espn' and espn_rusher is null and espn_passer is null

),

keyed as (

    select
        {{ dbt_utils.generate_surrogate_key(['play_key', 'role', 'participant_text']) }}
                                                                        as two_point_key,
        p.*,
        -- GSIS "Der.Brown": prefix before the first period, last name after it
        case when text_format = 'gsis'
             then split_part(participant_text, '.', 1) end              as name_prefix,
        case when text_format = 'gsis'
             then {{ nfl_normalize_player_name("regexp_replace(participant_text, '^[^.]*\\\\.', '')") }}
             end                                                        as last_name_normalized,
        {{ nfl_normalize_player_name('participant_text') }}             as full_name_normalized
    from participants p

),

players as (

    select
        player_id,
        player_key,
        current_team_id,
        upper(first_name)                                               as first_name_upper,
        {{ nfl_normalize_player_name('last_name') }}                    as last_name_normalized,
        {{ nfl_normalize_player_name('full_name') }}                    as full_name_normalized
    from {{ ref('stg_nfl__players') }}

),

-- the players who actually appeared in that game for that team, with what
-- they did: the role in the text (passer, receiver, rusher) breaks a name tie
-- ("C.Williams" on the Bears is the one with pass attempts that day).
roster as (

    select
        s.game_id,
        s.team_id,
        s.player_id,
        s.player_key,
        pl.first_name_upper,
        pl.last_name_normalized,
        pl.full_name_normalized,
        (s.passing_attempts  is not null)                               as has_passing,
        (s.rushing_attempts  is not null)                               as has_rushing,
        (s.receiving_targets is not null)                               as has_receiving
    from {{ ref('stg_nfl__player_stats') }} s
    inner join players pl
        on s.player_id = pl.player_id

),

-- a play with no possessing team (a penalty-restarted try) matches across
-- the whole game; a name is still nearly always unique among ~100 players.
candidates as (

    select
        k.two_point_key,
        r.player_key,
        r.player_id,
        count(*) over (partition by k.two_point_key)                    as candidate_count,
        iff(   (k.role = 'pass'    and r.has_passing)
            or (k.role = 'receive' and r.has_receiving)
            or (k.role = 'rush'    and r.has_rushing), 1, 0)            as role_match,
        sum(iff(   (k.role = 'pass'    and r.has_passing)
                or (k.role = 'receive' and r.has_receiving)
                or (k.role = 'rush'    and r.has_rushing), 1, 0))
            over (partition by k.two_point_key)                         as role_match_count
    from keyed k
    inner join roster r
        on k.game_id = r.game_id
       and (k.team_id is null or k.team_id = r.team_id)
       and (
            (k.text_format = 'gsis'
             and r.last_name_normalized = k.last_name_normalized
             and r.first_name_upper like upper(k.name_prefix) || '%')
         or (k.text_format = 'espn'
             and r.full_name_normalized = k.full_name_normalized)
       )
    qualify row_number() over (
        partition by k.two_point_key order by role_match desc, r.player_id
    ) = 1

),

-- fallback for a participant with no box-score line that game (a two-point
-- catch is not a reception; an eligible lineman has no stats at all): the
-- team's current roster. Such a player also has no offense-fact row, so the
-- points cannot land anywhere yet, but the name is keyed rather than lost.
team_roster_candidates as (

    select
        k.two_point_key,
        pl.player_key,
        pl.player_id,
        count(*) over (partition by k.two_point_key)                    as candidate_count
    from keyed k
    inner join players pl
        on k.team_id = pl.current_team_id
       and (
            (k.text_format = 'gsis'
             and pl.last_name_normalized = k.last_name_normalized
             and pl.first_name_upper like upper(k.name_prefix) || '%')
         or (k.text_format = 'espn'
             and pl.full_name_normalized = k.full_name_normalized)
       )
    qualify row_number() over (partition by k.two_point_key order by pl.player_id) = 1

),

aliases as (

    select
        {{ nfl_normalize_player_name('a.alias') }}                      as alias_normalized,
        pl.player_id,
        pl.player_key
    from {{ ref('seed_nfl_player_aliases') }} a
    inner join players pl
        on a.player_id = pl.player_id

),

resolved as (

    select
        k.*,
        case
            when k.role = 'unparsed'                                    then 'unresolved'
            when c.candidate_count = 1                                  then 'exact'
            when c.candidate_count > 1 and c.role_match_count = 1
                 and c.role_match = 1                                   then 'exact_role'
            when al.player_id is not null                               then 'alias'
            when c.candidate_count is null and tr.candidate_count = 1   then 'team_roster'
            when c.candidate_count > 1                                  then 'ambiguous'
            else 'unresolved'
        end                                                             as resolution_method,
        case
            when c.candidate_count = 1                                  then c.player_key
            when c.candidate_count > 1 and c.role_match_count = 1
                 and c.role_match = 1                                   then c.player_key
            when al.player_id is not null                               then al.player_key
            when c.candidate_count is null and tr.candidate_count = 1   then tr.player_key
        end                                                             as player_key,
        case
            when c.candidate_count = 1                                  then c.player_id
            when c.candidate_count > 1 and c.role_match_count = 1
                 and c.role_match = 1                                   then c.player_id
            when al.player_id is not null                               then al.player_id
            when c.candidate_count is null and tr.candidate_count = 1   then tr.player_id
        end                                                             as player_id
    from keyed k
    left join candidates c              on k.two_point_key = c.two_point_key
    left join team_roster_candidates tr on k.two_point_key = tr.two_point_key
    left join aliases al                on k.full_name_normalized = al.alias_normalized

)

select
    -- keys
    r.two_point_key,
    r.play_key,
    r.game_key,
    r.game_id,
    r.team_key,
    r.team_id,
    r.player_key,
    r.player_id,
    -- the same expression stg_nfl__player_stats uses, so this joins the phase
    -- facts 1:1; NULL when the name did not resolve
    case when r.player_id is not null
         then {{ dbt_utils.generate_surrogate_key(['r.game_id', 'r.player_id']) }}
    end                                                                 as player_game_key,
    g.date_key,

    -- context
    g.season,
    g.week,
    g.season_type,

    -- what
    r.role,
    r.is_success,
    r.text_format,
    r.participant_text,
    r.resolution_method,
    r.play_description

from resolved r
inner join games g
    on r.game_key = g.game_key
