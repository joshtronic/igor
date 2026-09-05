#!/usr/bin/env bash
# request.sh -- caching, backing-off HTTP GET/HEAD layer for connectors.
#
# The plumbing a connector rests on, not a connector itself. Generalizes
# lib/forgejo.sh's `_fj` retry doctrine (igor#395, #424, #425) for
# non-Forgejo hosts: bounded attempts, safe methods only, transport
# failures only -- an HTTP status is an ANSWER, not a hiccup. The one
# deliberate generalization: `_fj` never retries a 4xx/5xx because on
# Forgejo a 403 is the rate limiter and a 404 is a normal answer, but
# those are Forgejo facts, not HTTP facts. Here, 429 and 503 are the
# standard retry-me codes and ARE retried, honouring `Retry-After` when
# present. Every other 4xx/5xx stays non-retryable.
#
# Retry only ever applies to GET/HEAD. A retried POST/PUT/PATCH/DELETE
# risks a duplicate side effect (a re-sent email, a double-post) and is
# out of scope -- output connectors need their own idempotency handling.
#
# Caching applies to GET alone -- a HEAD has no body to serve back, so
# an entry could only ever replay "some HEAD succeeded recently". It is
# keyed on method + full URL and stored under $AGENT_STATE_DIR/cache/http,
# one body file per key plus a fetch-epoch sidecar. A per-call TTL
# controls freshness; ttl=0 (the default) is the explicit bypass -- no
# read, no write. A cache hit is never logged as a fetch. A failed
# re-fetch NEVER falls back to a stale cache entry: a stale "working"
# digest silently reporting last week's scores is a worse failure than a
# loud one. The cache is unbounded -- no eviction, no size cap. Nothing
# opts in yet (every current caller passes ttl=0); the first caller that
# does needs to bring a reaper with it.
#
# Requires on PATH: curl. sha256sum is used for the cache key; its
# absence degrades to "cache always misses" rather than a hard failure,
# same posture as lib/maintenance-checks.sh's own sha256sum guard.

if ! declare -F log >/dev/null; then
  log() { printf '[agent] %s\n' "$*" >&2; }
fi

# Same fail-fast rationale as lib/forgejo.sh's FORGEJO_CONNECT_TIMEOUT /
# FORGEJO_MAX_TIME (igor#395): a brief host blip either rides through or
# fails fast rather than wedging a tick.
REQUEST_CONNECT_TIMEOUT="${REQUEST_CONNECT_TIMEOUT:-5}"
REQUEST_MAX_TIME="${REQUEST_MAX_TIME:-15}"
# Bounded retry budget: REQUEST_RETRY_COUNT retries after the first
# attempt, for GET/HEAD only.
REQUEST_RETRY_COUNT="${REQUEST_RETRY_COUNT:-2}"
# Base backoff delay in seconds; doubles per attempt (1, 2, 4, ...) so
# consecutive failures don't hammer a struggling host at a constant rate.
REQUEST_RETRY_DELAY="${REQUEST_RETRY_DELAY:-1}"
# curl exit codes worth a second look: connect failed, timed out, SSL
# connect error, empty reply, recv failure. Mirrors
# FORGEJO_RETRY_CURL_CODES -- deliberately excludes 22, which this module
# never triggers since it doesn't pass curl -f.
REQUEST_RETRY_CURL_CODES="${REQUEST_RETRY_CURL_CODES:-7 28 35 52 56}"
# Upper bound on a server-supplied Retry-After, so a misbehaving host
# can't stall a tick indefinitely. Hardcoded -- one operator, bake it in.
REQUEST_MAX_RETRY_AFTER=30

_request_cache_dir() {
  printf '%s/cache/http' "${AGENT_STATE_DIR:-$HOME/.local/state/agent}"
}

