#!/usr/bin/env python3
"""migrate-brain-to-sqlite.py -- one-shot migration from the brain
markdown repo to ~/.local/state/agent/brain.sqlite.

Additive: the brain repo stays intact. This script reads the
markdown files and populates the sqlite store that the new
reading pipeline (Phase 2) will consume.

Idempotent: re-running against the same db is safe. URLs are
PK'd; reflections are deduped by timestamp + content hash before
insert; sources are INSERT OR IGNORE.

Skips, from journal/*.md, entries that are pure harness stubs
(maintenance summaries, HN snapshot summaries, "(no reflection
from Claude this tick)" placeholders). Reflections table is for
material Claude actually wrote.

Usage:
  bin/migrate-brain-to-sqlite.py <brain-path> [--db-path PATH]

Env:
  AGENT_STATE_DIR -- default db location parent (brain.sqlite
                     inside). Falls back to ~/.local/state/agent.
"""

import argparse
import hashlib
import os
import re
import sqlite3
import sys
from pathlib import Path
from urllib.parse import urlparse


SCHEMA = """
CREATE TABLE IF NOT EXISTS seen_urls (
    url        TEXT PRIMARY KEY,
    source     TEXT,
    domain     TEXT,
    first_seen TEXT,
    read_at    TEXT,
    notes      TEXT
);

CREATE TABLE IF NOT EXISTS sources (
    url    TEXT PRIMARY KEY,
    weight INTEGER,
    label  TEXT,
    status TEXT
);

CREATE TABLE IF NOT EXISTS reflections (
    id            INTEGER PRIMARY KEY AUTOINCREMENT,
    ts            TEXT NOT NULL,
    content       TEXT NOT NULL,
    source_url    TEXT,
    post_drafted  INTEGER DEFAULT 0
);

CREATE INDEX IF NOT EXISTS idx_reflections_ts ON reflections(ts);
"""

# The four-source slate the new reading pipeline draws from.
SOURCE_SLATE = [
    ("https://joshtronic.com",       "Josh's blog"),
    ("https://thatgirljen.com",      "Jen's blog"),
    ("https://news.ycombinator.com", "Hacker News"),
    ("https://kagi.com/smallweb",    "Kagi Small Web"),
]

# A journal entry whose body matches one of these prefixes is a
# harness stub, not a Claude reflection. Skip on migration.
STUB_PREFIXES = (
    "(no reflection from Claude this tick",
    "(no body --",
    "Scheduled maintenance pass on",
    "HN front-page snapshot",
    "(reading executor ran for",
    "(reflect executor ran for",
)


def default_db_path() -> Path:
    state_dir = os.environ.get("AGENT_STATE_DIR")
    if state_dir:
        return Path(state_dir) / "brain.sqlite"
    return Path.home() / ".local" / "state" / "agent" / "brain.sqlite"


def domain_of(url: str) -> str:
    try:
        return urlparse(url).netloc or ""
    except Exception:
        return ""


def init_schema(con: sqlite3.Connection) -> None:
    con.executescript(SCHEMA)
    con.commit()


def seed_sources(con: sqlite3.Connection) -> int:
    cur = con.cursor()
    added = 0
    for url, label in SOURCE_SLATE:
        before = cur.execute("SELECT changes()").fetchone()
        cur.execute(
            "INSERT OR IGNORE INTO sources (url, weight, label, status) "
            "VALUES (?, 1, ?, 'active')",
            (url, label),
        )
        if cur.rowcount > 0:
            added += 1
    con.commit()
    return added


# ----- ledger parsing -------------------------------------------

# `- [ ] URL [-- annotation -- ...]` or `- [x] URL [-- annotation -- ...]`
LEDGER_LINE_RE = re.compile(r'^- \[([ x])\]\s+(\S+)(?:\s+--\s+(.+))?$')

# `read YYYY-MM-DD` annotation inside an [x] line
READ_ANNOTATION_RE = re.compile(r'read (\d{4}-\d{2}-\d{2})')


