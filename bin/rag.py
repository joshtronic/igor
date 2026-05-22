#!/usr/bin/env python3
"""rag.py -- build or query Igor's cross-tick RAG index.

Subcommands:
    build           Rebuild the index from brain (journal + memories)
                    plus recent commits from each bot-accessible repo.
    query <text>    Find top-K relevant entries for <text>.

The corpus has four sources, distinguishable via the `source` tag:
    journal -- per-tick reflections from brain/journal/
    memory  -- distilled memory files from brain/memories/
    commit  -- recent commits across cloned repos (default last 30 days)
    review  -- review bodies + inline comments from recently merged
               PRs (default last 30 days). Captures human feedback
               that's actionable for future work (e.g., "ship it but
               next time consider X"). Approval comments that
               otherwise vanish into Forgejo's UI surface here.

Both commands require Redis 8+ (or Redis Stack -- needs the vector
search module) at $REDIS_URL (default redis://localhost:6379), and
the venv set up by bin/setup-rag.sh.

Designed to be called by tick.sh. Failures should not break ticks:
the wrapper should run with `set +e` and fall back to no-RAG mode
on non-zero exit.

Environment:
    REDIS_URL              redis connection (default redis://localhost:6379)
    IGOR_BRAIN_PATH        path to brain repo
    IGOR_REPO_ROOT         where the harness clones repos
                           (default ~/.local/state/igor/repos)
    IGOR_RAG_COMMIT_DAYS   how far back to embed commits (default 30)
    IGOR_RAG_REVIEW_DAYS   how far back to embed PR reviews (default 30)
    IGOR_RAG_CACHE_PATH    sqlite embedding cache location
                           (default $IGOR_STATE_DIR/rag-embeddings.sqlite)
    FORGEJO_URL            Forgejo base URL (for review fetch)
    FORGEJO_TOKEN          Forgejo API token (for review fetch)

The sqlite cache stores deterministic (model, text) -> embedding
mappings so a full corpus re-embed only happens once. Subsequent
ticks embed only NEW entries (new journal entries, new commits,
edited memories). Restoring from zero is `rm $cache_path`; the
next tick rebuilds it.
"""

import argparse
import hashlib
import json
import os
import re
import sqlite3
import subprocess
import sys
import urllib.error
import urllib.parse
import urllib.request
from datetime import datetime, timedelta, timezone
from pathlib import Path

import numpy as np
import redis
from fastembed import TextEmbedding
from redisvl.index import SearchIndex
from redisvl.query import VectorQuery
from redisvl.schema import IndexSchema

EMBED_MODEL = "BAAI/bge-small-en-v1.5"
EMBED_DIMS = 384
INDEX_NAME = "igor-rag"
DEFAULT_BRAIN = os.environ.get("IGOR_BRAIN_PATH") or os.path.expanduser(
    "~/.local/state/igor/repos/igor/brain"
)
DEFAULT_REPO_ROOT = os.environ.get("IGOR_REPO_ROOT") or os.path.expanduser(
    "~/.local/state/igor/repos"
)
COMMIT_DAYS = int(os.environ.get("IGOR_RAG_COMMIT_DAYS", "30"))
REVIEW_DAYS = int(os.environ.get("IGOR_RAG_REVIEW_DAYS", "30"))
FORGEJO_URL = os.environ.get("FORGEJO_URL", "").rstrip("/")
FORGEJO_TOKEN = os.environ.get("FORGEJO_TOKEN", "")
REDIS_URL = os.environ.get("REDIS_URL", "redis://localhost:6379")
DEFAULT_STATE_DIR = os.environ.get("IGOR_STATE_DIR") or os.path.expanduser(
    "~/.local/state/igor"
)
CACHE_PATH = os.environ.get("IGOR_RAG_CACHE_PATH") or os.path.join(
    DEFAULT_STATE_DIR, "rag-embeddings.sqlite"
)

SCHEMA = {
    "index": {
        "name": INDEX_NAME,
        "prefix": "igor:",
        "storage_type": "hash",
    },
    "fields": [
        {"name": "text", "type": "text"},
        {"name": "source", "type": "tag"},   # journal | memory | commit
        {"name": "date", "type": "tag"},     # YYYY-MM-DD or "n/a"
        {"name": "timestamp", "type": "tag"},  # human-readable header
        {"name": "repo", "type": "tag"},     # owner/repo, empty for journal/memory
        {
            "name": "embedding",
            "type": "vector",
            "attrs": {
                "dims": EMBED_DIMS,
                "algorithm": "flat",
                "distance_metric": "cosine",
                "datatype": "float32",
            },
        },
    ],
}


