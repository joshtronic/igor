#!/usr/bin/env python3
"""rag.py -- build or query Igor's journal RAG index.

Subcommands:
    build           Rebuild the index from brain/journal/.
    query <text>    Find top-K relevant journal entries for <text>.

Both commands require Redis Stack (Redis + RediSearch module) at
$REDIS_URL (default redis://localhost:6379), and the venv set up
by bin/setup-rag.sh.

Designed to be called by tick.sh. Failures should not break ticks:
the wrapper should run with `set +e` and fall back to no-RAG mode
on non-zero exit.
"""

import argparse
import hashlib
import os
import re
import sys
from pathlib import Path

import numpy as np
import redis
from fastembed import TextEmbedding
from redisvl.index import SearchIndex
from redisvl.query import VectorQuery
from redisvl.schema import IndexSchema

EMBED_MODEL = "BAAI/bge-small-en-v1.5"
EMBED_DIMS = 384
INDEX_NAME = "igor-journal"
DEFAULT_BRAIN = os.environ.get("IGOR_BRAIN_PATH") or os.path.expanduser(
    "~/.local/state/igor/repos/igor/brain"
)
REDIS_URL = os.environ.get("REDIS_URL", "redis://localhost:6379")

SCHEMA = {
    "index": {
        "name": INDEX_NAME,
        "prefix": "journal:",
        "storage_type": "hash",
    },
    "fields": [
        {"name": "text", "type": "text"},
        {"name": "date", "type": "tag"},
        {"name": "timestamp", "type": "tag"},
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
    """Bail with a clear message if Redis or RediSearch isn't available."""
    try:
        r = redis.from_url(REDIS_URL, socket_connect_timeout=2)
        r.ping()
    except redis.exceptions.ConnectionError as e:
        print(f"rag: cannot connect to Redis at {REDIS_URL}: {e}", file=sys.stderr)
        sys.exit(3)
    # Check for RediSearch module
    modules = r.execute_command("MODULE", "LIST")
    have_search = any(
        (b"search" in mod or b"SEARCH" in mod)
        if isinstance(mod, (bytes, list))
        else False
        for mod in modules
    )
    # Module list comes back as flat list of [name, "search", ver, 1, ...] pairs;
    # be permissive in the check
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
            "rag: RediSearch module not loaded. Install redis-stack-server "
            "(includes RediSearch) instead of vanilla redis-server. See "
            "https://redis.io/docs/latest/operate/oss_and_stack/install/",
            file=sys.stderr,
        )
        sys.exit(4)


def parse_journal(path: Path):
    """Split a journal file into entries. Yields (header, body) tuples."""
    content = path.read_text(encoding="utf-8")
    parts = re.split(r"(?m)^## ", content)
    for part in parts[1:]:
        lines = part.split("\n", 1)
        header = lines[0].strip()
        body = lines[1].strip() if len(lines) > 1 else ""
        if not body:
            continue
        yield header, body


def collect_entries(brain_path: Path):
    """Yield (id, date, header, full_text) per journal entry."""
    journal_dir = brain_path / "journal"
    if not journal_dir.is_dir():
        return
    for jf in sorted(journal_dir.glob("*.md")):
        date_str = jf.stem  # YYYY-MM-DD
        for header, body in parse_journal(jf):
            text = f"{header}\n\n{body}".strip()
            eid = hashlib.sha256(
                f"{jf.name}:{header}".encode("utf-8")
            ).hexdigest()[:16]
            yield eid, date_str, header, text


def build_index(brain_path: Path, quiet: bool = False):
    def log(msg):
        if not quiet:
            print(msg, file=sys.stderr)

    check_redis()

    schema = IndexSchema.from_dict(SCHEMA)
    index = SearchIndex(schema, redis_url=REDIS_URL)
    index.create(overwrite=True, drop=True)
    log(f"rag: created index {INDEX_NAME}")

    entries = list(collect_entries(brain_path))
    if not entries:
        log("rag: no journal entries found")
        return 0

    log(f"rag: embedding {len(entries)} entries with {EMBED_MODEL}")
    embedder = TextEmbedding(model_name=EMBED_MODEL)
    texts = [e[3] for e in entries]
    vectors = [np.array(v, dtype=np.float32) for v in embedder.embed(texts)]

    rows = [
        {
            "text": text,
            "date": date,
            "timestamp": header,
            "embedding": vec.tobytes(),
        }
        for (eid, date, header, text), vec in zip(entries, vectors)
    ]
    keys = [f"journal:{e[0]}" for e in entries]
    index.load(rows, keys=keys)
    log(f"rag: indexed {len(rows)} entries")
    return len(rows)


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
        return_fields=["text", "date", "timestamp"],
        num_results=k,
    )
    results = index.query(vq)
    for r in results:
        dist = r.get("vector_distance", "n/a")
        ts = r.get("timestamp", "")
        date = r.get("date", "")
        body = r.get("text", "").strip()
        print(f"## {ts}")
        print(f"_date: {date}, distance: {dist}_")
        print()
        print(body)
        print()
        print("---")
        print()


def main():
    p = argparse.ArgumentParser(description="Igor's journal RAG tool")
    p.add_argument("--brain", default=DEFAULT_BRAIN, help="path to brain repo")
    sub = p.add_subparsers(dest="cmd", required=True)

    bp = sub.add_parser("build", help="rebuild the journal index")
    bp.add_argument("--quiet", action="store_true")

    qp = sub.add_parser("query", help="query for top-K relevant entries")
    qp.add_argument("text", help="query text")
    qp.add_argument("-k", "--top-k", type=int, default=5)

    args = p.parse_args()
    if args.cmd == "build":
        build_index(Path(args.brain), quiet=args.quiet)
    elif args.cmd == "query":
        query_index(args.text, k=args.top_k)


if __name__ == "__main__":
    main()
