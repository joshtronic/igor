#!/usr/bin/env bash
# worker-doc.sh -- picks the document bin/check-sync.sh validates its
# OUTCOME sentinels and helper references against.
#
# Since igor#485/#486 the issue-work system prompt is built from
# `context_surface worker-contract` (lib/context-source.sh's last-good
# Distillery cache), not this repo's AGENTS.md. The gate has to check
# whichever document the worker actually RECEIVES, or it's checking a
# copy the model never reads (igor#487). A seeded cache -- every
# production host -- means that sourced body. A CI container has no
# cache and no Distillery access, so it falls back to the in-repo
# AGENTS.md and says so, loudly: a green run in that mode must never be
# mistaken for having checked the real document.
#
# Seeding is NOT this module's job (bin/install.sh and bin/tick.sh own
# it) -- a test gate shouldn't clone repos or touch the live cache.
#
# Requires lib/context-source.sh sourced first (context_seeded,
# context_surface). Lives here rather than inline in check-sync.sh so
# both branches are unit-testable; bin/test-worker-doc.sh drives them.

# worker_doc_select <destination-path>
#
# Sets WORKER_DOC (the path to validate) and WORKER_DOC_LABEL (how to
# name it in output). With a seeded cache the sourced worker-contract
# body is written to <destination-path> and WORKER_DOC points there;
# otherwise WORKER_DOC is the in-repo AGENTS.md and the destination is
# left alone.
#
# Nonzero -- with WORKER_DOC empty -- when the cache IS seeded but the
# surface can't be served. That's a broken cache, and it must not
# degrade into validating an empty file: the helper-reference check
# passes vacuously over one, which is the exact "checking a document
# nobody reads" failure this gate exists to catch.
worker_doc_select() {
  local dest="$1"
  WORKER_DOC=""
  WORKER_DOC_LABEL=""

  if ! context_seeded; then
    WORKER_DOC="AGENTS.md"
    WORKER_DOC_LABEL="AGENTS.md (fallback -- prompt cache unseeded)"
    return 0
  fi

  if ! context_surface worker-contract > "$dest"; then
    return 1
  fi
  # shellcheck disable=SC2034  # both are read by the caller (bin/check-sync.sh)
  WORKER_DOC="$dest"
  # shellcheck disable=SC2034
  WORKER_DOC_LABEL="the sourced worker-contract"
  return 0
}