def check_redis():
    """Bail with a clear message if Redis or vector search isn't available."""
    try:
        r = redis.from_url(REDIS_URL, socket_connect_timeout=2)
        r.ping()
    except redis.exceptions.ConnectionError as e:
        print(f"rag: cannot connect to Redis at {REDIS_URL}: {e}", file=sys.stderr)
        sys.exit(3)
    modules = r.execute_command("MODULE", "LIST")
    flat = []
    for mod in modules:
        if isinstance(mod, list):
            flat.extend(mod)
        else:
            flat.append(mod)
    have_search = any(
        b"search" in (m.lower() if isinstance(m, bytes) else b"")
        for m in flat
    )
    if not have_search:
        print(
            "rag: vector search module not loaded. Install redis-server 8+ "
            "from packages.redis.io. See docs/setup.md.",
            file=sys.stderr,
        )
        sys.exit(4)


# -- journal collector ----------------------------------------------------

def parse_journal(path: Path):
    """Split a journal file into (header, body) entries."""
    content = path.read_text(encoding="utf-8")
    parts = re.split(r"(?m)^## ", content)
    for part in parts[1:]:
        lines = part.split("\n", 1)
        header = lines[0].strip()
        body = lines[1].strip() if len(lines) > 1 else ""
        if not body:
            continue
        yield header, body


def collect_journal_entries(brain_path: Path):
    """Yield row dicts for each journal entry."""
    journal_dir = brain_path / "journal"
    if not journal_dir.is_dir():
        return
    for jf in sorted(journal_dir.glob("*.md")):
        date_str = jf.stem  # YYYY-MM-DD
        for header, body in parse_journal(jf):
            text = f"{header}\n\n{body}".strip()
            eid = hashlib.sha256(
                f"journal:{jf.name}:{header}".encode("utf-8")
            ).hexdigest()[:16]
            yield {
                "key": f"igor:journal:{eid}",
                "text": text,
                "source": "journal",
                "date": date_str,
                "timestamp": header,
                "repo": "",
            }


# -- memory collector -----------------------------------------------------

def collect_memory_entries(brain_path: Path):
    """Yield row dicts for each memory file (one entry per file)."""
    mem_dir = brain_path / "memories"
    if not mem_dir.is_dir():
        return
    skip_names = {"MEMORY.md", "README.md"}
    for mf in sorted(mem_dir.rglob("*.md")):
        if mf.name in skip_names:
            continue
        try:
            content = mf.read_text(encoding="utf-8").strip()
        except OSError:
            continue
        if not content:
            continue
        rel = mf.relative_to(brain_path)
        eid = hashlib.sha256(
            f"memory:{rel}".encode("utf-8")
        ).hexdigest()[:16]
        # Use the file path as the human-readable header
        yield {
            "key": f"igor:memory:{eid}",
            "text": content,
            "source": "memory",
            "date": "n/a",
            "timestamp": str(rel),
            "repo": "",
        }


# -- commit collector -----------------------------------------------------

def discover_repos(repo_root: Path):
    """Yield Path objects for every git repo under repo_root.

    Layout: $IGOR_REPO_ROOT/<owner>/<repo>/.git
    """
    if not repo_root.is_dir():
        return
    for owner_dir in sorted(repo_root.iterdir()):
        if not owner_dir.is_dir():
            continue
        for repo_dir in sorted(owner_dir.iterdir()):
            if not repo_dir.is_dir():
                continue
            if (repo_dir / ".git").exists():
                yield repo_dir


