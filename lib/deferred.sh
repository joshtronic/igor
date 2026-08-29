#!/usr/bin/env bash
# deferred.sh -- the deferred-ticket pass: work gated on an external data source
# that auto-activates when a condition becomes true.
#
# Convention opt-in, NO env knob (like logwatch): an OPEN issue carrying a
# `<!-- gate -->` block in its body AND the built-in `Status/Blocked` label is
# deferred work. The claimable grind already skips `Status/Blocked`, so nothing
# works it early -- no custom label needed (the old `Status/Deferred` is retired;
# we use only Forgejo's built-in labels + the `Agent` greenlight). Once per ISO day
# this pass fetches the gate's data source and asks (tool-free) whether its
# condition is now met. On MET it does NOT hand the ticket to the grind -- the gate
# check has false-positived in practice, so it removes `Status/Blocked`
# AND the `Agent` greenlight and ASSIGNS the ticket to FORGEJO_REVIEWER for
# confirmation. The human re-adds `Agent` once they've confirmed the gate really
# cleared, and only then does the grind claim it. On UNMET the ticket stays
# `Status/Blocked` and re-checks the next day.
#
# The gate block (first match wins; whitespace-tolerant):
#   <!-- gate
#   url: https://example.com/release-notes
#   condition: <plain-language condition to evaluate against that page>
#   -->
#
# Security: the check is a tool-free claude_call that sees ONLY the public page
# (no repo/private data), so there is no lethal-trifecta surface; the only
# hardening needed is on the outbound fetch (https-only + a size cap). The
# verdict FAILS CLOSED -- any error, ambiguity, or
# unparseable response leaves the ticket deferred (UNMET), so a flaky check can
# never wrongly activate work; the cost of a false UNMET is just "re-check
# tomorrow."
#
# Sourced by tick.sh; depends on _fj + forgejo_remove_label (lib/forgejo.sh),
# claude_call (lib/claude.sh), log (tick.sh), jq, curl. do_deferred_tick lives
# here (self-contained), like do_automerge_tick lives in lib/automerge.sh.

# A gated ticket = built-in `Status/Blocked` + this gate block in its body.
DEFERRED_GATE_OPEN="<!-- gate"

# deferred_parse_gate_url / deferred_parse_gate_condition <body> -- extract the
# url:/condition: lines of the first gate block. Empty if absent.
deferred_parse_gate_url() {
  printf '%s\n' "$1" | sed -n 's/^[[:space:]]*url:[[:space:]]*//p' | head -1
}
deferred_parse_gate_condition() {
  printf '%s\n' "$1" | sed -n 's/^[[:space:]]*condition:[[:space:]]*//p' | head -1
}

# ---- per-ticket daily slot state (.deferred in discretionary-state.json) ----
# Keyed by "<repo>#<num>" -> ISO date (YYYY-MM-DD), matching the per-subsystem
# daily/weekly stamp convention used elsewhere in discretionary-state.json. One
# gate-check per ticket per day; stamped BEFORE the model call so a down url or
# flaky parse can't spin a retry storm.
deferred_state_file() {
  printf '%s/discretionary-state.json' "${AGENT_STATE_DIR:-$HOME/.local/state/agent}"
}
deferred_day_done() {  # <key> -- 0 if this ticket was already checked today
  local key="$1" f last
  f=$(deferred_state_file); [ -f "$f" ] || return 1
  last=$(jq -r --arg k "$key" '.deferred[$k] // ""' "$f" 2>/dev/null)
  [ -n "$last" ] && [ "$last" = "$(date +%F)" ]
}
deferred_mark_day_done() {  # <key>
  local key="$1" f tmp
  f=$(deferred_state_file); [ -f "$f" ] || echo '{}' > "$f"
  tmp=$(mktemp)
  if jq --arg k "$key" --arg d "$(date +%F)" \
      '.deferred //= {} | .deferred[$k] = $d' "$f" > "$tmp"; then
    mv "$tmp" "$f"
  else
    rm -f "$tmp"   # jq failed -- drop the temp instead of leaking it
  fi
}

# deferred_fetch <url> -- echo the page body, size-capped, HTTPS-ONLY. Empty
# output if the url is not https or the fetch fails (caller treats empty as
# "stay deferred"). https-only blocks file:// / http://internal / metadata
# endpoints; the cap keeps a huge/hostile page from bloating the prompt.
deferred_fetch() {
  local url="$1"
  case "$url" in https://*) ;; *) return 0 ;; esac
  curl -fsS --max-time 20 "$url" 2>/dev/null | head -c 262144 || true
}

# deferred_check <model> <condition> <page> -- one TOOL-FREE claude_call asking
# whether the page satisfies the condition. Echoes the raw response.
deferred_check() {
  local model="$1" condition="$2" page="$3"
  claude_call "$model" "deferred-gate" 300 \
    "You decide whether a gating condition is satisfied by the content of a web page. Reply with EXACTLY two lines: a line 'GATE: MET' or 'GATE: UNMET', then a line 'EVIDENCE: <one short line>'. Answer MET only if the page CLEARLY shows the condition is now true; if it is unclear, partial, or merely promised/coming-soon, answer UNMET. Nothing else." \
    "$(printf 'Condition to evaluate:\n%s\n\n--- page content (may be truncated) ---\n%s\n--- end of page ---\n\nIs the condition MET right now, per this page?' "$condition" "$page")" \
    1
}

