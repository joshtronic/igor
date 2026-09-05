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
# The window (5 days back, 3 forward -- hardcoded below, chosen to trim
# a 162-game MLB season down to a handful without a config surface
# nobody will ever set differently) and a 10-competitor/20-event cap
# are a backstop against a pathological payload. No TTL (pass 0 to
# request_get) -- no connector caches yet.
#
# The `/schedule` sub-path is not guaranteed to exist for every league
# (igor#587 verified it for `baseball/mlb` but listed the college
# endpoints without it), so a FAILED fetch there retries the bare team
# endpoint, whose `.team.nextEvent` carries the same event shape. That
# fallback covers upcoming games only -- the back half of the window is
# lost on it -- which still beats going dark on the motivating case. A
# fetch that SUCCEEDS and answers garbage is ESPN being broken, not a
# missing path, and is not retried elsewhere.
#
# Echoes {league, team_id, team, events:[{name,date,status,notes,
# competitors:[{team,score,winner,record}]}]} on success -- `record` is
# the competitor's overall W-L summary, same as espn_slim_league.
# Absent/malformed `records` yields null, same as `score`/`winner`. On
# ANY failure -- empty args, a malformed date, both fetches failing, a
# date-math failure, or an unparseable/empty payload -- emits NOTHING
# and returns 1: a followed team whose fetch failed must not read
# downstream as "team has no games", which is what a valid-but-empty
# object would mean.
ESPN_TEAM_WINDOW_BACK_DAYS=5
ESPN_TEAM_WINDOW_FORWARD_DAYS=3

# _et_session_date <utc_timestamp> -- echoes the calendar date (YYYY-MM-DD)
# the given UTC timestamp falls on in America/New_York, using the system tz
# database (handles EST/EDT correctly, unlike a naive split on "T"). Echoes
# nothing and returns 1 on an empty or unparseable timestamp.
_et_session_date() {
  local ts="$1" epoch
  [ -z "$ts" ] && return 1
  if TZ=America/New_York date -d "$ts" +%F 2>/dev/null; then
    return 0
  fi
  # BSD date (macOS dev) has to go through an epoch: `-j -f` parses in the
  # CURRENT zone and matches the trailing Z as a literal character, so a
  # TZ=America/New_York prefix on the parse would read the timestamp as
  # Eastern and hand back exactly the naive answer this function exists to
  # avoid. Parse as UTC, then render that instant in ET.
  epoch=$(TZ=UTC date -j -f '%Y-%m-%dT%H:%M:%SZ' "$ts" +%s 2>/dev/null) \
    || epoch=$(TZ=UTC date -j -f '%Y-%m-%dT%H:%MZ' "$ts" +%s 2>/dev/null) \
    || return 1
  TZ=America/New_York date -r "$epoch" +%F 2>/dev/null
}

