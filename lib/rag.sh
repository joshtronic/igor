# lib/rag.sh -- shared RAG helpers.
#
# Source from any harness script that wants past-context retrieval:
#
#     . "$IGOR_HOME/lib/rag.sh"
#     ensure_rag_built || true            # lazy build; safe to skip
#     context=$(rag_query "$query_text")  # markdown blob on stdout
#
# Two functions:
#
#   ensure_rag_built
#       Idempotent per-tick build. First caller in a tick pays the
#       ~25s build cost (flush + rebuild redis index from brain
#       journal / memories / commits / reviews). Subsequent callers
#       in the same tick are no-ops -- they hit a marker file keyed
#       by $IGOR_TICK_PID. Returns 0 on success (index ready) or
#       1 on any failure (venv missing, build crashed, etc.); the
#       caller is expected to proceed without context.
#
#   rag_query <query-text>
#       Returns the top-K (default 5) most semantically-similar
#       entries from the index, formatted as a markdown blob on
#       stdout. Auto-calls ensure_rag_built if no marker exists.
#       Returns empty string on any failure.
#
# Required env (inherited from the caller):
#   IGOR_HOME         path to the harness repo (for rag.py + venv)
#   IGOR_STATE_DIR    where state lives ($HOME/.local/state/igor by default)
#   IGOR_BRAIN_PATH   path to the brain clone (defaults computed below)
#   IGOR_TICK_PID     pid of the parent tick.sh process. tick.sh
#                     exports this so children share a marker; if
#                     unset (running a script outside a tick), falls
#                     back to $$ -- a fresh build per invocation.

# Resolve paths once at source time; callers can override later if
# they're testing in odd contexts.
: "${IGOR_HOME:?IGOR_HOME must be set before sourcing lib/rag.sh}"
: "${IGOR_STATE_DIR:=$HOME/.local/state/igor}"

_RAG_VENV="$IGOR_STATE_DIR/rag-venv"
_RAG_MARKER_DIR="$IGOR_STATE_DIR/rag-built"

_rag_brain_path() {
  printf '%s' "${IGOR_BRAIN_PATH:-$IGOR_STATE_DIR/repos/igor/brain}"
}

_rag_marker_path() {
  printf '%s/%s' "$_RAG_MARKER_DIR" "${IGOR_TICK_PID:-$$}"
}

ensure_rag_built() {
  local marker
  marker=$(_rag_marker_path)
  [ -f "$marker" ] && return 0

  if ! "$IGOR_HOME/bin/setup-rag.sh"; then
    echo "rag: venv setup failed -- proceeding without past-context retrieval" >&2
    return 1
  fi

  local brain
  brain=$(_rag_brain_path)
  if ! IGOR_BRAIN_PATH="$brain" \
       "$_RAG_VENV/bin/python" "$IGOR_HOME/bin/rag.py" build; then
    echo "rag: build failed -- proceeding without past-context retrieval" >&2
    return 1
  fi

  mkdir -p "$_RAG_MARKER_DIR"
  touch "$marker"
}

rag_query() {
  local query="$1"
  [ -z "$query" ] && return 0
  local marker
  marker=$(_rag_marker_path)
  if [ ! -f "$marker" ]; then
    ensure_rag_built || return 0
  fi
  local brain
  brain=$(_rag_brain_path)
  IGOR_BRAIN_PATH="$brain" \
    "$_RAG_VENV/bin/python" "$IGOR_HOME/bin/rag.py" query \
      "$query" -k 5 2>/dev/null || true
}

# Cleanup helper -- tick.sh hooks this into its EXIT trap so the
# per-tick marker doesn't accumulate in $IGOR_STATE_DIR/rag-built/.
rag_cleanup_marker() {
  rm -f "$(_rag_marker_path)" 2>/dev/null || true
}
