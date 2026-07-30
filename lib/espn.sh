#!/usr/bin/env bash
# espn.sh -- ESPN public site API client for the daily sports digest.
# Isolates every ESPN network call. Sourced by bin/tick.sh.
#
# The sports digest is opt-in; callers gate on these being set:
#   PRIMARY_RECIPIENTS, SPORTS_LEAGUES   (SPORTS_RECIPIENTS adds extra subscribers)
# Requires on PATH: curl, jq.
#
# No key, no auth: these are the unofficial-but-public JSON endpoints
# behind espn.com (site.api.espn.com). League identifiers are ESPN
# {sport}/{league} paths -- football/nfl, basketball/nba, hockey/nhl,
# baseball/mlb, soccer/usa.1, soccer/fifa.world, golf/pga, mma/ufc,
# racing/f1, racing/nascar-premier, racing/irl, ... A league with no
# scoreboard surface (ESPN 400s) degrades to news-only rather than
# failing the league.

# Fallback logger so this module is sourceable standalone (tests).
if ! declare -F log >/dev/null; then
  log() { printf '[agent] %s\n' "$*" >&2; }
fi

# Override for tests or if ESPN moves the surface. No trailing slash.
ESPN_BASE_URL="${ESPN_BASE_URL:-https://site.api.espn.com/apis/site/v2/sports}"

# espn_scoreboard <sport/league> <yyyymmdd>
# Fetches the league's scoreboard for one calendar day (the digest's
# "yesterday"). Echoes the raw JSON ({ "events": [...] }) on stdout.
# Echoes '{"events":[]}' and rc=1 on any failure -- including the 400
# ESPN returns for leagues with no scoreboard surface -- so callers can
# branch on the event count and fall back to news-only.
espn_scoreboard() {
  local league="$1" yyyymmdd="$2" resp
  if [ -z "$league" ] || [ -z "$yyyymmdd" ]; then
    printf '%s' '{"events":[]}'; return 1
  fi
  resp=$(curl -fsS -G "$ESPN_BASE_URL/$league/scoreboard" \
    --data-urlencode "dates=${yyyymmdd}" 2>/dev/null) || {
      printf '%s' '{"events":[]}'; return 1
    }
  if ! jq -e . >/dev/null 2>&1 <<<"$resp"; then
    log "espn: non-JSON scoreboard response for $league"
    printf '%s' '{"events":[]}'; return 1
  fi
  printf '%s' "$resp"
}

# espn_news <sport/league>
# Fetches the league's current headlines. Echoes the raw JSON
# ({ "articles": [...] }) on stdout. Echoes '{"articles":[]}' and rc=1
# on any failure so callers can branch on the article count.
espn_news() {
  local league="$1" resp
  if [ -z "$league" ]; then
    printf '%s' '{"articles":[]}'; return 1
  fi
  resp=$(curl -fsS "$ESPN_BASE_URL/$league/news" 2>/dev/null) || {
      printf '%s' '{"articles":[]}'; return 1
    }
  if ! jq -e . >/dev/null 2>&1 <<<"$resp"; then
    log "espn: non-JSON news response for $league"
    printf '%s' '{"articles":[]}'; return 1
  fi
  printf '%s' "$resp"
}

# espn_slim_league <league> <scoreboard_json> <news_json>
# Pure jq reduction of one league's raw payloads to what the distill
# prompt needs:
#   { league,
#     events:[{name,date,status,notes,competitors:[{team,score,winner}]}],
#     headlines:[{headline,description,published,link}] }
# Caps keep the prompt bounded with ~12 configured leagues: 10 events
# per league (a full MLB Saturday slate runs to 15 games), 10 competitors
# per event (golf/racing fields run to 150 entrants -- the scoreboard
# order puts the leaders first), and 8 headlines per league.
# Article links come from ESPN verbatim -- the model is never the
# source of a URL.
espn_slim_league() {
  local league="$1" scoreboard="$2" news="$3"
  printf '%s\n%s\n' "$scoreboard" "$news" \
  | jq -n --arg league "$league" '
    (input) as $sb | (input) as $nw |
    {
      league: $league,
      events: [($sb.events // [])[0:10][] | {
        name: .name,
        date: ((.date // "") | split("T")[0]),
        status: (.status.type.description // "unknown"),
        notes: [(.competitions[0].notes // [])[] | .headline // empty],
        competitors: [(.competitions[0].competitors // [])[0:10][] | {
          team: (.team.displayName // .athlete.displayName // null),
          score: (.score // null),
          winner: (.winner // null)
        }]
      }],
      headlines: [($nw.articles // [])[0:8][] | {
        headline: .headline,
        description: (.description // null),
        published: (.published // null),
        link: (.links.web.href // null)
      }]
    }' 2>/dev/null \
  || printf '{"league":"%s","events":[],"headlines":[]}' "$league"
}
