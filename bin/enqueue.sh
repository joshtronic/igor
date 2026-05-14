#!/usr/bin/env bash
# enqueue.sh — Foreman wrapper that runs a project's enqueue script.
#
# Usage: enqueue.sh <project-name>
#
# Loads $FOREMAN_HOME/projects/<project-name>.conf, sources the
# harness .env, then chdirs to the project repo and execs its
# ENQUEUE_CMD. The project script does the actual detection logic;
# this wrapper just plumbs config + secrets.

set -euo pipefail

FOREMAN_HOME="${FOREMAN_HOME:-$(cd "$(dirname "$0")/.." && pwd)}"
PROJECT="${1:?usage: enqueue.sh <project-name>}"

CONF="$FOREMAN_HOME/projects/${PROJECT}.conf"
[ -f "$CONF" ] || { echo "enqueue: no conf at $CONF" >&2; exit 2; }

# shellcheck source=/dev/null
. "$CONF"

: "${REPO_PATH:?REPO_PATH required in $CONF}"
: "${FORGEJO_REPO:?FORGEJO_REPO required in $CONF}"
: "${ENQUEUE_CMD:?ENQUEUE_CMD not set — this project has no producer}"

# Harness-wide env (Forgejo creds, etc.)
if [ -f "$FOREMAN_HOME/.env" ]; then
  set -a
  # shellcheck source=/dev/null
  . "$FOREMAN_HOME/.env"
  set +a
fi

# Expose conf vars to the project script.
export REPO_PATH FORGEJO_REPO PR_BASE FOREMAN_HOME PROJECT

cd "$REPO_PATH"
exec "./$ENQUEUE_CMD"
