#!/usr/bin/env python3
"""
agent-reflect-ideas.py -- post-discretionary-tick reflection on
the blog-ideas thought stack.

Called after any successful discretionary tick (reading, post,
site-work). Reads the context file (what just happened, usually
the journal entry the tick produced) and the brain's blog-ideas
list, then asks Haiku whether the just-finished work shifts the
priority of any ideas. Output is a small list of "move idea N
up" or "move idea N down" actions, bounded to a few per
reflection.

The picker (discretionary-post.sh) takes the top idea, so each
"move up" surfaces the idea sooner. Each "move down" buries it
slightly. Newly-relevant ideas float; stale ideas sink.

Bounded by design: at most MAX_MOVES per reflection, at most 1
slot each, never moves an idea past the section boundaries.
Reflection failure is non-fatal -- the tick already succeeded;
this is rebalancing on top, not a hard dep.

Usage:
    agent-reflect-ideas.py <context-file> <ideas-file>
"""

from __future__ import annotations

import json
import os
import re
import subprocess
import sys
import urllib.error
import urllib.request
from datetime import datetime, timezone

MAX_MOVES = 3
SECTION_OPEN = "## Open ideas"
DEFAULT_MODEL = "claude-haiku-4-5-20251001"

# Per-million-token pricing (USD). Mirrored from lib/cost.sh -- keep
# in sync. Unknown models fall through to zero (tokens still logged,
# missing $ shows up loud in cost-report).
_PRICES = {
    "claude-sonnet-4-6": {"input": 3.00, "output": 15.00, "cache_create": 3.75, "cache_read": 0.30},
    "claude-opus-4-7":   {"input": 15.00, "output": 75.00, "cache_create": 18.75, "cache_read": 1.50},
    "claude-haiku-4-5":  {"input": 1.00, "output": 5.00, "cache_create": 1.25, "cache_read": 0.10},
}


def _prices_for(model: str) -> dict:
    if model in _PRICES:
        return _PRICES[model]
    for prefix, p in _PRICES.items():
        if model.startswith(prefix):
            return p
    return {}


def record_cost(call_site: str, model: str, response: dict) -> None:
    """Best-effort cost ledger record. Silent on any failure --
    the ledger must never break a tick."""
    try:
        state_dir = os.environ.get("AGENT_STATE_DIR") or os.path.expanduser("~/.local/state/agent")
        ledger = os.path.join(state_dir, "cost-ledger.jsonl")
        usage = response.get("usage") or {}
        input_t = int(usage.get("input_tokens", 0))
        output_t = int(usage.get("output_tokens", 0))
        cc = int(usage.get("cache_creation_input_tokens", 0))
        cr = int(usage.get("cache_read_input_tokens", 0))
        if input_t == 0 and output_t == 0:
            return
        prices = _prices_for(model)
        usd = (input_t * prices.get("input", 0)
               + output_t * prices.get("output", 0)
               + cc * prices.get("cache_create", 0)
               + cr * prices.get("cache_read", 0)) / 1_000_000
        line = {
            "timestamp": datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
            "tick_pid": os.environ.get("TICK_PID", str(os.getpid())),
            "call_site": call_site,
            "model": model,
            "input_tokens": input_t,
            "output_tokens": output_t,
            "cache_creation_input_tokens": cc,
            "cache_read_input_tokens": cr,
            "usd": round(usd, 6),
            "source": "api",
        }
        os.makedirs(os.path.dirname(ledger), exist_ok=True)
        with open(ledger, "a") as f:
            f.write(json.dumps(line) + "\n")
    except Exception:
        pass


def rag_query(query: str) -> str:
    """Call lib/rag.sh's rag_query via a shell, return the markdown
    blob on stdout. Empty string on any failure -- the reflection
    works fine without RAG context."""
    if not query.strip():
        return ""
    igor_home = os.environ.get("AGENT_HOME")
    if not igor_home:
        return ""
    rag_sh = os.path.join(igor_home, "lib", "rag.sh")
    if not os.path.isfile(rag_sh):
        return ""
    try:
        result = subprocess.run(
            ["bash", "-c", f'. "{rag_sh}" && rag_query "$1"', "_", query],
            capture_output=True,
            text=True,
            timeout=90,
            env=os.environ.copy(),
        )
    except (subprocess.TimeoutExpired, OSError):
        return ""
    if result.returncode != 0:
        return ""
    return result.stdout.strip()


