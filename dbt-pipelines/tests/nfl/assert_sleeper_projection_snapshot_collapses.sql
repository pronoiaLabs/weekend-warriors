{#
    assert_sleeper_projection_snapshot_collapses -- consecutive snapshots
    always differ.

    The snapshot fact's contract is that a row means the projection moved:
    two consecutive rows of the same player-week identical on every collapsed
    column would mean the LAG comparison drifted from the column list (the
    trap the odds snapshots guard against with the same shape of test).
#}

with pairs as (

    select
        projection_snapshot_key,
        sleeper_player_id,
        season,
        season_type,
        week,
        snapshot_number,
        {% set cols = [
            'pts_ppr', 'pts_half_ppr', 'pts_std', 'rec_tgt', 'rec', 'rec_yd', 'rec_td',
            'rush_att', 'rush_yd', 'rush_td', 'pass_att', 'pass_yd', 'pass_td', 'pass_int'
        ] %}
        {% for c in cols %}
        {{ c }},
        lag({{ c }}) over (
            partition by sleeper_player_id, season, season_type, week
            order by snapshot_number
        )                                               as prev_{{ c }}{{ ',' if not loop.last }}
        {% endfor %}
    from {{ ref('fact_sleeper_projection_snapshot') }}

)

select *
from pairs
where snapshot_number > 1
{% for c in cols %}
  and {{ c }} is not distinct from prev_{{ c }}
{% endfor %}
