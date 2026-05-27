#!/usr/bin/env python3
"""reading-pipeline.py -- the new reading-and-maybe-post executor.

Replaces bin/discretionary-read.sh (1161 lines) and
bin/discretionary-post.sh. Self-contained: stdlib + Anthropic
HTTP API + Forgejo HTTP API + git subprocess.

Per tick:
  1. For each of the 4 source-slate URLs (Josh blog, Jen blog,
     HN, Kagi Small Web), in that order, pick one URL the agent
     hasn't read yet, fetch it, draft a reflection, write to the
     reflections table, mark the URL read in seen_urls.
  2. After the read cycle, ask Haiku whether the recent
     reflections cluster into post-shaped material. If yes AND
     no open post PR on the bot's website repo, draft a post
     with Sonnet, write to src/posts/YYYY/<slug>.md in the
     website worktree, commit + push + open PR.
  3. Empty slot? Skip. Don't force-fill. A 3-read tick is fine.
     If all 4 sources came up empty, exit clean.

Phase 2 of the refactor (~/Notes/igor-refactor-plan.md). The
pipeline is STANDALONE -- not wired into tick.sh yet. Phase 4
does the wire-in. Until then, you can run it manually:

  bin/reading-pipeline.py \\
    --brain-db ~/.local/state/agent/brain.sqlite \\
    --website-path ~/.local/state/agent/repos/igor/website \\
    --dry-run

Default mode is `--dry-run`: fetches, drafts reflections, writes
to sqlite, evaluates the post decision -- but does NOT push or
open a PR. Pass `--live` to actually push and open.

Env required:
  ANTHROPIC_API_KEY -- for the reflection + post drafting calls
  FORGEJO_URL       -- e.g. https://git.sherver.org
  FORGEJO_TOKEN     -- for PR open
  BOT_USER          -- e.g. igor (the bot's Forgejo username)

Env optional:
  AGENT_MODEL          -- default claude-sonnet-4-6 (used for reflections + post body)
  AGENT_MODEL_THINKING -- default claude-haiku-4-5-20251001 (used for the post-shape decision)
  AGENT_STATE_DIR      -- default ~/.local/state/agent (used for cost ledger + default db)
  AGENT_HOME           -- default <script-parent-dir> (used for voice anchor location)
  WEBSITE_REPO         -- default $BOT_USER/website (Forgejo repo path for PR open)
"""

from __future__ import annotations

import argparse
import json
import os
import random
import re
import sqlite3
import subprocess
import sys
import urllib.error
import urllib.request
import xml.etree.ElementTree as ET
from datetime import datetime, timedelta, timezone
from pathlib import Path
from urllib.parse import urlparse


# -- constants ---------------------------------------------------

SLATE = [
    ("https://joshtronic.com",       "personal_newest"),
    ("https://thatgirljen.com",      "personal_random"),
    ("https://news.ycombinator.com", "hn_top"),
    ("https://kagi.com/smallweb",    "kagi_redirect"),
]
MAX_READS_PER_TICK = 4
REFLECTION_LOOKBACK_DAYS = 14
POST_TRIGGER_MIN_REFLECTIONS = 3  # need at least this many recent reflections to consider a post

DEFAULT_MODEL = "claude-sonnet-4-6"
DEFAULT_THINKING_MODEL = "claude-haiku-4-5-20251001"

UA = "Mozilla/5.0 (compatible; agent/reading-pipeline)"
FETCH_TIMEOUT = 30
FETCH_MAX_BYTES = 5_000_000  # 5 MB cap
HTML_TRUNCATE_BYTES = 200_000  # what we send to the model

# Date-in-URL pattern: /YYYY/MM/DD/ slug -- joshtronic.com and
# thatgirljen.com both use this shape.
DATE_IN_URL_RE = re.compile(r"/(\d{4})/(\d{2})/(\d{2})/")


def log(msg: str) -> None:
    print(f"reading-pipeline: {msg}", file=sys.stderr)


# -- env + setup -------------------------------------------------

def require_env(name: str) -> str:
    v = os.environ.get(name)
    if not v:
        log(f"required env var not set: {name}")
        sys.exit(2)
    return v