def parse_ledger_file(path: Path) -> list[dict]:
    """Yield records from a per-source ledger file
    (memories/reading/sources/<domain>.md)."""
    records = []
    source_url = None
    in_index = False
    with path.open(encoding="utf-8") as fh:
        for raw in fh:
            line = raw.rstrip("\n")
            if not source_url and line.startswith("Source:"):
                source_url = line.split(":", 1)[1].strip()
            if line.startswith("## Index"):
                in_index = True
                continue
            if not in_index:
                continue
            m = LEDGER_LINE_RE.match(line)
            if not m:
                continue
            checked, url, annotation = m.group(1), m.group(2), m.group(3) or ""
            read_at = None
            if checked == "x":
                ra = READ_ANNOTATION_RE.search(annotation)
                read_at = ra.group(1) if ra else None
            records.append({
                "url": url,
                "source": source_url,
                "domain": domain_of(url),
                "read_at": read_at,
                "notes": annotation.strip() or None,
            })
    return records


def migrate_ledgers(con: sqlite3.Connection, brain: Path) -> dict:
    """Insert one row per ledger entry into seen_urls. PK conflict
    on url -> skip (preserves earlier first_seen). After insert,
    set first_seen on rows where it's NULL (rare; first migration)."""
    sources_dir = brain / "memories" / "reading" / "sources"
    counts = {"files": 0, "inserted": 0, "skipped": 0}
    if not sources_dir.is_dir():
        return counts
    cur = con.cursor()
    today = None  # ledger entries don't carry a first_seen date
    for f in sorted(sources_dir.glob("*.md")):
        counts["files"] += 1
        for rec in parse_ledger_file(f):
            cur.execute(
                "INSERT OR IGNORE INTO seen_urls "
                "(url, source, domain, first_seen, read_at, notes) "
                "VALUES (?, ?, ?, ?, ?, ?)",
                (rec["url"], rec["source"], rec["domain"],
                 today, rec["read_at"], rec["notes"]),
            )
            if cur.rowcount > 0:
                counts["inserted"] += 1
            else:
                counts["skipped"] += 1
                # If this run learned a read date and the existing
                # row didn't have one, refine it.
                if rec["read_at"]:
                    cur.execute(
                        "UPDATE seen_urls SET read_at = ? "
                        "WHERE url = ? AND read_at IS NULL",
                        (rec["read_at"], rec["url"]),
                    )
    con.commit()
    return counts


# ----- log.md parsing -------------------------------------------

# Date heading in log.md: "## YYYY-MM-DD"
LOG_DATE_RE = re.compile(r'^## (\d{4}-\d{2}-\d{2})')

# Log entry line: "- domain -- "Title" -- URL"   (URL optional)
# Capture the URL if present.
LOG_LINE_URL_RE = re.compile(r'https?://\S+')


def migrate_log(con: sqlite3.Connection, brain: Path) -> dict:
    """For each URL mentioned in log.md, ensure it's in seen_urls
    with read_at set to the section's date header."""
    log_path = brain / "memories" / "reading" / "log.md"
    counts = {"entries": 0, "urls_set_read_at": 0, "url_lines_without_url": 0}
    if not log_path.is_file():
        return counts
    cur = con.cursor()
    current_date = None
    with log_path.open(encoding="utf-8") as fh:
        for raw in fh:
            line = raw.rstrip("\n")
            m = LOG_DATE_RE.match(line)
            if m:
                current_date = m.group(1)
                continue
            if not current_date or not line.startswith("- "):
                continue
            counts["entries"] += 1
            url_m = LOG_LINE_URL_RE.search(line)
            if not url_m:
                counts["url_lines_without_url"] += 1
                continue
            url = url_m.group(0)
            # Ensure the row exists, then set read_at if absent or
            # later than current_date (keep earliest read).
            cur.execute(
                "INSERT OR IGNORE INTO seen_urls "
                "(url, source, domain, first_seen, read_at) "
                "VALUES (?, NULL, ?, ?, ?)",
                (url, domain_of(url), current_date, current_date),
            )
            cur.execute(
                "UPDATE seen_urls SET read_at = ? "
                "WHERE url = ? AND (read_at IS NULL OR read_at > ?)",
                (current_date, url, current_date),
            )
            if cur.rowcount > 0:
                counts["urls_set_read_at"] += 1
    con.commit()
    return counts


# ----- journal parsing ------------------------------------------

# Header line: "## YYYY-MM-DDTHH:MM:SS+ZZZZ -- <mode-suffix>"
JOURNAL_HEADER_RE = re.compile(
    r'^## (\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}[+-]\d{4})\s+--\s+(.+)$'
)