def log(msg: str) -> None:
    print(f"agent-reflect-ideas: {msg}", file=sys.stderr)


def parse_ideas(text: str) -> tuple[list[str], list[str], list[str], list[str]]:
    """Split blog-ideas.md into (prelude, open_header, blocks, postlude).

    `prelude`     -- everything up to and including the '## Open ideas' line
    `blocks`      -- list of multi-line idea blocks under '## Open ideas',
                     each a string ending in '\\n'
    `postlude`    -- everything from the next '## ' section onward

    If no '## Open ideas' section exists, returns (lines, [], [], []).
    """
    lines = text.splitlines(keepends=True)
    prelude: list[str] = []
    blocks: list[str] = []
    postlude: list[str] = []

    state = "pre"
    current_block: list[str] = []

    def flush_block() -> None:
        if current_block:
            blocks.append("".join(current_block))
            current_block.clear()

    for line in lines:
        if state == "pre":
            prelude.append(line)
            if line.rstrip("\n") == SECTION_OPEN:
                state = "open"
            continue
        if state == "open":
            # Section transition out of open ideas.
            if line.startswith("## ") and line.rstrip("\n") != SECTION_OPEN:
                flush_block()
                postlude.append(line)
                state = "post"
                continue
            # New idea bullet at column 0 starts a new block.
            if line.startswith("- "):
                flush_block()
                current_block.append(line)
                continue
            # Continuation of the current block (or pre-block whitespace
            # which gets attached to the block once one starts).
            if current_block:
                current_block.append(line)
            else:
                prelude.append(line)
            continue
        # state == "post"
        postlude.append(line)

    if state == "open":
        flush_block()

    return prelude, [], blocks, postlude


def serialize(
    prelude: list[str], blocks: list[str], postlude: list[str]
) -> str:
    return "".join(prelude) + "".join(blocks) + "".join(postlude)


def block_title(block: str) -> str:
    """First quoted title in the block, or first 60 chars of the
    bullet line as a fallback."""
    m = re.search(r'"([^"]+)"', block)
    if m:
        return m.group(1)
    first = block.splitlines()[0] if block else ""
    return first[:60]


def apply_moves(
    blocks: list[str], moves: list[dict]
) -> tuple[list[str], list[str]]:
    """Apply moves in order. Returns (new_blocks, applied_log).

    Each move: {"idx": 1-based int, "direction": "up"|"down"}.
    Out-of-range idx, moves at boundaries, or unknown direction
    are skipped (with a log line)."""
    out = list(blocks)
    applied: list[str] = []
    n = len(out)
    for move in moves[:MAX_MOVES]:
        idx = move.get("idx")
        direction = move.get("direction")
        if not isinstance(idx, int) or direction not in ("up", "down"):
            applied.append(f"  skip (bad shape): {move}")
            continue
        i = idx - 1  # to 0-based
        if i < 0 or i >= n:
            applied.append(f"  skip (idx {idx} out of range, n={n})")
            continue
        title = block_title(out[i])
        if direction == "up" and i > 0:
            out[i - 1], out[i] = out[i], out[i - 1]
            applied.append(f'  moved up:   "{title}"')
        elif direction == "down" and i < n - 1:
            out[i], out[i + 1] = out[i + 1], out[i]
            applied.append(f'  moved down: "{title}"')
        else:
            applied.append(f'  skip (at boundary): "{title}" {direction}')
    return out, applied


