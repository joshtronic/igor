#!/usr/bin/env bash
# context-source.sh -- sources igor's prompt surfaces from the Distillery
# (joshtronic/distillery) at origin/master, LIVE: no pins, no submodules,
# and -- per the revised igor#485 spec -- NO in-repo fallback. A change
# merged to distillery master is live on igor's next tick, exactly like
# igor's own self-pull. The "fallback" is the PREVIOUSLY SOURCED copy: a
# last-good cache under CONTEXT_CACHE_DIR, refreshed all-or-nothing.
#
# Read via `git show origin/master:...` against the distillery clone
# ONLY -- never the clone's working tree, same read-the-ref-never-the-
# checkout pattern rc_local_init uses (lib/repo-checks.sh). bin/tick.sh
# owns keeping that clone fetched (a dedicated flat path, since
# distillery isn't necessarily one of the owner-nested bot-managed
# repos); this module only reads it.
#
# All-or-nothing swap is deliberate: skills reference each other's
# rules, so a half-updated brain is worse than yesterday's whole one. A
# broken distillery skill (missing, malformed, or too thin) must never
# corrupt the cache -- it refuses the swap and logs once, so the fleet
# keeps working on yesterday's rules instead of stalling at 3am on
# nobody watching. Only a NEVER-seeded cache is fatal (see
# context_seeded / context_bootstrap_alert) -- igor does not run
# prompt-consuming work on missing brain.
#
# Shape validation alone doesn't prove a skill is the one `still build`
# actually produced -- it only proves the extracted file LOOKS like a
# skill. The integrity check for that is dist/manifest.json, which
# `still build` writes with a sha256 per skill. context_refresh reads it
# at origin/master and verifies every extracted SKILL.md's raw bytes
# against its recorded hash before the generation is eligible to swap in
# (igor#545) -- same all-or-nothing posture: a missing manifest, an
# unparseable one, a skill absent from it, or a hash mismatch all refuse
# the whole swap, not just the one skill.

# Fallback stubs so this module is sourceable standalone (tests, or any
# caller that hasn't sourced tick.sh's full library set).
if ! declare -F log >/dev/null; then log() { printf '[agent] %s\n' "$*" >&2; }; fi
if ! declare -F recipients_with_primary >/dev/null; then
  recipients_with_primary() { printf '%s' "${PRIMARY_RECIPIENTS:-}"; }
fi
if ! declare -F email_send >/dev/null; then email_send() { return 1; }; fi

CONTEXT_MIN_LINES=10   # context_refresh's "non-trivial" bar, per skill

# The skills igor's prompt surfaces consume from the distillery. Kept as
# one list so context_refresh's all-or-nothing validation and the
# consuming call sites (bin/tick.sh, bin/site-work-block.sh,
# lib/feedback.sh) can't drift apart silently.
CONTEXT_SKILLS=(
  worker-contract
  review-directive
  voice
  feedback-directive
  site-work-directive
  sports-digest-directive
  now-directive
)

# CONTEXT_DISTILLERY_PATH / CONTEXT_CACHE_DIR are overridable (tests
# point them at fixtures); real runs default under AGENT_STATE_DIR.
_context_distillery_path() {
  printf '%s' "${CONTEXT_DISTILLERY_PATH:-${AGENT_STATE_DIR:-$HOME/.local/state/agent}/repos/distillery}"
}

_context_cache_root() {
  printf '%s' "${CONTEXT_CACHE_DIR:-${AGENT_STATE_DIR:-$HOME/.local/state/agent}/context}"
}

