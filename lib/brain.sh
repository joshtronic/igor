# lib/brain.sh -- the sqlite "brain" store (seen_urls + reflections)
# for the reading-ingest and ideation pipelines. Model calls live in
# lib/claude.sh (claude_call).
#
# Expects the global BRAIN_DB set before any call.
#
# Provides:
#   brain_init                 -- idempotent schema + migrations
#   sqlite_quote <val>         -- escape a value for an inline SQL literal
#   insert_reflection <ts> <body_file> <source_url> [<kind>]
#                              -- INSERT a reflection; echoes the new id.
#                                 kind defaults to 'reading'; 'thought'
#                                 is an un-prompted journal entry.

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