def default_paths() -> dict:
    home = os.environ.get("AGENT_HOME") or str(Path(__file__).resolve().parent.parent)
    state = os.environ.get("AGENT_STATE_DIR") or str(Path.home() / ".local" / "state" / "agent")
    bot = os.environ.get("BOT_USER") or "igor"
    return {
        "home": Path(home),
        "state": Path(state),
        "default_db": Path(state) / "brain.sqlite",
        "default_website": Path(state) / "repos" / bot / "website",
        "voice_anchor": Path(home) / "bin" / "lib" / "voice.txt",
        "bot_user": bot,
    }


# -- cost ledger -------------------------------------------------
# Mirrors bin/agent-reflect-ideas.py's record_cost helper. Stash
# token counts only; cost-report.sh computes USD from a price
# table (single source of truth).

def record_cost(call_site: str, model: str, response: dict, state_dir: Path) -> None:
    try:
        ledger = state_dir / "cost-ledger.jsonl"
        usage = response.get("usage") or {}
        input_t = int(usage.get("input_tokens", 0))
        output_t = int(usage.get("output_tokens", 0))
        cc = int(usage.get("cache_creation_input_tokens", 0))
        cr = int(usage.get("cache_read_input_tokens", 0))
        if input_t == 0 and output_t == 0:
            return
        line = {
            "timestamp": datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
            "tick_pid": os.environ.get("TICK_PID", str(os.getpid())),
            "call_site": call_site,
            "model": model,
            "input_tokens": input_t,
            "output_tokens": output_t,
            "cache_creation_input_tokens": cc,
            "cache_read_input_tokens": cr,
            "source": "api",
        }
        ledger.parent.mkdir(parents=True, exist_ok=True)
        with open(ledger, "a") as f:
            f.write(json.dumps(line) + "\n")
    except Exception:
        pass


# -- HTTP helpers ------------------------------------------------

def http_get(url: str, *, headers: dict | None = None,
             allow_redirects: bool = True,
             timeout: int = FETCH_TIMEOUT) -> tuple[str, bytes]:
    """Fetch URL. Returns (final_url, body_bytes). Caller decodes."""
    req = urllib.request.Request(url, headers=headers or {"User-Agent": UA})
    opener = urllib.request.build_opener()
    if not allow_redirects:
        class NoRedirect(urllib.request.HTTPRedirectHandler):
            def redirect_request(self, *a, **kw): return None
        opener = urllib.request.build_opener(NoRedirect())
    with opener.open(req, timeout=timeout) as resp:
        body = resp.read(FETCH_MAX_BYTES + 1)
        return resp.url, body


def fetch_text(url: str) -> str:
    try:
        _, body = http_get(url)
        if len(body) > FETCH_MAX_BYTES:
            log(f"fetch oversize, skipping: {url}")
            return ""
        return body.decode("utf-8", errors="replace")
    except (urllib.error.URLError, urllib.error.HTTPError, TimeoutError) as e:
        log(f"fetch failed for {url}: {e}")
        return ""


def follow_redirect(url: str) -> str:
    """GET the URL, return the final URL after redirects."""
    try:
        final, _ = http_get(url)
        return final or url
    except (urllib.error.URLError, urllib.error.HTTPError, TimeoutError) as e:
        log(f"redirect-follow failed for {url}: {e}")
        return ""


# -- Anthropic API -----------------------------------------------

def anthropic_call(api_key: str, model: str, system: str,
                   user: str, max_tokens: int,
                   call_site: str, state_dir: Path) -> str | None:
    payload = {
        "model": model,
        "max_tokens": max_tokens,
        "system": system,
        "messages": [{"role": "user", "content": user}],
    }
    req = urllib.request.Request(
        "https://api.anthropic.com/v1/messages",
        data=json.dumps(payload).encode("utf-8"),
        headers={
            "x-api-key": api_key,
            "anthropic-version": "2023-06-01",
            "content-type": "application/json",
        },
        method="POST",
    )
    try:
        with urllib.request.urlopen(req, timeout=120) as resp:
            body = json.loads(resp.read().decode("utf-8"))
    except (urllib.error.URLError, urllib.error.HTTPError, TimeoutError) as e:
        log(f"anthropic call failed ({call_site}): {e}")
        return None
    except json.JSONDecodeError as e:
        log(f"anthropic response not JSON ({call_site}): {e}")
        return None
    record_cost(call_site, model, body, state_dir)
    try:
        return body["content"][0]["text"]
    except (KeyError, IndexError, TypeError):
        log(f"anthropic response missing content ({call_site})")
        return None


# -- sqlite helpers ----------------------------------------------

