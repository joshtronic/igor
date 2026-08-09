#!/usr/bin/env bash
# dossier.sh -- the machine half of docs/agents-md-spec.md.
# dossier_get/dossier_get_repo/dossier_keys are the RUNTIME reader (falls
# back to legacy agent.json when a repo has no root AGENTS.md, so call sites
# can switch without a behavior change) -- both dossier_get (checkout dir)
# and dossier_get_repo (Forgejo API, no clone) share the same core lookup,
# dossier_get_content, which callers with content already in hand (e.g.
# lib/repo-checks.sh's git-show-based reads) can call directly too.
# dossier_validate is the STRUCTURAL check lib/repo-checks.sh's check_dossier
# runs against a root AGENTS.md's content -- absent-vs-nonconforming is
# check_dossier's call, not this function's. No YAML dependency -- the block
# is flat so grep/awk/bash parse it without one.
#
# Both filenames are HARDCODED: root AGENTS.md per the spec, and the legacy
# fallback is literally `agent.json`, NOT $AGENT_CONFIG_FILE. Callers moved
# onto these readers (automerge, feedback) therefore stop honoring that var
# -- deliberate, since the fallback exists only to read what the fleet has on
# disk today, and it goes away entirely once every repo adopts the dossier.

# All three lists are lifted verbatim from docs/agents-md-spec.md: the keys
# are the table in "The Metadata block"; DOSSIER_TYPES and DOSSIER_SITE_TYPES
# are the `type` closed list in the paragraph directly under that table
# (site types serve a live domain and therefore require `url`).
DOSSIER_KEYS="type url test lint verify feedback-csv"
DOSSIER_TYPES="arcade game content tool api personal infra"
DOSSIER_SITE_TYPES="arcade game content api personal"

# _dossier_trim_blank <lines-on-stdin> -- drop leading/trailing blank lines.
_dossier_trim_blank() {
  awk '{a[NR]=$0} END{s=1; e=NR; while(s<=e && a[s]~/^[[:space:]]*$/) s++; while(e>=s && a[e]~/^[[:space:]]*$/) e--; for(i=s;i<=e;i++) print a[i]}'
}