# _request_cache_key <method> <url> -- filesystem-safe key. Empty output
# (and a nonzero return) when sha256sum isn't on PATH; callers treat that
# as "caching unavailable" rather than failing the fetch.
_request_cache_key() {
  command -v sha256sum >/dev/null 2>&1 || return 1
  printf '%s %s' "$1" "$2" | sha256sum | awk '{print $1}'
}

# _request_cache_get <method> <url> <ttl> -- prints the cached body and
# returns 0 on a fresh hit; returns 1 (nothing printed) on any miss --
# absent, unreadable, unparseable, or expired.
_request_cache_get() {
  local method="$1" url="$2" ttl="$3" dir key body_file meta_file fetched now
  [ "$ttl" -gt 0 ] 2>/dev/null || return 1
  dir="$(_request_cache_dir)"
  key="$(_request_cache_key "$method" "$url")" || return 1
  body_file="$dir/$key.body"
  meta_file="$dir/$key.meta"
  [ -f "$body_file" ] && [ -f "$meta_file" ] || return 1
  fetched="$(cat "$meta_file" 2>/dev/null)"
  [[ "$fetched" =~ ^[0-9]+$ ]] || return 1
  now=$(date +%s)
  [ $((now - fetched)) -lt "$ttl" ] || return 1
  cat "$body_file"
}

# _request_cache_put <method> <url> <body> -- best-effort; a write
# failure (no sha256sum, unwritable state dir) is silently skipped, since
# a cache miss next call is the correct degraded behavior, not a fetch
# failure now.
_request_cache_put() {
  local method="$1" url="$2" body="$3" dir key tmp
  dir="$(_request_cache_dir)"
  key="$(_request_cache_key "$method" "$url")" || return 0
  mkdir -p "$dir" 2>/dev/null || return 0
  # Write-then-rename, body before meta. Two ticks can share
  # $AGENT_STATE_DIR, and a reader that lands mid-write must see either no
  # meta (a miss) or a meta pointing at a COMPLETE body -- never a
  # fresh-looking stamp over half-written bytes.
  tmp="$dir/$key.$$.tmp"
  if ! printf '%s' "$body" >"$tmp" 2>/dev/null || ! mv -f "$tmp" "$dir/$key.body" 2>/dev/null; then
    rm -f "$tmp"
    return 0
  fi
  if ! date +%s >"$tmp" 2>/dev/null || ! mv -f "$tmp" "$dir/$key.meta" 2>/dev/null; then
    rm -f "$tmp"
  fi
}

# _request_backoff_delay <attempt> -- 1, 2, 4, 8, ... so a run of
# failures backs off instead of hammering at a constant rate.
_request_backoff_delay() {
  echo $((REQUEST_RETRY_DELAY * (2 ** ($1 - 1))))
}

# _request_retry_after_seconds <header_file> -- the Retry-After value in
# seconds, capped at REQUEST_MAX_RETRY_AFTER, or empty when the header is
# absent or not a plain integer (an HTTP-date Retry-After falls back to
# the default backoff rather than being parsed here).
_request_retry_after_seconds() {
  local raw
  raw=$(grep -i '^retry-after:' "$1" 2>/dev/null | tail -1 | cut -d: -f2- | tr -d '\r' | tr -d ' ')
  [[ "$raw" =~ ^[0-9]+$ ]] || return 0
  [ "$raw" -gt "$REQUEST_MAX_RETRY_AFTER" ] && raw="$REQUEST_MAX_RETRY_AFTER"
  echo "$raw"
}