def collect_commit_entries(repo_root: Path, days: int):
    """Walk each repo's git log and yield row dicts for recent commits.

    Uses a NUL-separated format to handle multi-line bodies safely.
    Skips merge commits (they're rarely useful retrieval context).
    """
    fmt = "%H%x00%ai%x00%s%x00%b%x00END%x00"
    for repo_path in discover_repos(repo_root):
        try:
            owner_repo = f"{repo_path.parent.name}/{repo_path.name}"
        except Exception:
            continue
        try:
            out = subprocess.run(
                [
                    "git", "-C", str(repo_path),
                    "log",
                    f"--since={days} days ago",
                    "--no-merges",
                    f"--format={fmt}",
                ],
                capture_output=True, text=True, timeout=30,
            )
        except Exception:
            continue
        if out.returncode != 0:
            continue
        for record in out.stdout.split("END\x00"):
            record = record.strip()
            if not record:
                continue
            parts = record.split("\x00")
            if len(parts) < 4:
                continue
            sha, date_iso, subject, body = parts[0], parts[1], parts[2], parts[3]
            sha = sha.strip()
            subject = subject.strip()
            body = body.strip()
            if not sha or not subject:
                continue
            date_str = date_iso.split(" ")[0] if date_iso else "n/a"
            text = subject if not body else f"{subject}\n\n{body}"
            eid = hashlib.sha256(
                f"commit:{owner_repo}:{sha}".encode("utf-8")
            ).hexdigest()[:16]
            yield {
                "key": f"igor:commit:{eid}",
                "text": text,
                "source": "commit",
                "date": date_str,
                "timestamp": f"{owner_repo}@{sha[:8]}: {subject}",
                "repo": owner_repo,
            }


# -- review collector ----------------------------------------------------

def _forgejo_get(path: str):
    """GET /api/v1/<path> against FORGEJO_URL with token auth.
    Returns parsed JSON, or None on any failure."""
    if not FORGEJO_URL or not FORGEJO_TOKEN:
        return None
    url = f"{FORGEJO_URL}/api/v1/{path.lstrip('/')}"
    req = urllib.request.Request(
        url,
        headers={
            "Authorization": f"token {FORGEJO_TOKEN}",
            "Accept": "application/json",
        },
    )
    try:
        with urllib.request.urlopen(req, timeout=15) as resp:
            return json.loads(resp.read().decode("utf-8"))
    except (urllib.error.URLError, urllib.error.HTTPError, json.JSONDecodeError, TimeoutError):
        return None


def collect_review_entries(repo_root: Path, days: int):
    """Walk recently merged PRs in each repo, yield row dicts for
    each non-bot review body and inline comment.

    Captures human feedback that would otherwise vanish into
    Forgejo's UI once a PR is merged: approval comments, request-
    changes summaries, line-level corrections. These inform
    future ticks via RAG retrieval.
    """
    if not FORGEJO_URL or not FORGEJO_TOKEN:
        return  # API not configured (e.g., local dev without .env)

    bot_user = os.environ.get("BOT_USER", "")  # best-effort filter
    cutoff = datetime.now(timezone.utc) - timedelta(days=days)

    for repo_path in discover_repos(repo_root):
        owner_repo = f"{repo_path.parent.name}/{repo_path.name}"

        # List recently closed/merged PRs. Forgejo's pulls endpoint
        # sorts by recently updated; limit 50 covers most active
        # repos for ~30 days. Pagination could be added later.
        prs = _forgejo_get(
            f"repos/{owner_repo}/pulls?state=closed&sort=newest&limit=50"
        )
        if not prs:
            continue

        for pr in prs:
            # Skip if older than cutoff
            updated = pr.get("updated_at") or ""
            try:
                pr_dt = datetime.fromisoformat(updated.replace("Z", "+00:00"))
            except ValueError:
                continue
            if pr_dt < cutoff:
                continue

            pr_num = pr.get("number")
            pr_title = (pr.get("title") or "").strip()
            if not pr_num:
                continue

            # Fetch reviews on this PR
            reviews = _forgejo_get(
                f"repos/{owner_repo}/pulls/{pr_num}/reviews"
            ) or []

            for rev in reviews:
                reviewer = (rev.get("user") or {}).get("login") or ""
                if bot_user and reviewer == bot_user:
                    continue  # skip bot's own reviews

                rev_state = rev.get("state") or ""
                rev_body = (rev.get("body") or "").strip()
                rev_id = rev.get("id")
                rev_date = (rev.get("submitted_at") or updated)[:10]

                # Review body as one entry (if non-empty)
                if rev_body:
                    text = (
                        f"PR {owner_repo}#{pr_num}: {pr_title}\n"
                        f"Review by {reviewer} ({rev_state}):\n\n{rev_body}"
                    )
                    eid = hashlib.sha256(
                        f"review:{owner_repo}:{pr_num}:{rev_id}".encode("utf-8")
                    ).hexdigest()[:16]
                    yield {
                        "key": f"igor:review:{eid}",
                        "text": text,
                        "source": "review",
                        "date": rev_date,
                        "timestamp": f"{owner_repo}#{pr_num} review by {reviewer}",
                        "repo": owner_repo,
                    }

                # Inline comments embedded in review.comments[]
                for c in (rev.get("comments") or []):
                    c_body = (c.get("body") or "").strip()
                    if not c_body:
                        continue
                    c_author = (c.get("user") or {}).get("login") or reviewer
                    if bot_user and c_author == bot_user:
                        continue
                    c_path = c.get("path") or ""
                    c_line = c.get("original_line") or c.get("line") or ""
                    c_id = c.get("id")
                    text = (
                        f"PR {owner_repo}#{pr_num}: {pr_title}\n"
                        f"Inline comment by {c_author} on `{c_path}`"
                        f"{f' line {c_line}' if c_line else ''}:\n\n{c_body}"
                    )
                    eid = hashlib.sha256(
                        f"review-inline:{owner_repo}:{pr_num}:{c_id}".encode("utf-8")
                    ).hexdigest()[:16]
                    yield {
                        "key": f"igor:review:{eid}",
                        "text": text,
                        "source": "review",
                        "date": rev_date,
                        "timestamp": f"{owner_repo}#{pr_num} inline by {c_author}",
                        "repo": owner_repo,
                    }