# _dossier_trim <string> -- echoes with leading/trailing whitespace stripped.
_dossier_trim() {
  local s="$1"
  s="${s#"${s%%[![:space:]]*}"}"
  s="${s%"${s##*[![:space:]]}"}"
  printf '%s' "$s"
}

# _dossier_metadata_block <agents-md-content>
# Echoes the raw lines inside the FIRST fenced code block after the literal
# "## Metadata" heading. Empty + rc 1 if the heading, or a fence immediately
# following it (blank lines allowed in between), is missing.
_dossier_metadata_block() {
  local content="$1" post fence marker body n
  post=$(awk '/^## Metadata$/{f=1; next} f' <<<"$content" | _dossier_trim_blank)
  [ -n "$post" ] || return 1
  fence=$(head -1 <<<"$post")
  [[ "$fence" =~ ^(\`\`\`+|~~~+) ]] || return 1
  marker="${BASH_REMATCH[1]}"
  body=$(tail -n +2 <<<"$post")
  n=$(grep -nxF "$marker" <<<"$body" | head -1 | cut -d: -f1)
  [ -n "$n" ] || return 1
  [ "$n" -gt 1 ] && head -n $((n - 1)) <<<"$body"
  return 0
}

# dossier_get_content <agents_md_content> <agent_json_content> <key>
# The core lookup shared by every runtime consumer: dossier_get (checkout
# dir, below), dossier_get_repo (Forgejo API, no clone -- lib/automerge.sh,
# lib/feedback.sh), and check_deploy_smoke_signal (the local anchor clone via
# rc_file_read/git-show -- lib/repo-checks.sh). Same value contract
# everywhere: echoes the value + rc0, or empty + rc1. Falls back to legacy
# agent.json (url <- .smoke.url, feedback-csv <- .feedback.csv) when the repo
# hasn't adopted the dossier -- no AGENTS.md content, or a prose one with no
# `## Metadata` (same keying as check_dossier's rc2). Empty + rc 1 when the
# key is absent, or when an adopted dossier's block is unreadable.
dossier_get_content() {
  local agents_content="$1" cfg_content="$2" key="$3"
  local block line value
  if [ -n "$agents_content" ] && dossier_is_declared "$agents_content"; then
    block=$(_dossier_metadata_block "$agents_content") || return 1
    line=$(grep -E "^${key}:" <<<"$block" | head -1) || true
    [ -n "$line" ] || return 1
    value="${line#*:}"
    value="$(_dossier_trim "$value")"
    [ -n "$value" ] || return 1
    printf '%s\n' "$value"
    return 0
  fi
  [ -n "$cfg_content" ] || return 1
  case "$key" in
    url)          value=$(jq -r '.smoke.url // empty' <<<"$cfg_content" 2>/dev/null) ;;
    feedback-csv) value=$(jq -r '.feedback.csv // empty' <<<"$cfg_content" 2>/dev/null) ;;
    *) return 1 ;;
  esac
  value="$(_dossier_trim "$value")"
  [ -n "$value" ] || return 1
  printf '%s\n' "$value"
}

# dossier_get <checkout_dir> <key> -- dossier_get_content sourced from real
# files on disk. See dossier_get_content for the value contract.
dossier_get() {
  local dir="$1" key="$2" agents cfg agents_content cfg_content
  agents="$dir/AGENTS.md"; cfg="$dir/agent.json"
  agents_content=""; [ -f "$agents" ] && agents_content=$(cat "$agents")
  cfg_content=""; [ -f "$cfg" ] && cfg_content=$(cat "$cfg")
  dossier_get_content "$agents_content" "$cfg_content" "$key"
}

# dossier_get_repo <repo> <key> -- dossier_get_content sourced from a repo's
# Forgejo contents API (no clone needed) -- for callers with no local
# checkout, like lib/automerge.sh and lib/feedback.sh. Needs
# forgejo_repo_get_file (lib/forgejo.sh) already sourced. See
# dossier_get_content for the value contract. The legacy config is fetched
# ONLY when the dossier won't answer, so an adopted repo costs one API call
# per lookup rather than two.
dossier_get_repo() {
  local repo="$1" key="$2" agents_content cfg_content
  agents_content=$(forgejo_repo_get_file "$repo" AGENTS.md 2>/dev/null) || agents_content=""
  if [ -n "$agents_content" ] && dossier_is_declared "$agents_content"; then
    dossier_get_content "$agents_content" "" "$key"
    return
  fi
  cfg_content=$(forgejo_repo_get_file "$repo" agent.json 2>/dev/null) || cfg_content=""
  dossier_get_content "" "$cfg_content" "$key"
}

# dossier_keys <checkout_dir> -- lists the keys present, one per line. Same
# two sources, and the same adoption keying, as dossier_get. Empty + rc 1 if
# neither source has any key.
dossier_keys() {
  local dir="$1" agents cfg content block keys found=1
  agents="$dir/AGENTS.md"; cfg="$dir/agent.json"
  if [ -f "$agents" ] && dossier_is_declared "$(cat "$agents")"; then
    content=$(cat "$agents")
    block=$(_dossier_metadata_block "$content") || return 1
    # Key syntax per the spec's flat `key: value` rule -- no leading
    # whitespace, matching dossier_get and _dossier_validate_metadata (an
    # indented key must not be listed here as readable when neither of those
    # can actually read it). This is the UNVALIDATED read path
    # (dossier_validate may never have run), so a malformed block yields no
    # keys rather than junk ones.
    keys=$(sed -nE 's/^([a-z][a-z-]*):.*$/\1/p' <<<"$block")
    [ -n "$keys" ] || return 1
    printf '%s\n' "$keys"
    return 0
  fi
  [ -f "$cfg" ] || return 1
  [ -n "$(jq -r '.smoke.url // empty' "$cfg" 2>/dev/null)" ]      && { echo url; found=0; }
  [ -n "$(jq -r '.feedback.csv // empty' "$cfg" 2>/dev/null)" ]   && { echo feedback-csv; found=0; }
  return $found
}

# -- Structural spec validation -----------------------------------

# dossier_validate <root-agents-md-content>
# Checks against the spec's "Required structure" + "Validation contract"
# sections. Prints nothing and returns 0 when it conforms; on failure prints
# ONE greppable reason line to stdout and returns 1.
dossier_validate() {
  local content="$1" h1 heading_texts ok=1 v
  # The four legal H2 sequences enumerated by the spec's "Required
  # structure": KPIs and Metadata required, DOs and DON'Ts and Caveats
  # optional, Metadata always last.
  local -a valid_seqs=(
    "KPIs
Metadata"
    "KPIs
DOs and DON'Ts
Metadata"
    "KPIs
Caveats
Metadata"
    "KPIs
DOs and DON'Ts
Caveats
Metadata"
  )

  h1=$(head -1 <<<"$content")
  [[ "$h1" =~ ^#[[:space:]] ]] || { echo "dossier: missing H1 heading on line 1"; return 1; }

  heading_texts=$(sed -nE 's/^## (.*)$/\1/p' <<<"$content")
  for v in "${valid_seqs[@]}"; do [ "$heading_texts" = "$v" ] && ok=0 && break; done
  if [ "$ok" -ne 0 ]; then
    echo "dossier: section headings out of spec order or unrecognized -- got: $(tr '\n' '|' <<<"$heading_texts")"
    return 1
  fi

  _dossier_validate_kpis "$content" || return 1
  _dossier_validate_metadata "$content" "$h1" || return 1
  return 0
}

_dossier_validate_kpis() {
  local content="$1" kpi trimmed line any_item=1
  kpi=$(awk '/^## KPIs$/{f=1; next} /^## / && f{exit} f' <<<"$content")
  trimmed=$(_dossier_trim_blank <<<"$kpi")
  [ "$trimmed" = "(none yet)" ] && return 0
  if [ -z "$trimmed" ]; then
    echo "dossier: KPIs section is empty -- use '(none yet)' or list entries with a measurement source"
    return 1
  fi
  while IFS= read -r line; do
    [[ "$line" =~ ^[[:space:]]*([0-9]+\.|[-*])[[:space:]]+ ]] || continue
    any_item=0
    [[ "$line" =~ (--|—|–|,) ]] || { echo "dossier: KPI entry missing a measurement source (--, en/em dash, or comma): $line"; return 1; }
  done <<<"$trimmed"
  if [ "$any_item" -ne 0 ]; then
    echo "dossier: KPIs section has content but no list entries and isn't '(none yet)'"
    return 1
  fi
  return 0
}

_dossier_validate_metadata() {
  local content="$1" h1="$2" post fence marker body n block after
  local line k v type_val="" url_val="" host name
  post=$(awk '/^## Metadata$/{f=1; next} f' <<<"$content" | _dossier_trim_blank)
  [ -n "$post" ] || { echo "dossier: ## Metadata section has no fenced code block"; return 1; }
  fence=$(head -1 <<<"$post")
  if ! [[ "$fence" =~ ^(\`\`\`+|~~~+) ]]; then
    echo "dossier: ## Metadata must open with a fenced code block"
    return 1
  fi
  marker="${BASH_REMATCH[1]}"
  body=$(tail -n +2 <<<"$post")
  n=$(grep -nxF "$marker" <<<"$body" | head -1 | cut -d: -f1)
  [ -n "$n" ] || { echo "dossier: Metadata fenced code block never closes"; return 1; }
  block=""; [ "$n" -gt 1 ] && block=$(head -n $((n - 1)) <<<"$body")
  after=$(tail -n +$((n + 1)) <<<"$body")
  if grep -qE '[^[:space:]]' <<<"$after"; then
    echo "dossier: content follows the Metadata fenced block -- Metadata must be last, with exactly one block"
    return 1
  fi

  while IFS= read -r line; do
    [[ "$line" =~ ^[[:space:]]*$ ]] && continue
    if ! [[ "$line" =~ ^([a-z][a-z-]*):[[:space:]]?(.*)$ ]]; then
      echo "dossier: Metadata line is not a flat 'key: value' scalar: $line"
      return 1
    fi
    k="${BASH_REMATCH[1]}"; v="$(_dossier_trim "${BASH_REMATCH[2]}")"
    case " $DOSSIER_KEYS " in *" $k "*) ;; *) echo "dossier: unknown Metadata key: $k"; return 1 ;; esac
    case "$k" in
      type) type_val="$v" ;;
      url)  url_val="$v" ;;
    esac
  done <<<"$block"

  [ -n "$type_val" ] || { echo "dossier: Metadata missing required key: type"; return 1; }
  case " $DOSSIER_TYPES " in
    *" $type_val "*) ;;
    *) echo "dossier: Metadata type is not in the closed list: $type_val"; return 1 ;;
  esac
  case " $DOSSIER_SITE_TYPES " in
    *" $type_val "*)
      [ -n "$url_val" ] || { echo "dossier: Metadata type '$type_val' is a site type and requires url"; return 1; }
      host="${url_val#*://}"; host="${host%%/*}"; host="${host#www.}"
      name="$(_dossier_trim "${h1#\#}")"
      if [ "$host" != "$name" ]; then
        echo "dossier: H1 '$name' does not match url host '$host'"
        return 1
      fi
      ;;
  esac
  return 0
}

# dossier_is_declared <agents-md-content>
# 0 when the file declares itself a dossier -- i.e. carries the literal
# "## Metadata" heading. The migration gate keys on THIS, not on the file
# existing: a root AGENTS.md is the near-universal prose convention (this
# repo's own is one), and a repo carrying one without a Metadata block simply
# hasn't adopted the spec yet. See the spec's "Un-adopted vs nonconforming".
dossier_is_declared() {
  grep -qxF '## Metadata' <<<"$1"
}

# dossier_check_no_nested_metadata <nested-agents-md-content>
# 0 (pass) when the content has no "## Metadata" heading -- required for
# every non-root AGENTS.md file, since only the root dossier is
# machine-readable.
dossier_check_no_nested_metadata() {
  ! dossier_is_declared "$1"
}
