{#
    assert_team_epa_fold_reconciles_to_pbp -- the EPA columns folded into the
    team twins still say what the play-by-play says.

    Replaces assert_team_game_epa_mirrors, which guarded the retired
    fact_team_game_epa. The fold is re-derived here independently: scrimmage
    plays from stg_nfl__nflverse_pbp under the SAME filter the twins use
    (play_type in (pass, run), non-NULL EPA, a possessing team), aggregated
    per game and team from the offense side and again from the defense side,
    mapped to (game_id, team_id) through bridge_game_ids. Three ways to fail:

      * a non-preseason team-game row without its EPA block (the fold was
        measured 100% 1:1; a gap means the bridge or the join drifted);
      * an offense row whose off_plays / off_epa / dropbacks / carries
        disagree with the recomputation;
      * a defense row whose def_plays / def_epa disagree with the same plays
        read from the defending side -- which also re-proves the old mirrors
        invariant, since the defense twin takes its block from the opponent's
        offense row.

    Float sums compare to 0.001, the same tolerance the mirrors test used.
#}

with plays as (

    select
        nflverse_game_id,
        posteam,
        defteam,
        epa,
        pass,
        rush
    from {{ ref('stg_nfl__nflverse_pbp') }}
    where play_type in ('pass', 'run')
      and epa is not null
      and posteam is not null

),

bridged as (

    select
        nflverse_game_id,
        game_id,
        home_abbr_nflverse,
        home_team_id,
        away_abbr_nflverse,
        away_team_id
    from {{ ref('bridge_game_ids') }}
    where nflverse_game_id is not null

),

off_expected as (

    select
        g.game_id,
        iff(p.posteam = g.home_abbr_nflverse, g.home_team_id, g.away_team_id)
                                                        as team_id,
        count(*)                                        as exp_plays,
        sum(p.epa)                                      as exp_epa,
        count_if(p.pass = 1)                            as exp_dropbacks,
        count_if(p.rush = 1)                            as exp_carries
    from plays p
    inner join bridged g
        on g.nflverse_game_id = p.nflverse_game_id
    group by 1, 2

),

def_expected as (

    select
        g.game_id,
        iff(p.defteam = g.home_abbr_nflverse, g.home_team_id, g.away_team_id)
                                                        as team_id,
        count(*)                                        as exp_plays,
        sum(p.epa)                                      as exp_epa
    from plays p
    inner join bridged g
        on g.nflverse_game_id = p.nflverse_game_id
    group by 1, 2

),

offense_side as (

    select
        'offense'                                       as side,
        f.team_game_key,
        f.game_id,
        f.team_id,
        f.season_type,
        f.has_nflverse,
        e.exp_plays,
        f.off_plays                                     as fact_plays,
        e.exp_epa,
        f.off_epa                                       as fact_epa
    from {{ ref('fact_team_game_offense') }} f
    left join off_expected e
        on  e.game_id = f.game_id
        and e.team_id = f.team_id
    where (f.season_type != 1 and (not f.has_nflverse or e.game_id is null))
       or (e.game_id is not null
           and (f.off_plays  != e.exp_plays
                or abs(f.off_epa - e.exp_epa) > 0.001
                or f.dropbacks != e.exp_dropbacks
                or f.carries   != e.exp_carries))

),

defense_side as (

    select
        'defense'                                       as side,
        f.team_game_key,
        f.game_id,
        f.team_id,
        f.season_type,
        f.has_nflverse,
        e.exp_plays,
        f.def_plays                                     as fact_plays,
        e.exp_epa,
        f.def_epa                                       as fact_epa
    from {{ ref('fact_team_game_defense') }} f
    left join def_expected e
        on  e.game_id = f.game_id
        and e.team_id = f.team_id
    where (f.season_type != 1 and (not f.has_nflverse or e.game_id is null))
       or (e.game_id is not null
           and (f.def_plays != e.exp_plays
                or abs(f.def_epa - e.exp_epa) > 0.001))

)

select * from offense_side
union all
select * from defense_side
