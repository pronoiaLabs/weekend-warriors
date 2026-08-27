// Real sample data pulled from the warehouse: nflverse team branding and
// player headshots. Shared by every wireframe page. Access as WW.teams[abbr]
// and WW.players (array). All URLs are live public CDN assets.
const WW = {
  teams: {
  "ARI": {
    "abbr": "ARI",
    "name": "Arizona Cardinals",
    "nick": "Cardinals",
    "conf": "NFC",
    "division": "NFC West",
    "color": "#97233F",
    "color2": "#000000",
    "logo": "https://a.espncdn.com/i/teamlogos/nfl/500/ari.png",
    "logo_sq": "https://github.com/nflverse/nflverse-pbp/raw/master/squared_logos/ARI.png",
    "wordmark": "https://github.com/nflverse/nflverse-pbp/raw/master/wordmarks/ARI.png"
  },
  "ATL": {
    "abbr": "ATL",
    "name": "Atlanta Falcons",
    "nick": "Falcons",
    "conf": "NFC",
    "division": "NFC South",
    "color": "#A71930",
    "color2": "#000000",
    "logo": "https://a.espncdn.com/i/teamlogos/nfl/500/atl.png",
    "logo_sq": "https://github.com/nflverse/nflverse-pbp/raw/master/squared_logos/ATL.png",
    "wordmark": "https://github.com/nflverse/nflverse-pbp/raw/master/wordmarks/ATL.png"
  },
  "BAL": {
    "abbr": "BAL",
    "name": "Baltimore Ravens",
    "nick": "Ravens",
    "conf": "AFC",
    "division": "AFC North",
    "color": "#241773",
    "color2": "#9E7C0C",
    "logo": "https://a.espncdn.com/i/teamlogos/nfl/500/bal.png",
    "logo_sq": "https://github.com/nflverse/nflverse-pbp/raw/master/squared_logos/BAL.png",
    "wordmark": "https://github.com/nflverse/nflverse-pbp/raw/master/wordmarks/BAL.png"
  },
  "BUF": {
    "abbr": "BUF",
    "name": "Buffalo Bills",
    "nick": "Bills",
    "conf": "AFC",
    "division": "AFC East",
    "color": "#00338D",
    "color2": "#C60C30",
    "logo": "https://a.espncdn.com/i/teamlogos/nfl/500/buf.png",
    "logo_sq": "https://github.com/nflverse/nflverse-pbp/raw/master/squared_logos/BUF.png",
    "wordmark": "https://github.com/nflverse/nflverse-pbp/raw/master/wordmarks/BUF.png"
  },
  "CAR": {
    "abbr": "CAR",
    "name": "Carolina Panthers",
    "nick": "Panthers",
    "conf": "NFC",
    "division": "NFC South",
    "color": "#0085CA",
    "color2": "#000000",
    "logo": "https://a.espncdn.com/i/teamlogos/nfl/500-dark/car.png",
    "logo_sq": "https://github.com/nflverse/nflverse-pbp/raw/master/squared_logos/CAR.png",
    "wordmark": "https://github.com/nflverse/nflverse-pbp/raw/master/wordmarks/CAR.png"
  },
  "CHI": {
    "abbr": "CHI",
    "name": "Chicago Bears",
    "nick": "Bears",
    "conf": "NFC",
    "division": "NFC North",
    "color": "#0B162A",
    "color2": "#E64100",
    "logo": "https://a.espncdn.com/i/teamlogos/nfl/500/chi.png",
    "logo_sq": "https://github.com/nflverse/nflverse-pbp/raw/master/squared_logos/CHI.png",
    "wordmark": "https://github.com/nflverse/nflverse-pbp/raw/master/wordmarks/CHI.png"
  },
  "CIN": {
    "abbr": "CIN",
    "name": "Cincinnati Bengals",
    "nick": "Bengals",
    "conf": "AFC",
    "division": "AFC North",
    "color": "#FB4F14",
    "color2": "#000000",
    "logo": "https://a.espncdn.com/i/teamlogos/nfl/500/cin.png",
    "logo_sq": "https://github.com/nflverse/nflverse-pbp/raw/master/squared_logos/CIN.png",
    "wordmark": "https://github.com/nflverse/nflverse-pbp/raw/master/wordmarks/CIN.png"
  },
  "CLE": {
    "abbr": "CLE",
    "name": "Cleveland Browns",
    "nick": "Browns",
    "conf": "AFC",
    "division": "AFC North",
    "color": "#FF3C00",
    "color2": "#311D00",
    "logo": "https://a.espncdn.com/i/teamlogos/nfl/500/cle.png",
    "logo_sq": "https://github.com/nflverse/nflverse-pbp/raw/master/squared_logos/CLE.png",
    "wordmark": "https://github.com/nflverse/nflverse-pbp/raw/master/wordmarks/CLE.png"
  },
  "DAL": {
    "abbr": "DAL",
    "name": "Dallas Cowboys",
    "nick": "Cowboys",
    "conf": "NFC",
    "division": "NFC East",
    "color": "#002244",
    "color2": "#B0B7BC",
    "logo": "https://a.espncdn.com/i/teamlogos/nfl/500/dal.png",
    "logo_sq": "https://github.com/nflverse/nflverse-pbp/raw/master/squared_logos/DAL.png",
    "wordmark": "https://github.com/nflverse/nflverse-pbp/raw/master/wordmarks/DAL.png"
  },
  "DEN": {
    "abbr": "DEN",
    "name": "Denver Broncos",
    "nick": "Broncos",
    "conf": "AFC",
    "division": "AFC West",
    "color": "#002244",
    "color2": "#FB4F14",
    "logo": "https://a.espncdn.com/i/teamlogos/nfl/500/den.png",
    "logo_sq": "https://github.com/nflverse/nflverse-pbp/raw/master/squared_logos/DEN.png",
    "wordmark": "https://github.com/nflverse/nflverse-pbp/raw/master/wordmarks/DEN.png"
  },
  "DET": {
    "abbr": "DET",
    "name": "Detroit Lions",
    "nick": "Lions",
    "conf": "NFC",
    "division": "NFC North",
    "color": "#0076B6",
    "color2": "#B0B7BC",
    "logo": "https://a.espncdn.com/i/teamlogos/nfl/500/det.png",
    "logo_sq": "https://github.com/nflverse/nflverse-pbp/raw/master/squared_logos/DET.png",
    "wordmark": "https://github.com/nflverse/nflverse-pbp/raw/master/wordmarks/DET.png"
  },
  "GB": {
    "abbr": "GB",
    "name": "Green Bay Packers",
    "nick": "Packers",
    "conf": "NFC",
    "division": "NFC North",
    "color": "#203731",
    "color2": "#FFB612",
    "logo": "https://a.espncdn.com/i/teamlogos/nfl/500/gb.png",
    "logo_sq": "https://github.com/nflverse/nflverse-pbp/raw/master/squared_logos/GB.png",
    "wordmark": "https://github.com/nflverse/nflverse-pbp/raw/master/wordmarks/GB.png"
  },
  "HOU": {
    "abbr": "HOU",
    "name": "Houston Texans",
    "nick": "Texans",
    "conf": "AFC",
    "division": "AFC South",
    "color": "#03202F",
    "color2": "#A71930",
    "logo": "https://a.espncdn.com/i/teamlogos/nfl/500/hou.png",
    "logo_sq": "https://github.com/nflverse/nflverse-pbp/raw/master/squared_logos/HOU.png",
    "wordmark": "https://github.com/nflverse/nflverse-pbp/raw/master/wordmarks/HOU.png"
  },
  "IND": {
    "abbr": "IND",
    "name": "Indianapolis Colts",
    "nick": "Colts",
    "conf": "AFC",
    "division": "AFC South",
    "color": "#002C5F",
    "color2": "#a5acaf",
    "logo": "https://a.espncdn.com/i/teamlogos/nfl/500/ind.png",
    "logo_sq": "https://github.com/nflverse/nflverse-pbp/raw/master/squared_logos/IND.png",
    "wordmark": "https://github.com/nflverse/nflverse-pbp/raw/master/wordmarks/IND.png"
  },
  "JAX": {
    "abbr": "JAX",
    "name": "Jacksonville Jaguars",
    "nick": "Jaguars",
    "conf": "AFC",
    "division": "AFC South",
    "color": "#006778",
    "color2": "#000000",
    "logo": "https://a.espncdn.com/i/teamlogos/nfl/500/jax.png",
    "logo_sq": "https://github.com/nflverse/nflverse-pbp/raw/master/squared_logos/JAX.png",
    "wordmark": "https://github.com/nflverse/nflverse-pbp/raw/master/wordmarks/JAX.png"
  },
  "KC": {
    "abbr": "KC",
    "name": "Kansas City Chiefs",
    "nick": "Chiefs",
    "conf": "AFC",
    "division": "AFC West",
    "color": "#E31837",
    "color2": "#FFB612",
    "logo": "https://a.espncdn.com/i/teamlogos/nfl/500/kc.png",
    "logo_sq": "https://github.com/nflverse/nflverse-pbp/raw/master/squared_logos/KC.png",
    "wordmark": "https://github.com/nflverse/nflverse-pbp/raw/master/wordmarks/KC.png"
  },
  "LAC": {
    "abbr": "LAC",
    "name": "Los Angeles Chargers",
    "nick": "Chargers",
    "conf": "AFC",
    "division": "AFC West",
    "color": "#007BC7",
    "color2": "#ffc20e",
    "logo": "https://a.espncdn.com/i/teamlogos/nfl/500/lac.png",
    "logo_sq": "https://github.com/nflverse/nflverse-pbp/raw/master/squared_logos/LAC.png",
    "wordmark": "https://github.com/nflverse/nflverse-pbp/raw/master/wordmarks/LAC.png"
  },
  "LAR": {
    "abbr": "LAR",
    "name": "Los Angeles Rams",
    "nick": "Rams",
    "conf": "NFC",
    "division": "NFC West",
    "color": "#003594",
    "color2": "#FFD100",
    "logo": "https://a.espncdn.com/i/teamlogos/nfl/500/lar.png",
    "logo_sq": "https://github.com/nflverse/nflverse-pbp/raw/master/squared_logos/LAR.png",
    "wordmark": "https://github.com/nflverse/nflverse-pbp/raw/master/wordmarks/LAR.png"
  },
  "LV": {
    "abbr": "LV",
    "name": "Las Vegas Raiders",
    "nick": "Raiders",
    "conf": "AFC",
    "division": "AFC West",
    "color": "#000000",
    "color2": "#A5ACAF",
    "logo": "https://a.espncdn.com/i/teamlogos/nfl/500/lv.png",
    "logo_sq": "https://github.com/nflverse/nflverse-pbp/raw/master/squared_logos/LV.png",
    "wordmark": "https://github.com/nflverse/nflverse-pbp/raw/master/wordmarks/LV.png"
  },
  "MIA": {
    "abbr": "MIA",
    "name": "Miami Dolphins",
    "nick": "Dolphins",
    "conf": "AFC",
    "division": "AFC East",
    "color": "#008E97",
    "color2": "#F58220",
    "logo": "https://a.espncdn.com/i/teamlogos/nfl/500/mia.png",
    "logo_sq": "https://github.com/nflverse/nflverse-pbp/raw/master/squared_logos/MIA.png",
    "wordmark": "https://github.com/nflverse/nflverse-pbp/raw/master/wordmarks/MIA.png"
  },
  "MIN": {
    "abbr": "MIN",
    "name": "Minnesota Vikings",
    "nick": "Vikings",
    "conf": "NFC",
    "division": "NFC North",
    "color": "#4F2683",
    "color2": "#FFC62F",
    "logo": "https://a.espncdn.com/i/teamlogos/nfl/500/min.png",
    "logo_sq": "https://github.com/nflverse/nflverse-pbp/raw/master/squared_logos/MIN.png",
    "wordmark": "https://github.com/nflverse/nflverse-pbp/raw/master/wordmarks/MIN.png"
  },
  "NE": {
    "abbr": "NE",
    "name": "New England Patriots",
    "nick": "Patriots",
    "conf": "AFC",
    "division": "AFC East",
    "color": "#002244",
    "color2": "#C60C30",
    "logo": "https://a.espncdn.com/i/teamlogos/nfl/500/ne.png",
    "logo_sq": "https://github.com/nflverse/nflverse-pbp/raw/master/squared_logos/NE.png",
    "wordmark": "https://github.com/nflverse/nflverse-pbp/raw/master/wordmarks/NE.png"
  },
  "NO": {
    "abbr": "NO",
    "name": "New Orleans Saints",
    "nick": "Saints",
    "conf": "NFC",
    "division": "NFC South",
    "color": "#D3BC8D",
    "color2": "#000000",
    "logo": "https://a.espncdn.com/i/teamlogos/nfl/500/no.png",
    "logo_sq": "https://github.com/nflverse/nflverse-pbp/raw/master/squared_logos/NO.png",
    "wordmark": "https://github.com/nflverse/nflverse-pbp/raw/master/wordmarks/NO.png"
  },
  "NYG": {
    "abbr": "NYG",
    "name": "New York Giants",
    "nick": "Giants",
    "conf": "NFC",
    "division": "NFC East",
    "color": "#0B2265",
    "color2": "#A71930",
    "logo": "https://a.espncdn.com/i/teamlogos/nfl/500/nyg.png",
    "logo_sq": "https://github.com/nflverse/nflverse-pbp/raw/master/squared_logos/NYG.png",
    "wordmark": "https://github.com/nflverse/nflverse-pbp/raw/master/wordmarks/NYG.png"
  },
  "NYJ": {
    "abbr": "NYJ",
    "name": "New York Jets",
    "nick": "Jets",
    "conf": "AFC",
    "division": "AFC East",
    "color": "#003F2D",
    "color2": "#000000",
    "logo": "https://a.espncdn.com/i/teamlogos/nfl/500/nyj.png",
    "logo_sq": "https://github.com/nflverse/nflverse-pbp/raw/master/squared_logos/NYJ.png",
    "wordmark": "https://github.com/nflverse/nflverse-pbp/raw/master/wordmarks/NYJ.png"
  },
  "PHI": {
    "abbr": "PHI",
    "name": "Philadelphia Eagles",
    "nick": "Eagles",
    "conf": "NFC",
    "division": "NFC East",
    "color": "#004C54",
    "color2": "#A5ACAF",
    "logo": "https://a.espncdn.com/i/teamlogos/nfl/500/phi.png",
    "logo_sq": "https://github.com/nflverse/nflverse-pbp/raw/master/squared_logos/PHI.png",
    "wordmark": "https://github.com/nflverse/nflverse-pbp/raw/master/wordmarks/PHI.png"
  },
  "PIT": {
    "abbr": "PIT",
    "name": "Pittsburgh Steelers",
    "nick": "Steelers",
    "conf": "AFC",
    "division": "AFC North",
    "color": "#000000",
    "color2": "#FFB612",
    "logo": "https://a.espncdn.com/i/teamlogos/nfl/500/pit.png",
    "logo_sq": "https://github.com/nflverse/nflverse-pbp/raw/master/squared_logos/PIT.png",
    "wordmark": "https://github.com/nflverse/nflverse-pbp/raw/master/wordmarks/PIT.png"
  },
  "SEA": {
    "abbr": "SEA",
    "name": "Seattle Seahawks",
    "nick": "Seahawks",
    "conf": "NFC",
    "division": "NFC West",
    "color": "#002244",
    "color2": "#69be28",
    "logo": "https://a.espncdn.com/i/teamlogos/nfl/500/sea.png",
    "logo_sq": "https://github.com/nflverse/nflverse-pbp/raw/master/squared_logos/SEA.png",
    "wordmark": "https://github.com/nflverse/nflverse-pbp/raw/master/wordmarks/SEA.png"
  },
  "SF": {
    "abbr": "SF",
    "name": "San Francisco 49ers",
    "nick": "49ers",
    "conf": "NFC",
    "division": "NFC West",
    "color": "#AA0000",
    "color2": "#B3995D",
    "logo": "https://a.espncdn.com/i/teamlogos/nfl/500/sf.png",
    "logo_sq": "https://github.com/nflverse/nflverse-pbp/raw/master/squared_logos/SF.png",
    "wordmark": "https://github.com/nflverse/nflverse-pbp/raw/master/wordmarks/SF.png"
  },
  "TB": {
    "abbr": "TB",
    "name": "Tampa Bay Buccaneers",
    "nick": "Buccaneers",
    "conf": "NFC",
    "division": "NFC South",
    "color": "#A71930",
    "color2": "#322F2B",
    "logo": "https://a.espncdn.com/i/teamlogos/nfl/500/tb.png",
    "logo_sq": "https://github.com/nflverse/nflverse-pbp/raw/master/squared_logos/TB.png",
    "wordmark": "https://github.com/nflverse/nflverse-pbp/raw/master/wordmarks/TB.png"
  },
  "TEN": {
    "abbr": "TEN",
    "name": "Tennessee Titans",
    "nick": "Titans",
    "conf": "AFC",
    "division": "AFC South",
    "color": "#4495D2",
    "color2": "#D50A0A",
    "logo": "https://a.espncdn.com/i/teamlogos/nfl/500/ten.png",
    "logo_sq": "https://github.com/nflverse/nflverse-pbp/raw/master/squared_logos/TEN.png",
    "wordmark": "https://github.com/nflverse/nflverse-pbp/raw/master/wordmarks/TEN.png"
  },
  "WAS": {
    "abbr": "WAS",
    "name": "Washington Commanders",
    "nick": "Commanders",
    "conf": "NFC",
    "division": "NFC East",
    "color": "#5A1414",
    "color2": "#FFB612",
    "logo": "https://a.espncdn.com/i/teamlogos/nfl/500/wsh.png",
    "logo_sq": "https://github.com/nflverse/nflverse-pbp/raw/master/squared_logos/WAS.png",
    "wordmark": "https://github.com/nflverse/nflverse-pbp/raw/master/wordmarks/WAS.png"
  }
},
  players: [
  {
    "name": "Sauce Gardner",
    "pos": "CB",
    "team": "IND",
    "jersey": "1",
    "headshot": "https://static.www.nfl.com/image/upload/f_auto,q_auto/league/h89jaonhmvvdoitmldkq",
    "draft_year": 2022,
    "college": "Cincinnati",
    "height": 75,
    "weight": 190,
    "exp": 5
  },
  {
    "name": "Myles Garrett",
    "pos": "DE",
    "team": "LA",
    "jersey": "95",
    "headshot": "https://static.www.nfl.com/image/upload/f_auto,q_auto/league/y2d1lvpgfarfv76hjcqm",
    "draft_year": 2017,
    "college": "Texas A&M",
    "height": 76,
    "weight": 272,
    "exp": 10
  },
  {
    "name": "Minkah Fitzpatrick",
    "pos": "FS",
    "team": "NYJ",
    "jersey": "29",
    "headshot": "https://static.www.nfl.com/image/upload/f_auto,q_auto/league/z733r4dwebhrqeeihy0e",
    "draft_year": 2018,
    "college": "Alabama",
    "height": 73,
    "weight": 207,
    "exp": 9
  },
  {
    "name": "Brandon Aubrey",
    "pos": "K",
    "team": "DAL",
    "jersey": "17",
    "headshot": "https://static.www.nfl.com/image/upload/f_auto,q_auto/league/bgwg06zmyohjxvzznbf6",
    "draft_year": null,
    "college": "Notre Dame",
    "height": 75,
    "weight": 218,
    "exp": 4
  },
  {
    "name": "Harrison Butker",
    "pos": "K",
    "team": "KC",
    "jersey": "7",
    "headshot": "https://static.www.nfl.com/image/upload/f_auto,q_auto/league/yphf8avl8ji0ncdohabz",
    "draft_year": 2017,
    "college": "Georgia Tech",
    "height": 76,
    "weight": 205,
    "exp": 10
  },
  {
    "name": "Justin Tucker",
    "pos": "K",
    "team": "BAL",
    "jersey": "9",
    "headshot": "https://static.www.nfl.com/image/upload/f_auto,q_auto/league/thawkkxcbyuddwuidgb0",
    "draft_year": null,
    "college": "Texas",
    "height": 73,
    "weight": 191,
    "exp": 13
  },
  {
    "name": "Micah Parsons",
    "pos": "LB",
    "team": "GB",
    "jersey": "1",
    "headshot": "https://static.www.nfl.com/image/upload/f_auto,q_auto/league/euivq1hqslszdxjo9xyr",
    "draft_year": 2021,
    "college": "Penn State",
    "height": 75,
    "weight": 250,
    "exp": 6
  },
  {
    "name": "Fred Warner",
    "pos": "MLB",
    "team": "SF",
    "jersey": "54",
    "headshot": "https://static.www.nfl.com/image/upload/f_auto,q_auto/league/zmse3qgt0x2mqiuiuiu7",
    "draft_year": 2018,
    "college": "BYU",
    "height": 75,
    "weight": 230,
    "exp": 9
  },
  {
    "name": "T.J. Watt",
    "pos": "OLB",
    "team": "PIT",
    "jersey": "90",
    "headshot": "https://static.www.nfl.com/image/upload/f_auto,q_auto/league/aywegy4gpj1d32vrl67u",
    "draft_year": 2017,
    "college": "Wisconsin",
    "height": 76,
    "weight": 252,
    "exp": 10
  },
  {
    "name": "Brock Purdy",
    "pos": "QB",
    "team": "SF",
    "jersey": "13",
    "headshot": "https://static.www.nfl.com/image/upload/f_auto,q_auto/league/xs2fyj1sqdgwvt9ihbri",
    "draft_year": 2022,
    "college": "Iowa State",
    "height": 73,
    "weight": 220,
    "exp": 5
  },
  {
    "name": "C.J. Stroud",
    "pos": "QB",
    "team": "HOU",
    "jersey": "7",
    "headshot": "https://static.www.nfl.com/image/upload/f_auto,q_auto/league/tt4zrtxlhifaljhj0rn7",
    "draft_year": 2023,
    "college": "Ohio State",
    "height": 75,
    "weight": 218,
    "exp": 4
  },
  {
    "name": "Jalen Hurts",
    "pos": "QB",
    "team": "PHI",
    "jersey": "1",
    "headshot": "https://static.www.nfl.com/image/upload/f_auto,q_auto/league/xow5yvxjeqa6witmofmp",
    "draft_year": 2020,
    "college": "Oklahoma; Alabama",
    "height": 73,
    "weight": 223,
    "exp": 7
  },
  {
    "name": "Jayden Daniels",
    "pos": "QB",
    "team": "WAS",
    "jersey": "5",
    "headshot": "https://static.www.nfl.com/image/upload/f_auto,q_auto/league/gfz8k5onuqjrche9ogqc",
    "draft_year": 2024,
    "college": "LSU; Arizona State",
    "height": 76,
    "weight": 210,
    "exp": 3
  },
  {
    "name": "Joe Burrow",
    "pos": "QB",
    "team": "CIN",
    "jersey": "9",
    "headshot": "https://static.www.nfl.com/image/upload/f_auto,q_auto/league/gnnvcgui1cijybukk2w7",
    "draft_year": 2020,
    "college": "LSU; Ohio State",
    "height": 76,
    "weight": 215,
    "exp": 7
  },
  {
    "name": "Josh Allen",
    "pos": "QB",
    "team": "BUF",
    "jersey": "17",
    "headshot": "https://static.www.nfl.com/image/upload/f_auto,q_auto/league/mjwbioajzldkq1vzoz2d",
    "draft_year": 2018,
    "college": "Wyoming; Reedley",
    "height": 77,
    "weight": 237,
    "exp": 9
  },
  {
    "name": "Kirk Cousins",
    "pos": "QB",
    "team": "LV",
    "jersey": "8",
    "headshot": "https://static.www.nfl.com/image/upload/f_auto,q_auto/league/za7cynvpwlsro1tsaijk",
    "draft_year": 2012,
    "college": "Michigan State",
    "height": 75,
    "weight": 214,
    "exp": 15
  },
  {
    "name": "Lamar Jackson",
    "pos": "QB",
    "team": "BAL",
    "jersey": "8",
    "headshot": "https://static.www.nfl.com/image/upload/f_auto,q_auto/league/eno6s5qzl9grbfbfwhoa",
    "draft_year": 2018,
    "college": "Louisville",
    "height": 74,
    "weight": 205,
    "exp": 9
  },
  {
    "name": "Patrick Mahomes",
    "pos": "QB",
    "team": "KC",
    "jersey": "15",
    "headshot": "https://static.www.nfl.com/image/upload/f_auto,q_auto/league/wdckwtob1lybvkmxnf7p",
    "draft_year": 2017,
    "college": "Texas Tech",
    "height": 74,
    "weight": 225,
    "exp": 10
  },
  {
    "name": "Bijan Robinson",
    "pos": "RB",
    "team": "ATL",
    "jersey": "7",
    "headshot": "https://static.www.nfl.com/image/upload/f_auto,q_auto/league/esii5yb8yn9edboi4mlq",
    "draft_year": 2023,
    "college": "Texas",
    "height": 71,
    "weight": 215,
    "exp": 4
  },
  {
    "name": "Christian McCaffrey",
    "pos": "RB",
    "team": "SF",
    "jersey": "23",
    "headshot": "https://static.www.nfl.com/image/upload/f_auto,q_auto/league/st82s2ytyzanatcmkqck",
    "draft_year": 2017,
    "college": "Stanford",
    "height": 71,
    "weight": 210,
    "exp": 10
  },
  {
    "name": "De'Von Achane",
    "pos": "RB",
    "team": "MIA",
    "jersey": "28",
    "headshot": "https://static.www.nfl.com/image/upload/f_auto,q_auto/league/xk1xwio0bryfxo1ylweu",
    "draft_year": 2023,
    "college": "Texas A&M",
    "height": 69,
    "weight": 191,
    "exp": 4
  },
  {
    "name": "Derrick Henry",
    "pos": "RB",
    "team": "BAL",
    "jersey": "22",
    "headshot": "https://static.www.nfl.com/image/upload/f_auto,q_auto/league/tm79x0iknqg6hms3ypyt",
    "draft_year": 2016,
    "college": "Alabama",
    "height": 75,
    "weight": 252,
    "exp": 11
  },
  {
    "name": "Jahmyr Gibbs",
    "pos": "RB",
    "team": "DET",
    "jersey": "0",
    "headshot": "https://static.www.nfl.com/image/upload/f_auto,q_auto/league/cursejnmmp1i9hnxihkj",
    "draft_year": 2023,
    "college": "Alabama; Georgia Tech",
    "height": 69,
    "weight": 202,
    "exp": 4
  },
  {
    "name": "Josh Jacobs",
    "pos": "RB",
    "team": "GB",
    "jersey": "8",
    "headshot": "https://static.www.nfl.com/image/upload/f_auto,q_auto/league/uceokxeo0uqrqms3e3vl",
    "draft_year": 2019,
    "college": "Alabama",
    "height": 70,
    "weight": 223,
    "exp": 8
  },
  {
    "name": "Kyren Williams",
    "pos": "RB",
    "team": "LA",
    "jersey": "23",
    "headshot": "https://static.www.nfl.com/image/upload/f_auto,q_auto/league/xti3pek6rmojqchakxpy",
    "draft_year": 2022,
    "college": "Notre Dame",
    "height": 69,
    "weight": 207,
    "exp": 5
  },
  {
    "name": "Saquon Barkley",
    "pos": "RB",
    "team": "PHI",
    "jersey": "26",
    "headshot": "https://static.www.nfl.com/image/upload/f_auto,q_auto/league/qcayrzjpura2zydszonh",
    "draft_year": 2018,
    "college": "Penn State",
    "height": 72,
    "weight": 232,
    "exp": 9
  },
  {
    "name": "George Kittle",
    "pos": "TE",
    "team": "SF",
    "jersey": "85",
    "headshot": "https://static.www.nfl.com/image/upload/f_auto,q_auto/league/vkicdglglkyukgyxtmpx",
    "draft_year": 2017,
    "college": "Iowa",
    "height": 76,
    "weight": 250,
    "exp": 10
  },
  {
    "name": "Sam LaPorta",
    "pos": "TE",
    "team": "DET",
    "jersey": "87",
    "headshot": "https://static.www.nfl.com/image/upload/f_auto,q_auto/league/wxlk7ysg2nfq6h6ntdcu",
    "draft_year": 2023,
    "college": "Iowa",
    "height": 75,
    "weight": 245,
    "exp": 4
  },
  {
    "name": "Travis Kelce",
    "pos": "TE",
    "team": "KC",
    "jersey": "87",
    "headshot": "https://static.www.nfl.com/image/upload/f_auto,q_auto/league/dpxovcfku6ud2aohgf6a",
    "draft_year": 2013,
    "college": "Cincinnati",
    "height": 77,
    "weight": 250,
    "exp": 14
  },
  {
    "name": "Trey McBride",
    "pos": "TE",
    "team": "ARI",
    "jersey": "85",
    "headshot": "https://static.www.nfl.com/image/upload/f_auto,q_auto/league/psasp10nn5pcvkli9kil",
    "draft_year": 2022,
    "college": "Colorado State",
    "height": 76,
    "weight": 246,
    "exp": 5
  },
  {
    "name": "A.J. Brown",
    "pos": "WR",
    "team": "NE",
    "jersey": "1",
    "headshot": "https://static.www.nfl.com/image/upload/f_auto,q_auto/league/qfhvjyssf0lwsh0kienp",
    "draft_year": 2019,
    "college": "Mississippi",
    "height": 73,
    "weight": 226,
    "exp": 8
  },
  {
    "name": "Amon-Ra St. Brown",
    "pos": "WR",
    "team": "DET",
    "jersey": "14",
    "headshot": "https://static.www.nfl.com/image/upload/f_auto,q_auto/league/fd8nwhm6pvxfyzphzl6i",
    "draft_year": 2021,
    "college": "USC",
    "height": 72,
    "weight": 202,
    "exp": 6
  },
  {
    "name": "CeeDee Lamb",
    "pos": "WR",
    "team": "DAL",
    "jersey": "88",
    "headshot": "https://static.www.nfl.com/image/upload/f_auto,q_auto/league/mbblzwtynxr15ovzkevi",
    "draft_year": 2020,
    "college": "Oklahoma",
    "height": 74,
    "weight": 198,
    "exp": 7
  },
  {
    "name": "Drake London",
    "pos": "WR",
    "team": "ATL",
    "jersey": "5",
    "headshot": "https://static.www.nfl.com/image/upload/f_auto,q_auto/league/mcllowcfrmmdeo4zy3g1",
    "draft_year": 2022,
    "college": "USC",
    "height": 76,
    "weight": 215,
    "exp": 5
  },
  {
    "name": "Garrett Wilson",
    "pos": "WR",
    "team": "NYJ",
    "jersey": "5",
    "headshot": "https://static.www.nfl.com/image/upload/f_auto,q_auto/league/upxwxmhdd8xluztgqwhe",
    "draft_year": 2022,
    "college": "Ohio State",
    "height": 72,
    "weight": 183,
    "exp": 5
  },
  {
    "name": "Ja'Marr Chase",
    "pos": "WR",
    "team": "CIN",
    "jersey": "1",
    "headshot": "https://static.www.nfl.com/image/upload/f_auto,q_auto/league/qya3dtjb5kgofcuj2tuw",
    "draft_year": 2021,
    "college": "LSU",
    "height": 72,
    "weight": 205,
    "exp": 6
  },
  {
    "name": "Justin Jefferson",
    "pos": "WR",
    "team": "MIN",
    "jersey": "18",
    "headshot": "https://static.www.nfl.com/image/upload/f_auto,q_auto/league/htjevkugzk6ietrjysny",
    "draft_year": 2020,
    "college": "LSU",
    "height": 73,
    "weight": 195,
    "exp": 7
  },
  {
    "name": "Malik Nabers",
    "pos": "WR",
    "team": "NYG",
    "jersey": "1",
    "headshot": "https://static.www.nfl.com/image/upload/f_auto,q_auto/league/w3edoyyuomqlovvp9ixc",
    "draft_year": 2024,
    "college": "LSU",
    "height": 72,
    "weight": 200,
    "exp": 3
  },
  {
    "name": "Nico Collins",
    "pos": "WR",
    "team": "HOU",
    "jersey": "12",
    "headshot": "https://static.www.nfl.com/image/upload/f_auto,q_auto/league/fguybjrn1kwflxm5szwq",
    "draft_year": 2021,
    "college": "Michigan",
    "height": 76,
    "weight": 222,
    "exp": 6
  },
  {
    "name": "Puka Nacua",
    "pos": "WR",
    "team": "LA",
    "jersey": "12",
    "headshot": "https://static.www.nfl.com/image/upload/f_auto,q_auto/league/ipy6qw7hdygdfc8k86ba",
    "draft_year": 2023,
    "college": "BYU; Washington",
    "height": 74,
    "weight": 216,
    "exp": 4
  },
  {
    "name": "Zay Flowers",
    "pos": "WR",
    "team": "BAL",
    "jersey": "4",
    "headshot": "https://static.www.nfl.com/image/upload/f_auto,q_auto/league/xzhto2dejy2pflkfx40c",
    "draft_year": 2023,
    "college": "Boston College",
    "height": 69,
    "weight": 183,
    "exp": 4
  }
]
};

// Theme bootstrap: applies the saved (or system) theme before first paint and
// injects a light/dark toggle into the topbar of every page that loads this file.
(function () {
  var theme;
  try { theme = localStorage.getItem('ww-theme'); } catch (e) { theme = null; }
  if (!theme) theme = (window.matchMedia && matchMedia('(prefers-color-scheme: light)').matches) ? 'light' : 'dark';
  document.documentElement.dataset.theme = theme;
  function place() {
    var bar = document.querySelector('.topbar');
    if (!bar || bar.querySelector('.theme-toggle')) return;
    var btn = document.createElement('button');
    btn.className = 'theme-toggle';
    btn.type = 'button';
    btn.title = 'Toggle light / dark';
    btn.textContent = theme === 'light' ? '☾' : '☀';
    btn.addEventListener('click', function () {
      theme = theme === 'light' ? 'dark' : 'light';
      document.documentElement.dataset.theme = theme;
      btn.textContent = theme === 'light' ? '☾' : '☀';
      try { localStorage.setItem('ww-theme', theme); } catch (e) {}
    });
    bar.appendChild(btn);
  }
  if (document.readyState === 'loading') document.addEventListener('DOMContentLoaded', place); else place();
})();
