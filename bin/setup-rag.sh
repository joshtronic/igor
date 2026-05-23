#!/usr/bin/env bash
# setup-rag.sh -- idempotent Python venv setup for the RAG layer.
#
# Creates $AGENT_STATE_DIR/rag-venv if missing, installs requirements.
# Designed to be called at tick start by tick.sh -- no-op after the
# first successful run.
#
# Run manually:  bin/setup-rag.sh
# Force rebuild: rm -rf $AGENT_STATE_DIR/rag-venv && bin/setup-rag.sh

set -euo pipefail

AGENT_HOME="${AGENT_HOME:-$(cd "$(dirname "$0")/.." && pwd)}"
AGENT_STATE_DIR="${AGENT_STATE_DIR:-$HOME/.local/state/agent}"
VENV="$AGENT_STATE_DIR/rag-venv"
REQS="$AGENT_HOME/requirements.txt"
STAMP="$VENV/.installed-from"

mkdir -p "$AGENT_STATE_DIR"

# Idempotent fast-path: if venv exists AND requirements.txt hasn't
# changed since last install, skip. Compare by content hash so a
# whitespace-equivalent file doesn't trigger a rebuild.
if [ -d "$VENV" ] && [ -f "$STAMP" ]; then
  current_hash=$(sha256sum "$REQS" | awk '{print $1}')
  installed_hash=$(cat "$STAMP" 2>/dev/null || echo "")
  if [ "$current_hash" = "$installed_hash" ]; then
    exit 0
  fi
  echo "rag: requirements.txt changed, rebuilding venv" >&2
fi

# Need python3
if ! command -v python3 >/dev/null 2>&1; then
  echo "rag: python3 not found on PATH. Install python3 + python3-venv via apt." >&2
  exit 1
fi

# Need venv module (Debian splits this out into python3-venv)
if ! python3 -c "import venv" 2>/dev/null; then
  echo "rag: python3-venv not available. Install via 'apt install python3-venv'." >&2
  exit 1
fi

if [ ! -d "$VENV" ]; then
  echo "rag: creating venv at $VENV" >&2
  python3 -m venv "$VENV"
fi

echo "rag: installing dependencies from $REQS" >&2
"$VENV/bin/pip" install --quiet --upgrade pip
"$VENV/bin/pip" install --quiet -r "$REQS"

sha256sum "$REQS" | awk '{print $1}' > "$STAMP"
echo "rag: venv ready" >&2