espn_team_schedule() {
  local league="$1" team_id="$2" yyyymmdd="$3" resp today_dash lo hi prehi out
  local team_json raw_events ts d ts_list=() et_dates=() dates_json
  if [ -z "$league" ] || [ -z "$team_id" ] || [[ ! "$yyyymmdd" =~ ^[0-9]{8}$ ]]; then
    return 1
  fi
  if ! resp=$(request_get "$ESPN_BASE_URL/$league/teams/$team_id/schedule" 0); then
    resp=$(request_get "$ESPN_BASE_URL/$league/teams/$team_id" 0) || return 1
  fi
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
  # ET runs behind UTC, so an event's ET date is either its UTC date or the
  # day before it: everything that can land in [lo, hi] has a UTC date in
  # [lo, hi+1]. Narrowing to that in jq first costs one fork instead of one
  # per event, and leaves the window -- not a slice of the payload's head --
  # as the thing bounding the work.
  prehi=$(date -d "$today_dash +$((ESPN_TEAM_WINDOW_FORWARD_DAYS + 1)) days" +%F 2>/dev/null \
    || date -j -v+"$((ESPN_TEAM_WINDOW_FORWARD_DAYS + 1))"d -f %F "$today_dash" +%F 2>/dev/null)
  if [ -z "$lo" ] || [ -z "$hi" ] || [ -z "$prehi" ]; then
    log "espn: date math failed for team schedule window ($today_dash)"
    return 1
  fi
  team_json=$(jq -n -c '(input).team.displayName // null' <<<"$resp" 2>/dev/null) || return 1
  # [0:50] is a runaway guard against a pathological payload, not a second
  # window: 50 candidates inside a nine-day span is already past any real
  # schedule, and only 20 are emitted.
  raw_events=$(jq -n -c --arg lo "$lo" --arg prehi "$prehi" '
    (input) as $p
    | [((($p.events // $p.team.nextEvent) // [])[]
        | select(((.date // "") | split("T")[0]) as $u | $u >= $lo and $u <= $prehi))][0:50]' \
    <<<"$resp" 2>/dev/null) || return 1
  # Each candidate's ET calendar date is resolved outside jq (via the system
  # tz database) and fed back in by index -- jq alone can't apply EST/EDT
  # correctly.
  mapfile -t ts_list < <(jq -r '.[] | .date // ""' <<<"$raw_events")
  for ts in "${ts_list[@]}"; do
    d=$(_et_session_date "$ts") || d=""
    et_dates+=("$d")
  done
  if [ "${#et_dates[@]}" -eq 0 ]; then
    dates_json='[]'
  else
    dates_json=$(printf '%s\n' "${et_dates[@]}" | jq -R -s -c 'rtrimstr("\n") | split("\n")')
  fi
  # The events stay on stdin. Linux caps a single argv string at 128KB and a
  # full-season team schedule runs well past that, so --argjson would hand
  # execve an E2BIG that the `|| return 1` below would report as a failed
  # fetch -- a followed team silently dropping out of the digest.
  out=$(jq -n --arg league "$league" --arg team_id "$team_id" --arg lo "$lo" --arg hi "$hi" \
    --argjson team "$team_json" --argjson dates "$dates_json" '
    (input) as $events |
    {
      league: $league,
      team_id: $team_id,
      team: $team,
      events: [range(0; ($events | length)) as $i
        | $events[$i] as $ev
        | ($dates[$i] // "") as $d
        | select($d != "" and $d >= $lo and $d <= $hi)
        | {
          name: $ev.name,
          date: $d,
          status: ($ev.status.type.description // $ev.competitions[0].status.type.description // "unknown"),
          notes: [($ev.competitions[0].notes // [])[] | .headline // empty],
          competitors: [($ev.competitions[0].competitors // [])[0:10][] | {
            team: (.team.displayName // .athlete.displayName // null),
            score: (.score // null),
            winner: (.winner // null),
            record: (((.records // []) | (if type == "array" then . else [] end)) | map(select(type == "object" and .name == "overall")) | (.[0].summary // null))
          }]
        }][0:20]
    }' <<<"$raw_events" 2>/dev/null) || return 1
  [ -z "$out" ] && return 1
  printf '%s' "$out"
}

# _espn_trim <s> -- strips leading and trailing whitespace.
_espn_trim() { sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//' <<<"$1"; }

# espn_parse_follow <raw>
# Parses SPORTS_FOLLOW (comma-separated "sport/league:team_id" entries)
# into TAB-separated "league<TAB>team_id" lines on stdout, one per
# valid entry -- same split-and-trim discipline as SPORTS_LEAGUES
# (bin/tick.sh). A malformed entry (no ':', empty league, or empty
# team_id) is logged and skipped; it never drops or corrupts the rest
# of the list. Unset/empty input emits nothing and returns 0 -- the
# regression case that keeps a bare SPORTS_LEAGUES-only setup untouched.
# Both halves are trimmed as well as the whole entry, so `mlb: laa`
# yields the team_id `laa` rather than a URL with a space in it.
espn_parse_follow() {
  local raw="$1" entry league team_id
  [ -z "$raw" ] && return 0
  while IFS= read -r entry; do
    entry=$(_espn_trim "$entry")
    [ -z "$entry" ] && continue
    case "$entry" in
      *:*) ;;
      *) log "espn: malformed SPORTS_FOLLOW entry (no ':'): $entry"; continue ;;
    esac
    league=$(_espn_trim "${entry%%:*}")
    team_id=$(_espn_trim "${entry#*:}")
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
#     events:[{name,date,status,notes,competitors:[{team,score,winner,record}]}],
#     headlines:[{headline,description,published,link}] }
# `record` is the competitor's overall W-L summary (ESPN's `records`
# array, `name == "overall"`) -- home/road splits are not carried.
# Absent or malformed `records` yields null, same as `score`/`winner`.
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
          winner: (.winner // null),
          record: (((.records // []) | (if type == "array" then . else [] end)) | map(select(type == "object" and .name == "overall")) | (.[0].summary // null))
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