# -- embedding cache -----------------------------------------------------

def _open_cache():
    """Open (and create if needed) the sqlite embedding cache."""
    Path(CACHE_PATH).parent.mkdir(parents=True, exist_ok=True)
    conn = sqlite3.connect(CACHE_PATH)
    conn.execute(
        """
        CREATE TABLE IF NOT EXISTS embeddings (
            content_hash TEXT PRIMARY KEY,
            embedding BLOB NOT NULL,
            created_at TEXT NOT NULL
        )
        """
    )
    return conn


def _hash_text(text: str) -> str:
    """Cache key. Includes the model name so changing the embedder
    automatically invalidates the cache (old hashes become orphans
    that fall out of the lookup miss path)."""
    return hashlib.sha256(f"{EMBED_MODEL}|{text}".encode("utf-8")).hexdigest()


def embed_with_cache(texts: list, log_fn=None):
    """Embed texts, using the sqlite cache for previously-seen content.

    Returns a list of np.float32 arrays in the same order as input.
    Only texts whose (model, content) hash isn't already cached
    actually go through the embedder.
    """
    if not texts:
        return []

    hashes = [_hash_text(t) for t in texts]
    conn = _open_cache()

    cached: dict[str, np.ndarray] = {}
    # SQLite has a ~999 parameter limit by default; chunk the IN clause.
    chunk = 500
    for i in range(0, len(hashes), chunk):
        batch = hashes[i:i + chunk]
        placeholders = ",".join("?" * len(batch))
        rows = conn.execute(
            f"SELECT content_hash, embedding FROM embeddings WHERE content_hash IN ({placeholders})",
            batch,
        ).fetchall()
        for h, blob in rows:
            cached[h] = np.frombuffer(blob, dtype=np.float32)

    missing_indices = [i for i, h in enumerate(hashes) if h not in cached]
    if log_fn:
        log_fn(
            f"rag: cache hit {len(hashes) - len(missing_indices)}/{len(hashes)}, "
            f"need to embed {len(missing_indices)} new"
        )

    if missing_indices:
        missing_texts = [texts[i] for i in missing_indices]
        embedder = TextEmbedding(model_name=EMBED_MODEL)
        new_vectors = list(embedder.embed(missing_texts))
        now = datetime.now(timezone.utc).isoformat()
        to_insert = []
        for idx, vec in zip(missing_indices, new_vectors):
            arr = np.array(vec, dtype=np.float32)
            cached[hashes[idx]] = arr
            to_insert.append((hashes[idx], arr.tobytes(), now))
        conn.executemany(
            "INSERT OR REPLACE INTO embeddings (content_hash, embedding, created_at) VALUES (?, ?, ?)",
            to_insert,
        )
        conn.commit()

    conn.close()
    return [cached[h] for h in hashes]


# -- build + query --------------------------------------------------------