def db_connect(db_path: Path) -> sqlite3.Connection:
    if not db_path.is_file():
        log(f"brain db not found: {db_path}. Run bin/migrate-brain-to-sqlite.py first.")
        sys.exit(2)
    con = sqlite3.connect(db_path)
    con.row_factory = sqlite3.Row
    return con


def is_read(con: sqlite3.Connection, url: str) -> bool:
    row = con.execute(
        "SELECT 1 FROM seen_urls WHERE url = ? AND read_at IS NOT NULL",
        (url,),
    ).fetchone()
    return row is not None


def mark_read(con: sqlite3.Connection, url: str, source: str, today: str) -> None:
    domain = urlparse(url).netloc or ""
    con.execute(
        "INSERT INTO seen_urls (url, source, domain, first_seen, read_at) "
        "VALUES (?, ?, ?, ?, ?) "
        "ON CONFLICT(url) DO UPDATE SET "
        "  read_at = COALESCE(seen_urls.read_at, excluded.read_at), "
        "  source  = COALESCE(seen_urls.source,  excluded.source)",
        (url, source, domain, today, today),
    )
    con.commit()


def insert_reflection(con: sqlite3.Connection, ts: str, content: str,
                      source_url: str | None) -> int:
    cur = con.execute(
        "INSERT INTO reflections (ts, content, source_url) VALUES (?, ?, ?)",
        (ts, content, source_url),
    )
    con.commit()
    return cur.lastrowid


def recent_reflections(con: sqlite3.Connection, days: int) -> list[sqlite3.Row]:
    # Cutoff matches the stored timestamp format -- local time with
    # numeric offset (`YYYY-MM-DDTHH:MM:SS+HHMM`). Lexicographic
    # comparison works as long as both sides use the same TZ
    # offset, which holds since the journal+pipeline both use the
    # host's local TZ.
    cutoff = (datetime.now().astimezone()
              - timedelta(days=days)).strftime("%Y-%m-%dT%H:%M:%S%z")
    return list(con.execute(
        "SELECT id, ts, content, source_url, post_drafted "
        "FROM reflections WHERE ts >= ? ORDER BY ts DESC",
        (cutoff,),
    ).fetchall())


def mark_reflections_drafted(con: sqlite3.Connection, ids: list[int]) -> None:
    if not ids:
        return
    qs = ",".join("?" * len(ids))
    con.execute(f"UPDATE reflections SET post_drafted = 1 WHERE id IN ({qs})", ids)
    con.commit()


# -- per-source URL pickers --------------------------------------

def url_date(url: str) -> str | None:
    m = DATE_IN_URL_RE.search(url)
    if not m:
        return None
    return f"{m.group(1)}-{m.group(2)}-{m.group(3)}"


def pick_personal(con: sqlite3.Connection, source_url: str,
                  *, newest: bool) -> str | None:
    """Pick an unread URL from a personal blog (one whose own URLs
    are the candidate pool). `newest` = sort by url-extracted date
    desc and pick top; else random."""
    domain = urlparse(source_url).netloc
    rows = con.execute(
        "SELECT url FROM seen_urls "
        "WHERE domain = ? AND read_at IS NULL AND url LIKE ?",
        (domain, f"%{domain}%"),
    ).fetchall()
    candidates = [r["url"] for r in rows if url_date(r["url"])]
    if not candidates:
        return None
    if newest:
        candidates.sort(key=lambda u: url_date(u) or "", reverse=True)
        return candidates[0]
    return random.choice(candidates)


def pick_hn(con: sqlite3.Connection) -> str | None:
    """Top unread URL from HN RSS."""
    rss = fetch_text("https://news.ycombinator.com/rss")
    if not rss:
        return None
    try:
        root = ET.fromstring(rss)
    except ET.ParseError as e:
        log(f"HN RSS parse failed: {e}")
        return None
    for item in root.iter("item"):
        link = item.findtext("link", default="").strip()
        if not link or link.startswith("https://news.ycombinator.com/"):
            continue
        if not is_read(con, link):
            return link
    return None


def pick_kagi(con: sqlite3.Connection) -> str | None:
    """Whatever Kagi Small Web redirects to. If we've already
    read that URL, give up (no retry -- empty slot is fine)."""
    final = follow_redirect("https://kagi.com/smallweb")
    if not final or final.startswith("https://kagi.com/"):
        return None
    if is_read(con, final):
        return None
    return final


