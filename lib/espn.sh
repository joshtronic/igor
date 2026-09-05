#!/usr/bin/env bash
# espn.sh -- ESPN public site API client for the daily sports digest.
# Isolates every ESPN network call. Sourced by bin/tick.sh, after
# lib/request.sh -- every fetch goes through request_get (igor#585) for
# its bounded retry + 429/503 backoff, rather than a bare curl. Caching
# is intentionally left off (ttl=0): this is a port, not a behavior
# change, and the digest wants each day's fetch live. Two things the
# bare curl did not do come along with request_get and are wanted:
# REQUEST_CONNECT_TIMEOUT/REQUEST_MAX_TIME now bound a fetch (an
# unbounded one could wedge a tick, and ~12 leagues means 24 of them per
# digest), and a transport failure is logged instead of swallowed.
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
# "yesterday"; the date must be exactly 8 digits). Echoes the raw JSON
# ({ "events": [...] }) on stdout. Echoes '{"events":[]}' and rc=1 on any
# failure -- including a malformed date and the 400 ESPN returns for
# leagues with no scoreboard surface -- so callers can branch on the
# event count and fall back to news-only.
espn_scoreboard() {
  local league="$1" yyyymmdd="$2" resp
  # The date goes into the query string by interpolation, not by curl's
  # --data-urlencode, so the digits-only shape is enforced here rather
  # than assumed of the caller: URL-encoding a digit is a no-op, which
  # is what makes the interpolation equivalent to the old form.
  if [ -z "$league" ] || [[ ! "$yyyymmdd" =~ ^[0-9]{8}$ ]]; then
    printf '%s' '{"events":[]}'; return 1
  fi
  resp=$(request_get "$ESPN_BASE_URL/$league/scoreboard?dates=${yyyymmdd}" 0) || {
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
  resp=$(request_get "$ESPN_BASE_URL/$league/news" 0) || {
      printf '%s' '{"articles":[]}'; return 1
    }
  if ! jq -e . >/dev/null 2>&1 <<<"$resp"; then
    log "espn: non-JSON news response for $league"
    printf '%s' '{"articles":[]}'; return 1
  fi
  printf '%s' "$resp"
}

# espn_team_schedule <sport/league> <team_id> <yyyymmdd>
# Fetches one followed team's full-season schedule and reduces it to a
# window of recent + upcoming events around <yyyymmdd> ("today"), in
# the same event shape espn_slim_league already produces (name, date,
# status, notes, competitors) -- the writer isn't learning a second
# vocabulary. This is a different query from espn_scoreboard/
# espn_slim_league, not a filter on top of one: a followed team's game
# doesn't survive the league scoreboard's [0:10] cut reliably (a full
# college football Saturday runs 50+ games), and some teams (small
# college programs) never appear on the default scoreboard at all.
#
# The window (ESPN_TEAM_WINDOW_BACK_DAYS/ESPN_TEAM_WINDOW_FORWARD_DAYS)
# trims a 162-game MLB season down to a handful; a 10-competitor and
# 20-event cap are a backstop against a pathological payload. No TTL
# (pass 0 to request_get) -- no connector caches yet.
#
# Echoes {league, team_id, team, events:[...]} on success. On ANY
# failure -- empty args, a malformed date, a failed fetch, a date-math
# failure, or an unparseable/empty payload -- emits NOTHING and returns
# 1: a followed team whose fetch failed must not read downstream as
# "team has no games", which is what a valid-but-empty object would
# mean.
ESPN_TEAM_WINDOW_BACK_DAYS="${ESPN_TEAM_WINDOW_BACK_DAYS:-5}"
ESPN_TEAM_WINDOW_FORWARD_DAYS="${ESPN_TEAM_WINDOW_FORWARD_DAYS:-3}"

espn_team_schedule() {
  local league="$1" team_id="$2" yyyymmdd="$3" resp today_dash lo hi out
  if [ -z "$league" ] || [ -z "$team_id" ] || [[ ! "$yyyymmdd" =~ ^[0-9]{8}$ ]]; then
    return 1
  fi
  resp=$(request_get "$ESPN_BASE_URL/$league/teams/$team_id/schedule" 0) || return 1
  if ! jq -e . >/dev/null 2>&1 <<<"$resp"; then
    log "espn: non-JSON team schedule response for $league/$team_id"
    return 1
  fi
  today_dash="${yyyymmdd:0:4}-${yyyymmdd:4:2}-${yyyymmdd:6:2}"
  # Portable across GNU (Linux server) and BSD (macOS dev) date, same
  # fallback pattern do_sports_tick uses for ydash/ycompact.
  lo=$(date -d "$today_dash -${ESPN_TEAM_WINDOW_BACK_DAYS} days" +%F 2>/dev/null \
    || date -j -v-"${ESPN_TEAM_WINDOW_BACK_DAYS}"d -f %F "$today_dash" +%F 2>/dev/null)
  hi=$(date -d "$today_dash +${ESPN_TEAM_WINDOW_FORWARD_DAYS} days" +%F 2>/dev/null \
    || date -j -v+"${ESPN_TEAM_WINDOW_FORWARD_DAYS}"d -f %F "$today_dash" +%F 2>/dev/null)
  if [ -z "$lo" ] || [ -z "$hi" ]; then
    log "espn: date math failed for team schedule window ($today_dash)"
    return 1
  fi
  out=$(jq -n --arg league "$league" --arg team_id "$team_id" --arg lo "$lo" --arg hi "$hi" '
    (input) as $p |
    {
      league: $league,
      team_id: $team_id,
      team: ($p.team.displayName // null),
      events: [($p.events // [])[]
        | ((.date // "") | split("T")[0]) as $d
        | select($d >= $lo and $d <= $hi)
        | {
          name: .name,
          date: $d,
          status: (.status.type.description // .competitions[0].status.type.description // "unknown"),
          notes: [(.competitions[0].notes // [])[] | .headline // empty],
          competitors: [(.competitions[0].competitors // [])[0:10][] | {
            team: (.team.displayName // .athlete.displayName // null),
            score: (.score // null),
            winner: (.winner // null)
          }]
        }][0:20]
    }' <<<"$resp" 2>/dev/null) || return 1
  [ -z "$out" ] && return 1
  printf '%s' "$out"
}

# espn_parse_follow <raw>
# Parses SPORTS_FOLLOW (comma-separated "sport/league:team_id" entries)
# into TAB-separated "league<TAB>team_id" lines on stdout, one per
# valid entry -- same split-and-trim discipline as SPORTS_LEAGUES
# (bin/tick.sh). A malformed entry (no ':', empty league, or empty
# team_id) is logged and skipped; it never drops or corrupts the rest
# of the list. Unset/empty input emits nothing and returns 0 -- the
# regression case that keeps a bare SPORTS_LEAGUES-only setup untouched.
espn_parse_follow() {
  local raw="$1" entry league team_id
  [ -z "$raw" ] && return 0
  while IFS= read -r entry; do
    entry=$(sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//' <<<"$entry")
    [ -z "$entry" ] && continue
    case "$entry" in
      *:*) ;;
      *) log "espn: malformed SPORTS_FOLLOW entry (no ':'): $entry"; continue ;;
    esac
    league="${entry%%:*}"
    team_id="${entry#*:}"
    if [ -z "$league" ] || [ -z "$team_id" ]; then
      log "espn: malformed SPORTS_FOLLOW entry: $entry"
      continue
    fi
    printf '%s\t%s\n' "$league" "$team_id"
  done < <(tr ',' '\n' <<<"$raw")
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