def iter_journal_entries(path: Path):
    """Yield (ts, mode_suffix, body) tuples from a journal file."""
    ts = mode = None
    body_lines: list[str] = []
    with path.open(encoding="utf-8") as fh:
        for raw in fh:
            line = raw.rstrip("\n")
            m = JOURNAL_HEADER_RE.match(line)
            if m:
                if ts is not None:
                    yield ts, mode, "\n".join(body_lines).strip()
                ts, mode = m.group(1), m.group(2).strip()
                body_lines = []
                continue
            body_lines.append(line)
    if ts is not None:
        yield ts, mode, "\n".join(body_lines).strip()


def is_stub(body: str) -> bool:
    body = body.lstrip()
    return any(body.startswith(p) for p in STUB_PREFIXES) or not body


def migrate_journal(con: sqlite3.Connection, brain: Path) -> dict:
    journal_dir = brain / "journal"
    counts = {"files": 0, "entries_seen": 0, "stubs_skipped": 0,
              "inserted": 0, "duplicates_skipped": 0}
    if not journal_dir.is_dir():
        return counts
    cur = con.cursor()
    for f in sorted(journal_dir.glob("*.md")):
        counts["files"] += 1
        for ts, mode, body in iter_journal_entries(f):
            counts["entries_seen"] += 1
            if is_stub(body):
                counts["stubs_skipped"] += 1
                continue
            # Dedupe by (ts, content_hash). Two reflections with
            # identical timestamps + content shouldn't migrate
            # twice on re-run.
            content_hash = hashlib.sha256(body.encode("utf-8")).hexdigest()
            existing = cur.execute(
                "SELECT id FROM reflections WHERE ts = ? "
                "AND content = ?",
                (ts, body),
            ).fetchone()
            if existing:
                counts["duplicates_skipped"] += 1
                continue
            cur.execute(
                "INSERT INTO reflections (ts, content, source_url) "
                "VALUES (?, ?, NULL)",
                (ts, body),
            )
            counts["inserted"] += 1
            _ = content_hash  # reserved for a future content_hash column
    con.commit()
    return counts


# ----- main -----------------------------------------------------

def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("brain_path", help="Path to brain repo working tree")
    ap.add_argument("--db-path", default=None,
                    help="sqlite db path (default: $AGENT_STATE_DIR/brain.sqlite "
                         "or ~/.local/state/agent/brain.sqlite)")
    args = ap.parse_args()

    brain = Path(args.brain_path).expanduser().resolve()
    if not brain.is_dir():
        print(f"error: brain path not a directory: {brain}", file=sys.stderr)
        return 1

    db_path = Path(args.db_path).expanduser() if args.db_path else default_db_path()
    db_path.parent.mkdir(parents=True, exist_ok=True)

    con = sqlite3.connect(db_path)
    con.row_factory = sqlite3.Row

    print(f"db:    {db_path}")
    print(f"brain: {brain}")
    print()

    init_schema(con)
    print("schema: ensured")

    added = seed_sources(con)
    total_sources = con.execute("SELECT COUNT(*) FROM sources").fetchone()[0]
    print(f"sources: +{added} new, {total_sources} total")

    ledger_counts = migrate_ledgers(con, brain)
    print(f"ledgers: read {ledger_counts['files']} files, "
          f"+{ledger_counts['inserted']} new urls, "
          f"{ledger_counts['skipped']} already-present (read_at refined where applicable)")

    log_counts = migrate_log(con, brain)
    print(f"log.md: {log_counts['entries']} entries scanned, "
          f"{log_counts['urls_set_read_at']} url reads applied, "
          f"{log_counts['url_lines_without_url']} log lines without URLs (skipped)")

    journal_counts = migrate_journal(con, brain)
    print(f"journal: {journal_counts['files']} files, "
          f"{journal_counts['entries_seen']} entries seen, "
          f"{journal_counts['stubs_skipped']} stubs skipped, "
          f"+{journal_counts['inserted']} reflections inserted, "
          f"{journal_counts['duplicates_skipped']} duplicates skipped")

    print()
    print("totals:")
    print(f"  seen_urls:   {con.execute('SELECT COUNT(*) FROM seen_urls').fetchone()[0]}")
    print(f"  seen_urls.read_at NOT NULL: "
          f"{con.execute('SELECT COUNT(*) FROM seen_urls WHERE read_at IS NOT NULL').fetchone()[0]}")
    print(f"  sources:     {con.execute('SELECT COUNT(*) FROM sources').fetchone()[0]}")
    print(f"  reflections: {con.execute('SELECT COUNT(*) FROM reflections').fetchone()[0]}")

    con.close()
    return 0


if __name__ == "__main__":
    sys.exit(main())