def pick_url_for_source(con: sqlite3.Connection,
                        source_url: str, picker: str) -> str | None:
    if picker == "personal_newest":
        return pick_personal(con, source_url, newest=True)
    if picker == "personal_random":
        return pick_personal(con, source_url, newest=False)
    if picker == "hn_top":
        return pick_hn(con)
    if picker == "kagi_redirect":
        return pick_kagi(con)
    log(f"unknown picker: {picker}")
    return None


# -- fetch + reflect (single URL) --------------------------------

def reflect_on_url(api_key: str, model: str, state_dir: Path,
                   voice_anchor: str, url: str) -> dict | None:
    """Fetch the URL, ask the model for {title, journal}.
    Returns the parsed dict or None on any failure."""
    html = fetch_text(url)
    if not html:
        return None
    html_trunc = html[:HTML_TRUNCATE_BYTES]

    system = (
        f"{voice_anchor.strip()}\n\n"
        "---\n\n"
        "You are doing a discretionary reading tick. You'll receive the "
        "HTML of a web page (likely a blog post or article). Your job:\n\n"
        "1. Identify the article's actual title (often in <title>, an h1, "
        "or near the top of the content).\n"
        "2. Read the substantive content. Skip navigation, footers, ads, "
        "cookie banners.\n"
        "3. Write a first-person journal entry about what struck you. One "
        "to two paragraphs. ~150-300 words. Your own voice -- terse, "
        "grounded.\n"
        "4. If the page is mostly chrome (no real article, paywall, error, "
        "etc.), note that briefly and move on.\n\n"
        "Output STRICT JSON. No surrounding prose. No code fences. Just:\n\n"
        '{\n  "title": "the article title as I\'d cite it",\n'
        '  "journal": "the journal entry in markdown, first person"\n}'
    )
    user = f"URL: {url}\n\nHTML content:\n\n{html_trunc}"
    raw = anthropic_call(api_key, model, system, user,
                         max_tokens=1500, call_site="reading-pipeline-reflect",
                         state_dir=state_dir)
    if raw is None:
        return None
    # Strip code fences if present.
    text = re.sub(r"^```[a-zA-Z]*\n?|\n?```$", "", raw.strip())
    try:
        parsed = json.loads(text)
    except json.JSONDecodeError as e:
        log(f"reflection JSON parse failed for {url}: {e}; raw: {text[:200]}")
        return None
    if not parsed.get("title") or not parsed.get("journal"):
        log(f"reflection missing title or journal for {url}")
        return None
    return parsed


# -- post-shape decision -----------------------------------------

def decide_post(api_key: str, thinking_model: str, state_dir: Path,
                voice_anchor: str, reflections: list[sqlite3.Row]) -> dict | None:
    """Ask Haiku: do these reflections cluster into post-shaped
    material? Return {post_shaped: bool, reason: str, slug?: str,
    angle?: str}."""
    if len(reflections) < POST_TRIGGER_MIN_REFLECTIONS:
        return {"post_shaped": False,
                "reason": f"only {len(reflections)} recent reflection(s); below threshold"}
    bundle_parts = []
    for r in reflections[:20]:
        bundle_parts.append(f"## {r['ts']}\n\n{r['content']}")
    bundle = "\n\n---\n\n".join(bundle_parts)

    system = (
        f"{voice_anchor.strip()}\n\n"
        "---\n\n"
        "Decide whether the recent reading reflections cluster into "
        "post-shaped material. A post is shaped when:\n"
        "- A theme has shown up across 2+ reflections in different framings.\n"
        "- The agent has its own angle worth writing down, not a rehash.\n"
        "- The cluster is sharp enough to ship in one tick (600-900 words).\n\n"
        "Reject when:\n"
        "- Single-source observation with no echo.\n"
        "- Too vague to commit to one claim.\n"
        "- Recent post on roughly the same idea (assume drafts can dedupe at write time).\n\n"
        "Output STRICT JSON. No code fences. Schema:\n\n"
        '{\n'
        '  "post_shaped": true|false,\n'
        '  "reason": "one short sentence",\n'
        '  "slug": "post-slug-only-if-true",\n'
        '  "angle": "one-sentence claim the post would make, only if true"\n'
        '}'
    )
    user = f"Recent reflections (newest first):\n\n{bundle}"
    raw = anthropic_call(api_key, thinking_model, system, user,
                         max_tokens=400, call_site="reading-pipeline-postgate",
                         state_dir=state_dir)
    if raw is None:
        return None
    text = re.sub(r"^```[a-zA-Z]*\n?|\n?```$", "", raw.strip())
    try:
        return json.loads(text)
    except json.JSONDecodeError as e:
        log(f"post-decision JSON parse failed: {e}; raw: {text[:300]}")
        return None


