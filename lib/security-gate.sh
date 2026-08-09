#!/usr/bin/env bash
# lib/security-gate.sh -- harness-side security review gate.
#
# An INDEPENDENT security pass over a branch diff, run by the harness
# (not the implementing agent) right before any code is pushed. The
# agent's own AGENTS.md `/security-review` is the fix-early first line;
# this is the unskippable last line. A material finding blocks the ship.
#
# Deterministic by contract: the reviewer must end its output with a
# `SECURITY_VERDICT: PASS|BLOCK` line, which we parse. One retry; if no
# verdict lands, we FAIL CLOSED (treat as block) -- security-first.
#
# Source order: expects lib/claude.sh (claude_call) already sourced,
# a model in the env (AGENT_MODEL_SECURITY, falling back to AGENT_MODEL
# or MODEL), and a `log` function defined by the caller.
#
# The reviewer model is deliberately the strongest tier configured
# (AGENT_MODEL_SECURITY, normally Fable): a one-shot adversarial
# judgment is exactly where the extra capability pays, and on
# subscription billing the marginal cost of the bigger model is zero.

# Max diff bytes fed to the reviewer. Issue-work diffs are already
# runaway-capped (~1000 non-test lines, igor#467); this bounds the
# pathological case and keeps the token cost predictable. An over-cap diff
# is reviewed truncated, with a note so the reviewer knows it didn't see
# everything.
SECURITY_GATE_MAX_DIFF_BYTES=60000

# security_gate <worktree> <base_ref> <call_site>
#
# Reviews origin/<base_ref>..HEAD (the harness has already committed the
# agent's work by the time this runs on every surface).
#
#   return 0  PASS  -- safe to ship; nothing on stdout
#   return 1  BLOCK -- material finding, OR the gate could not complete
#                      (fail closed). Findings are printed to stdout for
#                      the caller to surface (block comment / log line).
security_gate() {
  local worktree="$1" base="$2" call_site="$3"
  local model diff note="" system user raw verdict findings attempt

  model="${AGENT_MODEL_SECURITY:-${AGENT_MODEL:-${MODEL:-claude-sonnet-4-6}}}"

  diff=$(git -C "$worktree" diff "origin/${base}..HEAD" 2>/dev/null || true)
  if [ -z "$diff" ]; then
    # Nothing committed to review -- nothing to gate.
    return 0
  fi
  if [ "${#diff}" -gt "$SECURITY_GATE_MAX_DIFF_BYTES" ]; then
    diff="${diff:0:SECURITY_GATE_MAX_DIFF_BYTES}"
    note="

[diff truncated at ${SECURITY_GATE_MAX_DIFF_BYTES} bytes; review what is
shown, and if you cannot be confident the change is safe, BLOCK]"
  fi

  system=$(cat <<'EOF'
You are an independent security reviewer. You did NOT write this code.
Your only job: catch material, exploitable security problems that THIS
diff introduces. Be precise and conservative -- flag ONLY real,
exploitable issues introduced by this change. Do NOT flag style, tests,
theoretical concerns, or pre-existing problems the diff does not touch.

Look for, among others:
- hardcoded secrets, credentials, API keys, or tokens
- command / SQL / path injection from untrusted input
- unsafe eval, shell interpolation, or deserialization of input
- path traversal, SSRF, auth or authorization bypass
- disabled TLS or certificate verification
- secrets written to logs or committed files

Write your findings as a short list, or the single line
"No material findings." Then, as the VERY LAST line of your output,
print EXACTLY one of:
SECURITY_VERDICT: PASS
SECURITY_VERDICT: BLOCK

Use BLOCK only when you found a real, exploitable issue introduced by
this diff that should stop the merge. When in genuine doubt about a
concrete risk, prefer BLOCK.
EOF
)
  user="Branch diff to review:

${diff}${note}"

  for attempt in 1 2; do
    # strip_fences=0: the diff (and any findings quoting it) can contain
    # ``` fences that must not be stripped.
    raw=$(claude_call "$model" "$call_site" 1500 "$system" "$user" 0) || {
      log "security gate: review call failed (attempt $attempt)"
      continue
    }
    verdict=$(printf '%s' "$raw" \
      | grep -oE 'SECURITY_VERDICT:[[:space:]]*(PASS|BLOCK)' \
      | grep -oE 'PASS|BLOCK' | tail -1 || true)
    case "$verdict" in
      PASS)
        return 0
        ;;
      BLOCK)
        findings=$(printf '%s' "$raw" \
          | grep -vE '^[[:space:]]*SECURITY_VERDICT:' || true)
        printf '%s\n' "$findings"
        return 1
        ;;
      *)
        log "security gate: no parseable verdict (attempt $attempt)"
        ;;
    esac
  done

  # Fail closed: no verdict after retries. Block, but say why so the
  # human reads it as a re-queue, not a confirmed vulnerability.
  printf '%s\n' "The security gate could not complete -- no verdict from the reviewer after 2 attempts. This is most likely a transient model/API error rather than a real finding; re-queue to retry."
  return 1
}