# context_skill_body <skill-name>
#
# Reads skills/<skill-name>/SKILL.md from the distillery clone at
# origin/master and echoes the body with the YAML frontmatter (the
# opening `---` fence through the closing one, plus one blank line)
# stripped.
#
# Nonzero when: clone missing, skill missing, no frontmatter, or empty
# body. The failure reason goes to STDERR, not a global -- callers
# invoke this via `$( )`, which forks a subshell, so a global set in
# here would never make it back out.
context_skill_body() {
  local skill="$1" path raw
  path="$(_context_distillery_path)"

  if [ -z "$skill" ]; then
    printf 'no skill name given\n' >&2
    return 1
  fi
  if [ ! -d "$path/.git" ]; then
    printf 'no readable distillery clone at %s\n' "$path" >&2
    return 1
  fi
  # `|| true`: a caller running under `set -e` must not abort here --
  # `git show` failing is the ordinary "skill absent on this HEAD" case,
  # not a crash-worthy error.
  raw=$(git -C "$path" show "origin/master:skills/${skill}/SKILL.md" 2>/dev/null) || true
  if [ -z "$raw" ]; then
    printf 'skills/%s/SKILL.md not found on origin/master\n' "$skill" >&2
    return 1
  fi

  local -a lines
  mapfile -t lines <<<"$raw"

  if [ "${lines[0]:-}" != "---" ]; then
    printf 'no YAML frontmatter (no opening --- fence)\n' >&2
    return 1
  fi

  local n=${#lines[@]} i close=-1
  for ((i = 1; i < n; i++)); do
    if [ "${lines[i]}" = "---" ]; then
      close=$i
      break
    fi
  done
  if [ "$close" -lt 0 ]; then
    printf 'frontmatter never closes (no closing --- fence)\n' >&2
    return 1
  fi

  local start=$((close + 1))
  if [ "$start" -lt "$n" ] && [ -z "${lines[$start]}" ]; then
    start=$((start + 1))   # one blank line after the fence, if present
  fi

  local body
  body=$(printf '%s\n' "${lines[@]:$start}")
  if [ -z "$(printf '%s' "$body" | tr -d '[:space:]')" ]; then
    printf 'body is empty\n' >&2
    return 1
  fi
  printf '%s\n' "$body"
}

# _context_warn_once <key> <message> -- logs at most once per distinct
# key (a bad HEAD sha, or the constant "clone-unavailable"), so a merged
# skill that stays broken -- or a distillery that stays unreachable --
# doesn't re-warn every tick until the key changes (fixed, or a
# different new HEAD is also broken).
_context_warn_once() {
  local key="$1" msg="$2" cache_root marker last
  cache_root="$(_context_cache_root)"
  mkdir -p "$cache_root"
  marker="$cache_root/.bad-head"
  last=$(cat "$marker" 2>/dev/null || echo "")
  if [ "$last" = "$key" ]; then
    return 0
  fi
  log "context-source: $msg"
  printf '%s' "$key" > "$marker"
}

# _context_manifest_raw <distillery-path>
#
# Reads dist/manifest.json at origin/master and echoes it, but ONLY
# after confirming it's parseable JSON -- a missing file or a broken
# parse both fail loudly (distinct stderr reasons) rather than letting
# a caller silently treat "no manifest" as "nothing to verify".
_context_manifest_raw() {
  local dpath="$1" raw
  raw=$(git -C "$dpath" show "origin/master:dist/manifest.json" 2>/dev/null) || raw=""
  if [ -z "$raw" ]; then
    printf 'manifest missing -- no dist/manifest.json on origin/master\n' >&2
    return 1
  fi
  if ! printf '%s' "$raw" | jq empty >/dev/null 2>&1; then
    printf 'manifest unparseable -- dist/manifest.json is not valid JSON\n' >&2
    return 1
  fi
  printf '%s' "$raw"
}

# _context_verify_skill_sha256 <skill> <manifest-json>
#
# Hashes the skill's raw SKILL.md bytes at origin/master (the whole
# file, exactly as `still build` would have hashed it -- not the
# frontmatter-stripped body context_skill_body returns) and compares
# against the manifest's recorded sha256 for that skill, keyed by name
# under .skills. A skill absent from the manifest is a failure, same as
# a mismatch -- otherwise the check is bypassed by just deleting the
# manifest entry. Broken out as its own function (rather than inlined
# in context_refresh's loop) so a test can stub it to prove the gate,
# not some unrelated validation, is what rejects a mutated skill.
_context_verify_skill_sha256() {
  local skill="$1" manifest="$2" dpath expected computed
  dpath="$(_context_distillery_path)"
  expected=$(printf '%s' "$manifest" | jq -r --arg s "$skill" '.skills[$s] // empty' 2>/dev/null)
  if [ -z "$expected" ]; then
    printf 'missing from manifest\n' >&2
    return 1
  fi
  computed=$(git -C "$dpath" show "origin/master:skills/${skill}/SKILL.md" 2>/dev/null | sha256sum | cut -d' ' -f1)
  if [ "$expected" != "$computed" ]; then
    printf 'sha256 mismatch (manifest %s != computed %s)\n' "$expected" "$computed" >&2
    return 1
  fi
}

# context_refresh
#
# Called once per tick (bin/tick.sh, near the self-pull). Reads the
# distillery clone's origin/master HEAD; a no-op if it matches the
# cache's stamp. Otherwise reads dist/manifest.json and extracts +
# validates every CONTEXT_SKILLS entry -- shape (frontmatter present,
# body >= CONTEXT_MIN_LINES lines) AND integrity (raw SKILL.md bytes
# hash to the sha256 the manifest recorded for that skill) -- into a
# fresh generation dir and, ONLY if every one is valid, atomically
# swaps it in as `current` (a symlink rename -- readers via
# context_surface always see either the whole old generation or the
# whole new one, never a partial write).
#
# On any problem -- clone missing/unreadable, HEAD unresolvable, a
# missing/unparseable manifest, a skill absent from the manifest, a
# sha256 mismatch, or any shape failure -- the existing cache is left
# untouched and one warn is logged (deduped by _context_warn_once).
# Returns nonzero in that case; callers treat this as "coasting on
# last-good", not a crash -- see context_seeded for the one case that
# actually matters (never seeded at all).
context_refresh() {
  local path cache_root current head stamp
  path="$(_context_distillery_path)"
  cache_root="$(_context_cache_root)"
  mkdir -p "$cache_root"
  current="$cache_root/current"

  if [ ! -d "$path/.git" ]; then
    _context_warn_once "clone-unavailable" "no readable distillery clone at $path -- serving last-good cache"
    return 1
  fi

  head=$(git -C "$path" rev-parse origin/master 2>/dev/null) || head=""
  if [ -z "$head" ]; then
    _context_warn_once "clone-unavailable" "cannot resolve origin/master at $path -- serving last-good cache"
    return 1
  fi

  stamp=""
  [ -f "$current/HEAD" ] && stamp=$(cat "$current/HEAD" 2>/dev/null)
  if [ "$head" = "$stamp" ]; then
    return 0   # already current -- no re-extract
  fi

  local gen errfile skill body line_count ok=1 bad_reason="" manifest_raw
  errfile=$(mktemp)
  if manifest_raw=$(_context_manifest_raw "$path" 2>"$errfile"); then
    :
  else
    ok=0
    bad_reason="$(cat "$errfile" 2>/dev/null)"
  fi

  gen=$(mktemp -d "$cache_root/.gen-XXXXXX")
  if [ "$ok" -eq 1 ]; then
    for skill in "${CONTEXT_SKILLS[@]}"; do
      if body=$(context_skill_body "$skill" 2>"$errfile"); then
        line_count=$(printf '%s\n' "$body" | wc -l)
        if [ "$line_count" -lt "$CONTEXT_MIN_LINES" ]; then
          ok=0
          bad_reason="skill '${skill}' too short (${line_count} line(s), need >= ${CONTEXT_MIN_LINES})"
          break
        fi
        if ! _context_verify_skill_sha256 "$skill" "$manifest_raw" 2>"$errfile"; then
          ok=0
          bad_reason="skill '${skill}' failed manifest sha256 verification -- $(cat "$errfile" 2>/dev/null)"
          break
        fi
        printf '%s\n' "$body" > "$gen/${skill}.md"
      else
        ok=0
        bad_reason="skill '${skill}' invalid -- $(cat "$errfile" 2>/dev/null)"
        break
      fi
    done
  fi
  rm -f "$errfile"

  if [ "$ok" -ne 1 ]; then
    rm -rf "$gen"
    _context_warn_once "$head" "refresh of ${head:0:7} refused -- $bad_reason -- serving last-good cache"
    return 1
  fi

  printf '%s\n' "$head" > "$gen/HEAD"

  # Atomic swap: repoint `current` in one rename (ln + mv -T on the
  # symlink itself, never traversing into the target). The old
  # generation is deleted right below, and the guarantee that buys is
  # narrow but real: a reader that ALREADY OPENED one of its files
  # keeps reading it to completion, since unlinking doesn't invalidate
  # descriptors already open on the file (standard POSIX unlink
  # semantics). A reader that resolves `current` and opens afterwards,
  # or reads several surfaces in sequence across the swap, can still
  # straddle two generations -- callers read one surface per `$( )`,
  # so that window is a stale read, never a partial one.
  ln -sfn "$(basename "$gen")" "$cache_root/current.tmp"
  mv -T "$cache_root/current.tmp" "$current"

  find "$cache_root" -maxdepth 1 -type d -name '.gen-*' ! -name "$(basename "$gen")" -exec rm -rf {} +
  rm -f "$cache_root/.bad-head"
  return 0
}

# context_surface <skill-name>
#
# Echoes the cached body for a consumed skill. Nonzero ONLY when the
# cache has never been seeded (see context_seeded) -- once seeded, every
# name in CONTEXT_SKILLS is guaranteed present (context_refresh writes
# them all together or none at all). bin/tick.sh's bootstrap gate checks
# context_seeded once per tick, before any of these call sites run, so
# reaching a live "unseeded" failure here would mean that gate was
# skipped -- a caller bug, not a runtime condition to design around.
context_surface() {
  local skill="$1" current
  current="$(_context_cache_root)/current"
  if [ ! -f "$current/HEAD" ]; then
    log "context-source: cache unseeded -- cannot serve $skill"
    return 1
  fi
  if [ -f "$current/${skill}.md" ]; then
    cat "$current/${skill}.md"
    return 0
  fi
  log "context-source: $skill not present in the seeded cache (not a consumed skill?)"
  return 1
}

# context_seeded -- true iff a context_refresh has ever swapped a
# generation into place. The tick-level bootstrap gate reads this.
context_seeded() {
  [ -f "$(_context_cache_root)/current/HEAD" ]
}

# context_bootstrap_alert
#
# Once-daily operator alert while the cache has NEVER been seeded -- a
# fresh install, or a distillery that's been unreachable/broken since
# day one. Distinct from _context_warn_once's ordinary fail-open log,
# which covers an ALREADY-seeded fleet coasting on last-good; this is
# the one case that's actually fatal to prompt-consuming work.
context_bootstrap_alert() {
  local cache_root marker today recipients subject body
  cache_root="$(_context_cache_root)"
  mkdir -p "$cache_root"
  marker="$cache_root/.bootstrap-alert-emailed-on"
  today=$(date +%Y-%m-%d)
  [ "$(cat "$marker" 2>/dev/null || echo "")" = "$today" ] && return 0

  recipients=$(recipients_with_primary "${ALERT_RECIPIENTS:-}")
  if [ -z "$recipients" ] || [ -z "${SMTP2GO_API_KEY:-}" ] || [ -z "${SMTP2GO_SENDER:-}" ]; then
    log "context-source: prompt cache never seeded and alert email not configured (PRIMARY_RECIPIENTS + SMTP2GO) -- log-only"
    return 0
  fi

  subject="[Agent] prompt cache never seeded on $(hostname -s 2>/dev/null || echo agent)"
  body="igor's prompt-surface cache (lib/context-source.sh) has never
completed a successful pull from the Distillery (joshtronic/distillery).
All prompt-consuming work (issue work, PR review, feedback triage,
site-work, sports digest) is BLOCKED until one succeeds -- there is no
in-repo fallback by design (igor#485).

Check: is the distillery clone reachable (SSH access via FORGEJO_HOST,
at \${AGENT_STATE_DIR}/repos/distillery)? Does every consumed skill on
distillery's master have valid frontmatter and a body of at least
${CONTEXT_MIN_LINES} lines? See the tick log for the specific failure.

This alert is sent at most once per day; it stops once the first
successful pull lands."
  if email_send "$subject" "<pre>${body}</pre>" "$body" "$recipients"; then
    printf '%s' "$today" > "$marker"
    log "context-source: bootstrap-never-seeded alert emailed to $recipients"
  else
    log "warning: context-source bootstrap alert email failed -- will retry next tick"
  fi
  return 0
}