# -- forgejo helpers ---------------------------------------------

def forgejo_get(token: str, base_url: str, path: str,
                timeout: int = 30) -> dict | list | None:
    req = urllib.request.Request(
        f"{base_url.rstrip('/')}{path}",
        headers={"Authorization": f"token {token}",
                 "Accept": "application/json"},
    )
    try:
        with urllib.request.urlopen(req, timeout=timeout) as resp:
            return json.loads(resp.read().decode("utf-8"))
    except (urllib.error.URLError, urllib.error.HTTPError, TimeoutError) as e:
        log(f"forgejo GET {path} failed: {e}")
        return None


def forgejo_post(token: str, base_url: str, path: str,
                 payload: dict, timeout: int = 30) -> dict | None:
    req = urllib.request.Request(
        f"{base_url.rstrip('/')}{path}",
        data=json.dumps(payload).encode("utf-8"),
        headers={"Authorization": f"token {token}",
                 "Accept": "application/json",
                 "Content-Type": "application/json"},
        method="POST",
    )
    try:
        with urllib.request.urlopen(req, timeout=timeout) as resp:
            return json.loads(resp.read().decode("utf-8"))
    except (urllib.error.URLError, urllib.error.HTTPError, TimeoutError) as e:
        log(f"forgejo POST {path} failed: {e}")
        return None


def open_post_pr_exists(token: str, base_url: str, repo: str,
                         bot_user: str) -> bool:
    """Is there an open bot-authored PR on `repo` that adds a file
    under src/posts/? Best-effort: if the check itself fails, err
    on the side of NOT drafting another post (return True)."""
    prs = forgejo_get(token, base_url,
                      f"/api/v1/repos/{repo}/pulls?state=open&limit=50")
    if prs is None:
        log("forgejo PR list failed -- assuming a post is in flight to be safe")
        return True
    for pr in prs:
        user = (pr.get("user") or {}).get("login", "")
        if user != bot_user:
            continue
        num = pr.get("number")
        if not num:
            continue
        files = forgejo_get(token, base_url,
                            f"/api/v1/repos/{repo}/pulls/{num}/files")
        if files is None:
            continue
        for f in files:
            fn = f.get("filename", "")
            if fn.startswith("src/posts/"):
                return True
    return False


# -- post drafting -----------------------------------------------

def draft_post(api_key: str, model: str, state_dir: Path,
               voice_anchor: str, reflections: list[sqlite3.Row],
               angle: str, slug: str) -> dict | None:
    """Draft a post. Returns {title, description, body, tags}.
    Body is markdown, no frontmatter (caller adds it)."""
    bundle_parts = []
    for r in reflections[:20]:
        bundle_parts.append(f"## {r['ts']}\n\n{r['content']}")
    bundle = "\n\n---\n\n".join(bundle_parts)

    system = (
        f"{voice_anchor.strip()}\n\n"
        "---\n\n"
        "Draft a blog post for igor.bot. Source material: the recent "
        "reading reflections below. The post's one claim is the `angle` "
        "given.\n\n"
        "Rules:\n"
        "- Length 600-900 words; hard cap 1,200.\n"
        "- Lede 1-2 sentences; no \"in today's world\" intros.\n"
        "- One claim per post -- the given angle.\n"
        "- Short paragraphs (2-4 sentences). H2 sparingly.\n"
        "- First person. No fabricated quotes, no fake numbers, no false "
        "certainty. If you don't have a fact, leave it out.\n"
        "- Link any specific source you reference -- inline markdown link.\n"
        "- Closer: one line. No \"thanks for reading.\"\n"
        "- Don't put a `# Title` heading at the top of the body. The layout "
        "renders the frontmatter `title` as the page's h1.\n\n"
        "Output STRICT JSON. No code fences. Schema:\n\n"
        '{\n'
        '  "title": "post title (used as frontmatter title + the page h1)",\n'
        '  "description": "<= 155 chars (meta description)",\n'
        '  "body": "markdown body, no frontmatter, no leading h1",\n'
        '  "tags": ["zero", "to", "three", "lowercase"]\n'
        '}'
    )
    user = (
        f"Angle (post's one claim):\n{angle}\n\n"
        f"Proposed slug: {slug}\n\n"
        f"Recent reading reflections (newest first):\n\n{bundle}"
    )
    raw = anthropic_call(api_key, model, system, user,
                         max_tokens=4000, call_site="reading-pipeline-postbody",
                         state_dir=state_dir)
    if raw is None:
        return None
    text = re.sub(r"^```[a-zA-Z]*\n?|\n?```$", "", raw.strip())
    try:
        parsed = json.loads(text)
    except json.JSONDecodeError as e:
        log(f"post-body JSON parse failed: {e}; raw: {text[:300]}")
        return None
    if not parsed.get("title") or not parsed.get("body"):
        log("post-body missing title or body")
        return None
    return parsed


