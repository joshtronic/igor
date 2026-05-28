# lib/brain.sh -- shared brain (sqlite) + model-call helpers for the
# reading-ingest and ideation pipelines.
#
# Source order matters: this expects lib/cost.sh already sourced
# (anthropic_call records usage via cost_record_api) and the globals
# BRAIN_DB and ANTHROPIC_API_KEY set before any call.
#
# Provides:
#   brain_init                 -- idempotent schema + migrations
#   sqlite_quote <val>         -- escape a value for an inline SQL literal
#   insert_reflection <ts> <body_file> <source_url> [<kind>]
#                              -- INSERT a reflection; echoes the new id.
#                                 kind defaults to 'reading'; 'thought'
#                                 is an un-prompted journal entry.
#   anthropic_call <model> <call_site> <max_tokens> <system> <user>
#                              -- POST to the Messages API; echoes the
#                                 model's text (code fences stripped).

# sqlite_quote: SQLite's only string escape is the doubled single quote.
sqlite_quote() {
  printf "'%s'" "$(printf '%s' "$1" | sed "s/'/''/g")"
}

# Lazy-init the brain db. CREATE IF NOT EXISTS makes a fresh install
# self-seed and is a no-op every tick after. The `kind` column is in
# the fresh schema and back-filled onto pre-existing tables via the
# guarded ALTER below -- SQLite can't ADD COLUMN conditionally, so we
# probe first.
brain_init() {
  sqlite3 "$BRAIN_DB" >/dev/null 2>&1 <<'SQL' || return 1
CREATE TABLE IF NOT EXISTS seen_urls (
    url        TEXT PRIMARY KEY,
    source     TEXT,
    domain     TEXT,
    first_seen TEXT,
    read_at    TEXT,
    notes      TEXT
);
CREATE TABLE IF NOT EXISTS reflections (
    id            INTEGER PRIMARY KEY AUTOINCREMENT,
    ts            TEXT NOT NULL,
    content       TEXT NOT NULL,
    source_url    TEXT,
    kind          TEXT NOT NULL DEFAULT 'reading',
    post_drafted  INTEGER DEFAULT 0
);
CREATE INDEX IF NOT EXISTS idx_reflections_ts ON reflections(ts);
SQL
  if ! sqlite3 "$BRAIN_DB" "SELECT kind FROM reflections LIMIT 0;" >/dev/null 2>&1; then
    sqlite3 "$BRAIN_DB" \
      "ALTER TABLE reflections ADD COLUMN kind TEXT NOT NULL DEFAULT 'reading';" \
      >/dev/null 2>&1 || return 1
  fi
  sqlite3 "$BRAIN_DB" \
    "CREATE INDEX IF NOT EXISTS idx_reflections_kind ON reflections(kind);" \
    >/dev/null 2>&1 || true
  return 0
}

# Insert a reflection. Uses readfile() to bypass SQL-quoting issues in
# long text bodies. Returns the new id on stdout.
insert_reflection() {
  local ts="$1" body_file="$2" source_url="$3" kind="${4:-reading}"
  sqlite3 "$BRAIN_DB" <<EOF
INSERT INTO reflections (ts, content, source_url, kind)
VALUES ($(sqlite_quote "$ts"), readfile($(sqlite_quote "$body_file")),
        $(sqlite_quote "$source_url"), $(sqlite_quote "$kind"));
SELECT last_insert_rowid();
EOF
}

# Anthropic Messages API call. Builds the payload via tempfiles to
# dodge ARG_MAX, POSTs via curl, records cost, echoes the content text
# with any code fences stripped. Non-zero on any failure.
anthropic_call() {
  local model="$1" call_site="$2" max_tokens="$3" system="$4" user="$5"
  local sys_file user_file payload_file response_file http_status text
  sys_file=$(mktemp); user_file=$(mktemp)
  payload_file=$(mktemp); response_file=$(mktemp)
  # shellcheck disable=SC2064
  trap "rm -f '$sys_file' '$user_file' '$payload_file' '$response_file'" RETURN

  printf '%s' "$system" > "$sys_file"
  printf '%s' "$user"   > "$user_file"
  jq -n \
    --arg m "$model" \
    --argjson mt "$max_tokens" \
    --rawfile s "$sys_file" \
    --rawfile u "$user_file" \
    '{model: $m, max_tokens: $mt, system: $s,
      messages: [{role: "user", content: $u}]}' \
    > "$payload_file" || return 1

  http_status=$(curl -sS \
    -X POST https://api.anthropic.com/v1/messages \
    -H "x-api-key: $ANTHROPIC_API_KEY" \
    -H "anthropic-version: 2023-06-01" \
    -H "Content-Type: application/json" \
    --max-time 120 \
    -w '%{http_code}' -o "$response_file" \
    --data-binary "@$payload_file" 2>/dev/null) || return 1

  if [ "$http_status" != "200" ]; then
    log "anthropic $call_site: HTTP $http_status -- $(jq -r '.error.message // .error.type // empty' < "$response_file" 2>/dev/null | head -c 200)"
    return 1
  fi

  cost_record_api "$call_site" "$model" "$(cat "$response_file")"

  text=$(jq -r '.content[0].text // empty' < "$response_file" 2>/dev/null)
  [ -z "$text" ] && { log "anthropic $call_site: empty content"; return 1; }
  printf '%s' "$text" | sed -E '/^```/d'
}