# request_fetch <method> <url> [ttl_seconds] -- the core entry point.
# Returns 0 on success. GET/HEAD get the retry treatment described above;
# every other method gets exactly one attempt. Only GET is ever cached,
# regardless of ttl.
#
# On stdout: a GET prints the response body; a HEAD prints NOTHING, since
# the only thing a HEAD carries is its status and its headers. Every
# other method prints its body but is never cached.
#
# Returns 1 on a non-retryable HTTP status, and on a 429/503 that outlived
# the retry budget. A transport failure returns curl's OWN exit code
# instead -- whether it was non-retryable or outlived the budget -- so the
# caller can tell a timeout from a refused connection.
request_fetch() {
  local method="${1^^}" url="$2" ttl="${3:-0}"
  local retryable=0 cacheable=0
  case "$method" in
    GET) retryable=1 cacheable=1 ;;
    HEAD) retryable=1 ;;
  esac

  # -I, not -X HEAD: -X sends the HEAD verb but leaves curl expecting a
  # response body the server never sends, so the call blocks until
  # --max-time trips (curl exit 28, which IS in REQUEST_RETRY_CURL_CODES
  # -- every HEAD would burn the whole retry budget on a transport
  # failure that never happened). curl's own man page says as much under
  # -X. -I writes the header block to stdout, so -o /dev/null keeps it
  # out of the body -w appends the status to.
  local -a method_flags
  case "$method" in
    HEAD) method_flags=(-I -o /dev/null) ;;
    *) method_flags=(-X "$method") ;;
  esac

  local cached
  if [ "$cacheable" -eq 1 ] && cached=$(_request_cache_get "$method" "$url" "$ttl"); then
    [ -n "$cached" ] && printf '%s\n' "$cached"
    return 0
  fi

  local attempts=1
  [ "$retryable" -eq 1 ] && attempts=$((REQUEST_RETRY_COUNT + 1))

  local header_tmp attempt resp rc code body delay retry_after
  header_tmp=$(mktemp) || {
    log "request: ${method} ${url} -- mktemp failed, cannot capture headers"
    return 1
  }
  # A RETURN trap isn't scoped to this call: left alone, it also fires
  # (with header_tmp out of scope, tripping `set -u`) when the CALLER of
  # request_fetch next returns. Clear it as part of its own firing.
  trap 'rm -f "$header_tmp"; trap - RETURN' RETURN

  for ((attempt = 1; attempt <= attempts; attempt++)); do
    : >"$header_tmp"
    resp=$(curl -s -D "$header_tmp" -w '\n%{http_code}' \
      --connect-timeout "$REQUEST_CONNECT_TIMEOUT" --max-time "$REQUEST_MAX_TIME" \
      "${method_flags[@]}" "$url")
    rc=$?

    if [ "$rc" -eq 0 ]; then
      code="${resp##*$'\n'}"
      body="${resp%$'\n'*}"

      if [[ "$code" =~ ^2[0-9][0-9]$ ]]; then
        [ "$cacheable" -eq 1 ] && [ "$ttl" -gt 0 ] 2>/dev/null && _request_cache_put "$method" "$url" "$body"
        [ -n "$body" ] && printf '%s\n' "$body"
        return 0
      fi

      if [ "$code" = "429" ] || [ "$code" = "503" ]; then
        if [ "$retryable" -eq 1 ] && [ "$attempt" -lt "$attempts" ]; then
          retry_after=$(_request_retry_after_seconds "$header_tmp")
          delay="${retry_after:-$(_request_backoff_delay "$attempt")}"
          sleep "$delay"
          continue
        fi
        log "request: ${method} ${url} -> HTTP ${code} after ${attempt} attempt(s)"
        return 1
      fi

      # Any other status is an answer, not a hiccup -- never retried.
      return 1
    fi

    # Transport failure. Only these curl exit codes are worth a retry.
    if [[ " $REQUEST_RETRY_CURL_CODES " != *" $rc "* ]]; then
      return "$rc"
    fi
    if [ "$retryable" -eq 1 ] && [ "$attempt" -lt "$attempts" ]; then
      sleep "$(_request_backoff_delay "$attempt")"
      continue
    fi
    log "request: ${method} ${url} failed after ${attempt} attempt(s) (curl exit ${rc})"
    return "$rc"
  done
}

# request_get <url> [ttl_seconds] -- GET convenience wrapper.
request_get() {
  request_fetch GET "$1" "${2:-0}"
}