# -- git ops -----------------------------------------------------

def run(cmd: list[str], cwd: Path | None = None,
        check: bool = True) -> subprocess.CompletedProcess:
    return subprocess.run(cmd, cwd=cwd, check=check,
                          capture_output=True, text=True)


def write_post_file(website_path: Path, slug: str, post: dict,
                    when: datetime) -> Path:
    ymd = when.strftime("%Y-%m-%d")
    year = when.strftime("%Y")
    iso = when.strftime("%Y-%m-%dT%H:%M:%S%z") or when.isoformat()
    post_dir = website_path / "src" / "posts" / year
    post_dir.mkdir(parents=True, exist_ok=True)
    post_file = post_dir / f"{ymd}-{slug}.md"
    tags_yaml = "[" + ", ".join(f'"{t}"' for t in (post.get("tags") or [])) + "]"
    desc = (post.get("description") or "").replace('"', '\\"')
    title = (post.get("title") or "").replace('"', '\\"')
    body = post.get("body") or ""
    # Sanitize em/en dashes to double-hyphen (matches existing pattern).
    body = body.replace("–", "--").replace("—", "--")
    with open(post_file, "w", encoding="utf-8") as f:
        f.write("---\n")
        f.write(f'title: "{title}"\n')
        f.write(f'description: "{desc}"\n')
        f.write(f"date: {iso}\n")
        f.write(f"tags: {tags_yaml}\n")
        f.write("---\n\n")
        f.write(body.rstrip() + "\n")
    return post_file


def commit_and_push(website_path: Path, branch: str, post_file: Path,
                    commit_subject: str) -> None:
    run(["git", "fetch", "origin", "--prune"], cwd=website_path)
    run(["git", "checkout", "-B", branch, "origin/master"], cwd=website_path)
    run(["git", "add", str(post_file.relative_to(website_path))],
        cwd=website_path)
    run(["git", "commit", "-m", commit_subject], cwd=website_path)
    run(["git", "push", "-u", "origin", branch], cwd=website_path)


# -- main --------------------------------------------------------