def call_haiku(
    api_key: str, model: str, context: str, blocks: list[str]
) -> dict | None:
    """Single Haiku call. Returns parsed JSON dict or None on failure."""
    if not blocks:
        return None
    titles = [block_title(b) for b in blocks]
    listing = "\n".join(f"{i + 1}. {t}" for i, t in enumerate(titles))

    system = (
        "You are a reflection step that runs after the agent (an autonomous "
        "Claude process) finishes a discretionary tick. the agent maintains a "
        "priority-ordered list of blog post ideas; the topmost idea is "
        "the next one to ship. Your job is to look at what the agent just did "
        "and propose at most 3 small re-orderings of the ideas list -- "
        'each move is "shift this idea up one slot" or "down one slot". '
        "Bias toward 0 moves: only shift an idea when the just-finished "
        "tick clearly made it feel more or less timely. Never propose "
        "more than 3 moves; never propose more than 1 slot per idea per "
        "reflection.\n\n"
        "Output STRICT JSON. No prose, no code fences. Schema:\n\n"
        "{\n"
        '  "moves": [{"idx": <1-based-int>, "direction": "up"|"down"}],\n'
        '  "reasoning": "one short sentence"\n'
        "}"
    )

    # Pull past context related to the tick's output so the reflection
    # can spot recurring framings or just-shipped topics.
    rag_context = rag_query(context[:2000])

    user = (
        "Context (what the agent just did this tick):\n\n"
        f"{context.strip()}\n\n"
        "Current blog-ideas list (1-indexed, top = next up):\n\n"
        f"{listing}\n\n"
        "---\n\n"
        "## Past context (RAG -- prior thinking related to what just happened)\n\n"
        f"{rag_context if rag_context else '(no past context retrieved this tick)'}\n"
    )

    payload = {
        "model": model,
        "max_tokens": 400,
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
        with urllib.request.urlopen(req, timeout=60) as resp:
            body = json.loads(resp.read().decode("utf-8"))
    except (urllib.error.URLError, urllib.error.HTTPError, TimeoutError) as e:
        log(f"API call failed: {e}")
        return None
    except json.JSONDecodeError as e:
        log(f"API response not JSON: {e}")
        return None

    record_cost("agent-reflect-ideas", model, body)

    try:
        text = body["content"][0]["text"]
    except (KeyError, IndexError, TypeError):
        log("API response missing content text")
        return None

    # Strip code fences if present.
    text = re.sub(r"^```[a-zA-Z]*\n?|\n?```$", "", text.strip())

    try:
        parsed = json.loads(text)
    except json.JSONDecodeError as e:
        log(f"model output not JSON: {e}")
        log(f"raw text: {text[:500]}")
        return None

    return parsed


def main() -> int:
    if len(sys.argv) != 3:
        print(
            "usage: agent-reflect-ideas.py <context-file> <ideas-file>",
            file=sys.stderr,
        )
        return 1

    context_path, ideas_path = sys.argv[1], sys.argv[2]

    if not os.path.isfile(context_path):
        log(f"context file not found: {context_path}")
        return 1
    if not os.path.isfile(ideas_path):
        log(f"ideas file not found: {ideas_path}")
        return 1

    api_key = os.environ.get("ANTHROPIC_API_KEY")
    if not api_key:
        log("ANTHROPIC_API_KEY not set")
        return 1

    model = os.environ.get("AGENT_MODEL_THINKING", DEFAULT_MODEL)

    with open(context_path, encoding="utf-8") as f:
        context = f.read()
    with open(ideas_path, encoding="utf-8") as f:
        ideas_text = f.read()

    prelude, _, blocks, postlude = parse_ideas(ideas_text)
    if not blocks:
        log("no open-ideas blocks found -- skipping reflection")
        return 0

    result = call_haiku(api_key, model, context, blocks)
    if result is None:
        log("reflection skipped (no usable model output)")
        return 0

    moves = result.get("moves") or []
    reasoning = result.get("reasoning") or ""

    if not moves:
        log(f"no moves proposed -- {reasoning}")
        return 0

    new_blocks, applied = apply_moves(blocks, moves)
    log(f"applied {len(moves)} move(s) -- {reasoning}")
    for line in applied:
        print(f"agent-reflect-ideas:{line}", file=sys.stderr)

    if new_blocks == blocks:
        log("no net changes after applying moves")
        return 0

    with open(ideas_path, "w", encoding="utf-8") as f:
        f.write(serialize(prelude, new_blocks, postlude))
    log(f"rewrote {ideas_path}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