def build_index(brain_path: Path, repo_root: Path, days: int, quiet: bool = False):
    def log(msg):
        if not quiet:
            print(msg, file=sys.stderr)

    check_redis()

    # Flush before rebuild. The design is intentionally ephemeral:
    # source files on disk (journal, memories, git history) are the
    # source of truth; Redis is a derived cache that gets recomputed
    # from scratch every tick. Self-healing -- orphans from previous
    # shapes, model changes, or schema migrations disappear here.
    # Dedicated Redis instance (only Igor uses it), so FLUSHDB is safe.
    r = redis.from_url(REDIS_URL)
    pre_count = r.dbsize()
    r.flushdb()
    log(f"rag: flushed redis db ({pre_count} keys removed)")

    schema = IndexSchema.from_dict(SCHEMA)
    index = SearchIndex(schema, redis_url=REDIS_URL)
    index.create(overwrite=True)
    log(f"rag: created index {INDEX_NAME}")

    journal_rows = list(collect_journal_entries(brain_path))
    memory_rows = list(collect_memory_entries(brain_path))
    commit_rows = list(collect_commit_entries(repo_root, days))
    review_rows = list(collect_review_entries(repo_root, REVIEW_DAYS))
    all_rows = journal_rows + memory_rows + commit_rows + review_rows

    log(
        f"rag: collected {len(journal_rows)} journal + "
        f"{len(memory_rows)} memory + {len(commit_rows)} commit "
        f"(last {days}d) + {len(review_rows)} review "
        f"(last {REVIEW_DAYS}d) = {len(all_rows)} total"
    )

    if not all_rows:
        log("rag: no entries to embed")
        return 0

    texts = [row["text"] for row in all_rows]
    vectors = embed_with_cache(texts, log_fn=log)

    data = []
    keys = []
    for row, vec in zip(all_rows, vectors):
        data.append({
            "text": row["text"],
            "source": row["source"],
            "date": row["date"],
            "timestamp": row["timestamp"],
            "repo": row["repo"],
            "embedding": vec.tobytes(),
        })
        keys.append(row["key"])
    index.load(data, keys=keys)
    post_count = r.dbsize()
    log(f"rag: indexed {len(data)} entries (dbsize now {post_count})")
    return len(data)


def query_index(text: str, k: int = 5):
    check_redis()
    schema = IndexSchema.from_dict(SCHEMA)
    index = SearchIndex(schema, redis_url=REDIS_URL)
    if not index.exists():
        print("rag: index does not exist; run 'rag.py build' first", file=sys.stderr)
        sys.exit(2)

    embedder = TextEmbedding(model_name=EMBED_MODEL)
    qvec = np.array(next(iter(embedder.embed([text]))), dtype=np.float32)

    vq = VectorQuery(
        vector=qvec,
        vector_field_name="embedding",
        return_fields=["text", "source", "date", "timestamp", "repo"],
        num_results=k,
    )
    results = index.query(vq)
    for r in results:
        dist = r.get("vector_distance", "n/a")
        source = r.get("source", "?")
        ts = r.get("timestamp", "")
        date = r.get("date", "")
        repo = r.get("repo", "")
        body = r.get("text", "").strip()
        header_extra = f", repo: {repo}" if repo else ""
        print(f"## [{source}] {ts}")
        print(f"_date: {date}{header_extra}, distance: {dist}_")
        print()
        print(body)
        print()
        print("---")
        print()


def main():
    p = argparse.ArgumentParser(description="Igor's cross-tick RAG tool")
    p.add_argument("--brain", default=DEFAULT_BRAIN, help="path to brain repo")
    p.add_argument("--repo-root", default=DEFAULT_REPO_ROOT,
                   help="path under which bot-accessible repo clones live")
    p.add_argument("--commit-days", type=int, default=COMMIT_DAYS,
                   help="how many days of commit history to embed")
    sub = p.add_subparsers(dest="cmd", required=True)

    bp = sub.add_parser("build", help="rebuild the full RAG index")
    bp.add_argument("--quiet", action="store_true")

    qp = sub.add_parser("query", help="query for top-K relevant entries")
    qp.add_argument("text", help="query text")
    qp.add_argument("-k", "--top-k", type=int, default=5)

    args = p.parse_args()
    if args.cmd == "build":
        build_index(
            Path(args.brain),
            Path(args.repo_root),
            args.commit_days,
            quiet=args.quiet,
        )
    elif args.cmd == "query":
        query_index(args.text, k=args.top_k)


if __name__ == "__main__":
    main()