def main() -> int:
    paths = default_paths()

    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("--brain-db", default=str(paths["default_db"]))
    ap.add_argument("--website-path", default=str(paths["default_website"]))
    ap.add_argument("--voice-anchor", default=str(paths["voice_anchor"]))
    ap.add_argument("--live", action="store_true",
                    help="actually push + open PR. Default is dry-run.")
    args = ap.parse_args()

    db_path = Path(args.brain_db).expanduser()
    website_path = Path(args.website_path).expanduser()
    voice_path = Path(args.voice_anchor).expanduser()

    api_key = require_env("ANTHROPIC_API_KEY")
    forgejo_url = os.environ.get("FORGEJO_URL", "")
    forgejo_token = os.environ.get("FORGEJO_TOKEN", "")
    bot_user = os.environ.get("BOT_USER") or paths["bot_user"]
    website_repo = os.environ.get("WEBSITE_REPO", f"{bot_user}/website")

    model = os.environ.get("AGENT_MODEL", DEFAULT_MODEL)
    thinking_model = os.environ.get("AGENT_MODEL_THINKING", DEFAULT_THINKING_MODEL)

    if not voice_path.is_file():
        log(f"voice anchor not found: {voice_path}")
        return 2
    voice_anchor = voice_path.read_text(encoding="utf-8")

    con = db_connect(db_path)
    today = datetime.now(timezone.utc).strftime("%Y-%m-%d")
    now_iso = datetime.now().astimezone().strftime("%Y-%m-%dT%H:%M:%S%z")

    mode = "LIVE" if args.live else "dry-run"
    log(f"start ({mode}); db={db_path}; website={website_path}")

    # -- read cycle ---------------------------------------------
    new_reflection_ids: list[int] = []
    successful_reads = 0
    for source_url, picker in SLATE:
        log(f"source: {source_url} ({picker})")
        url = pick_url_for_source(con, source_url, picker)
        if not url:
            log(f"  no candidate -- skipping slot")
            continue
        log(f"  picked: {url}")
        result = reflect_on_url(api_key, model, paths["state"], voice_anchor, url)
        if result is None:
            log(f"  reflection failed -- skipping slot")
            continue
        rid = insert_reflection(con, now_iso, result["journal"], url)
        mark_read(con, url, source_url, today)
        new_reflection_ids.append(rid)
        successful_reads += 1
        log(f"  reflected (reflection id={rid}, title={result['title'][:60]!r})")
        if successful_reads >= MAX_READS_PER_TICK:
            break

    log(f"read cycle done: {successful_reads}/{MAX_READS_PER_TICK} successful")

    # -- post-shape decision -----------------------------------
    reflections = recent_reflections(con, REFLECTION_LOOKBACK_DAYS)
    log(f"recent reflections (last {REFLECTION_LOOKBACK_DAYS}d): {len(reflections)}")

    if not new_reflection_ids:
        log("no new reflections this tick -- skipping post decision")
        con.close()
        return 0

    if forgejo_url and forgejo_token:
        pr_in_flight = open_post_pr_exists(forgejo_token, forgejo_url,
                                            website_repo, bot_user)
    else:
        pr_in_flight = True  # be safe if we can't check
        log("forgejo creds missing -- assuming a post is in flight (won't draft)")
    log(f"post PR in flight on {website_repo}: {pr_in_flight}")

    if pr_in_flight:
        log("done -- post slot occupied, no decision needed")
        con.close()
        return 0

    decision = decide_post(api_key, thinking_model, paths["state"],
                           voice_anchor, reflections)
    if decision is None:
        log("post decision call failed -- exiting clean")
        con.close()
        return 0

    log(f"post decision: shaped={decision.get('post_shaped')} "
        f"reason={decision.get('reason')!r}")
    if not decision.get("post_shaped"):
        con.close()
        return 0

    slug = (decision.get("slug") or "").strip().strip("/")
    angle = (decision.get("angle") or "").strip()
    if not slug or not angle:
        log("post-shaped but slug or angle missing -- skipping")
        con.close()
        return 0

    # -- draft + write + push + PR ------------------------------
    log(f"drafting post (slug={slug!r}, angle={angle[:80]!r})")
    post = draft_post(api_key, model, paths["state"], voice_anchor,
                       reflections, angle, slug)
    if post is None:
        log("post drafting failed")
        con.close()
        return 0

    when = datetime.now().astimezone()
    if not args.live:
        log("DRY-RUN: would write post + push + open PR. "
            f"Title: {post['title']!r}, slug: {slug}, body length: "
            f"{len(post.get('body') or '')} chars.")
        con.close()
        return 0

    if not website_path.is_dir():
        log(f"website worktree not found at {website_path}; cannot push")
        con.close()
        return 0

    branch = f"agent/reading-pipeline-{when.strftime('%Y%m%d-%H%M%S')}"
    post_file = write_post_file(website_path, slug, post, when)
    log(f"wrote {post_file}")
    try:
        commit_and_push(website_path, branch, post_file,
                        f"feat: add post '{post['title']}'")
    except subprocess.CalledProcessError as e:
        log(f"git push failed: {e.stderr or e.stdout}")
        con.close()
        return 1

    pr_body = (
        f"From the new reading-pipeline (Phase 2 of the refactor).\n\n"
        f"Drafted from {len(reflections)} recent reflection(s) under the "
        f"angle: {angle}\n"
    )
    pr = forgejo_post(forgejo_token, forgejo_url,
                      f"/api/v1/repos/{website_repo}/pulls",
                      {"title": f"feat: add post '{post['title']}'",
                       "body": pr_body,
                       "head": branch,
                       "base": "master"})
    if pr is None:
        log("forgejo PR open failed; branch is pushed -- check manually")
        con.close()
        return 1
    log(f"PR opened: #{pr.get('number')} {pr.get('html_url', '')}")
    mark_reflections_drafted(con, [r["id"] for r in reflections
                                    if r["post_drafted"] == 0])

    con.close()
    return 0


if __name__ == "__main__":
    sys.exit(main())