# deferred_parse_verdict <raw> -- echo MET or UNMET. Reads the GATE: line value and
# checks if it STARTS with MET (so "UNMET" is never mistaken for "MET"); defaults
# to UNMET = FAIL CLOSED on anything unparseable.
deferred_parse_verdict() {
  local gline
  gline=$(printf '%s\n' "$1" | sed -n 's/^[[:space:]]*GATE:[[:space:]]*//p' \
    | head -1 | tr '[:lower:]' '[:upper:]' | tr -d '[:space:]')
  case "$gline" in MET*) echo MET ;; *) echo UNMET ;; esac
}

# deferred_parse_evidence <raw> -- the EVIDENCE: line, for the un-defer comment.
deferred_parse_evidence() {
  printf '%s\n' "$1" | sed -n 's/^[[:space:]]*EVIDENCE:[[:space:]]*//p' | head -1
}

# deferred_release_to_reviewer <repo> <num> <reviewer> <evidence> -- gate cleared:
# hand the ticket to the HUMAN for confirmation, not straight to the grind. The
# auto gate-check has false-positived in practice, so a machine MET
# is NOT trusted to auto-work: drop the `Status/Blocked` hold AND the `Agent`
# greenlight, assign the reviewer, and comment how to release it. The human re-adds
# `Agent` once they've confirmed. Impure (label/assign/comment via _fj).
deferred_release_to_reviewer() {
  local repo="$1" num="$2" reviewer="$3" evidence="$4"
  forgejo_remove_label "$repo" "$num" "Status/Blocked" 2>/dev/null \
    || log "deferred: warning -- could not drop Status/Blocked on ${repo}#${num}"
  forgejo_remove_label "$repo" "$num" "Agent" 2>/dev/null \
    || log "deferred: warning -- could not drop Agent on ${repo}#${num}"
  if [ -n "$reviewer" ]; then
    forgejo_assign "$repo" "$num" "$reviewer" 2>/dev/null \
      || log "deferred: warning -- could not assign ${repo}#${num} to ${reviewer}"
  fi
  _fj POST "/repos/${repo}/issues/${num}/comments" \
    "$(jq -n --arg b "Gate cleared -- ${evidence:-condition met}. Removed \`Status/Blocked\` + \`Agent\` and assigned to ${reviewer:-a reviewer} for confirmation. This auto gate-check can false-positive, so the ticket is NOT auto-worked: **re-add the \`Agent\` label** once you've confirmed the gate really cleared, and the grind will pick it up." '{body:$b}')" \
    >/dev/null 2>&1 || true
}

# do_deferred_tick -- walk the analysis set for deferred-gated tickets; check the
# first one not yet checked today; on MET drop the hold so the grind claims it.
# Returns 0 when it checks a ticket (the tick's one piece of work), 1 when nothing
# is due. A model call, so the cascade places it below the Claude health gate.
do_deferred_tick() {
  local repo_line repo issues n body url condition key page model raw verdict evidence reviewer
  model="${AGENT_MODEL_REVIEW:-${AGENT_MODEL:-}}"
  [ -n "$model" ] || return 1
  reviewer="${FORGEJO_REVIEWER:-}"

  while IFS= read -r repo_line; do
    [ -n "$repo_line" ] || continue
    repo=$(jq -r '.full_name' <<<"$repo_line" 2>/dev/null)
    [ -n "$repo" ] || continue

    issues=$(_fj GET "/repos/${repo}/issues?state=open&type=issues&labels=Status/Blocked&limit=50" 2>/dev/null) || continue
    [ -n "$issues" ] || continue

    while IFS= read -r n; do
      [ -n "$n" ] || continue
      key="${repo}#${n}"
      deferred_day_done "$key" && continue   # already checked today
      deferred_mark_day_done "$key"          # stamp up front: one look per ticket per ISO day (no retry storm)

      body=$(jq -r --arg num "$n" '.[] | select((.number|tostring)==$num) | .body // ""' <<<"$issues")
      url=$(deferred_parse_gate_url "$body")
      condition=$(deferred_parse_gate_condition "$body")
      if [ -z "$url" ] || [ -z "$condition" ]; then
        log "deferred: ${key} gate block has no usable url/condition -- skipping"
        continue
      fi

      page=$(deferred_fetch "$url")
      if [ -z "$page" ]; then
        log "deferred: ${key} gate url unreachable or not https (${url}) -- staying deferred, retry tomorrow"
        return 0
      fi

      raw=$(deferred_check "$model" "$condition" "$page") \
        || { log "deferred: ${key} gate check call failed -- staying deferred"; return 0; }
      verdict=$(deferred_parse_verdict "$raw")
      if [ "$verdict" = "MET" ]; then
        evidence=$(deferred_parse_evidence "$raw")
        deferred_release_to_reviewer "$repo" "$n" "$reviewer" "$evidence"
        log "deferred: ${key} gate MET -- held for ${reviewer:-reviewer} triage (dropped Status/Blocked + Agent)"
      else
        log "deferred: ${key} gate still UNMET -- re-check tomorrow"
      fi
      return 0   # one gate-check per tick
    done < <(jq -r --arg g "$DEFERRED_GATE_OPEN" \
               '.[]? | select((.body // "") | contains($g)) | .number' <<<"$issues" 2>/dev/null)
  done <<<"$ANALYSIS_REPOS_JSON"

  return 1
}
