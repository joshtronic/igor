#!/usr/bin/env bash
# needsyou.sh -- the event-driven "needs you" notification: fires the moment
# something ENTERS the set of things only the operator can unblock (a PR
# awaiting human review, an issue gaining Status/Blocked or Status/Need More
# Info, a CEO proposal/question awaiting a greenlight, a systemd unit gone
# failed). Silent when the set is unchanged; silent when something LEAVES it.
#
# This module is PURE: given a items array (each {id, repo, why, url, since})
# it diffs against the last-notified id set, renders, and persists -- so it
# unit-tests off fixtures, like lib/ship-report.sh. The Forgejo/systemctl
# GATHERING that builds the items array lives in do_needsyou_tick in
# bin/tick.sh, same split as shipreport_build vs do_shipreport_tick.
#
# Dedup is by stable id (e.g. "pr:acme/x#12", "issue:acme/x#7"), not by
# content -- an item that leaves and later re-enters the set is a genuinely
# new event and notifies again.

# Fallback logger so this module is sourceable standalone (tests).
if ! declare -F log >/dev/null; then log() { printf '[agent] %s\n' "$*"; }; fi

_needsyou_state_file() { echo "${AGENT_STATE_DIR:-$HOME/.local/state/agent}/discretionary-state.json"; }

# needsyou_add_item <items_json> <id> <repo> <why> <url> <since_epoch>
# Appends one item and echoes the updated array. <since_epoch> is when the
# underlying thing actually started waiting (PR/issue created_at, systemd's
# ActiveEnterTimestamp) -- NOT when we happened to notice it -- so the wait
# time in the notification is real, not "since this tick ran".
needsyou_add_item() {
  local items="$1" id="$2" repo="$3" why="$4" url="$5" since="$6"
  jq -c --arg id "$id" --arg repo "$repo" --arg why "$why" --arg url "$url" --argjson since "$since" \
    '. + [{id:$id, repo:$repo, why:$why, url:$url, since:$since}]' <<<"$items"
}

# needsyou_current_ids <items_json> -- the ids of the CURRENT set, sorted.
# This becomes the next persisted "seen" state verbatim: an id that vanishes
# (the item left the set) is simply not carried forward, so a later
# re-entrance under the same id notifies again instead of staying suppressed.
needsyou_current_ids() {
  jq -c '[.[].id] | sort' <<<"$1"
}

# needsyou_new_items <prev_ids_json> <items_json> -- the subset of the
# current items whose id was NOT in the previously-notified set. This is the
# entire notify decision: empty means stay silent (unchanged or something
# only left), non-empty means an addition just happened.
needsyou_new_items() {
  local prev_ids="$1" items="$2"
  jq -c --argjson prev "$prev_ids" '[ .[] | . as $it | select(($prev | index($it.id)) == null) ]' <<<"$items"
}

# needsyou_load_ids <state_file> -- the previously-notified id set, or [].
needsyou_load_ids() {
  local state_file="$1"
  [ -f "$state_file" ] || { echo '[]'; return; }
  jq -c '.needsyou.ids // []' "$state_file" 2>/dev/null || echo '[]'
}

# needsyou_save_ids <state_file> <ids_json> -- REPLACE (not merge) the
# notified set with the current reality, so a departed id is dropped.
needsyou_save_ids() {
  local state_file="$1" ids="$2" tmp
  [ -f "$state_file" ] || echo '{}' > "$state_file"
  tmp=$(mktemp)
  if jq --argjson ids "$ids" '.needsyou.ids = $ids' "$state_file" > "$tmp" 2>/dev/null; then
    mv "$tmp" "$state_file"
  else
    rm -f "$tmp"
  fi
}

# needsyou_fmt_wait <since_epoch> <now_epoch> -- a short human wait tag:
# "just now" / "5m" / "3h" / "3d". A PR that has sat three days reads as a
# different message from one that landed a minute ago (the whole point of
# carrying `since` on every item instead of just a boolean).
needsyou_fmt_wait() {
  local since="$1" now="$2" secs
  secs=$(( now - since ))
  [ "$secs" -lt 0 ] && secs=0
  if   [ "$secs" -lt 60 ];    then printf 'just now'
  elif [ "$secs" -lt 3600 ];  then printf '%dm' $(( secs / 60 ))
  elif [ "$secs" -lt 86400 ]; then printf '%dh' $(( secs / 3600 ))
  else                             printf '%dd' $(( secs / 86400 ))
  fi
}

# needsyou_render_text <now_epoch> -- plain-text body, items on stdin,
# grouped by repo (one header per repo, items sorted so a group is
# contiguous).
needsyou_render_text() {
  local now="$1" items; items=$(cat)
  printf 'NEEDS YOU\n=========\n\n'
  if [ "$(jq 'length' <<<"$items" 2>/dev/null || echo 0)" -eq 0 ]; then
    printf '(nothing needs you)\n'
    return
  fi
  local repo why url since last_repo="" wait
  while IFS=$'\t' read -r repo why url since; do
    [ -n "$repo" ] || continue
    if [ "$repo" != "$last_repo" ]; then
      [ -n "$last_repo" ] && printf '\n'
      printf -- '-- %s --\n' "$repo"
      last_repo="$repo"
    fi
    wait=$(needsyou_fmt_wait "$since" "$now")
    printf '  * %s  (waiting %s)\n    %s\n' "$why" "$wait" "$url"
  done < <(jq -r 'sort_by(.repo)[] | [.repo, .why, .url, (.since|tostring)] | @tsv' <<<"$items" 2>/dev/null)
}

# needsyou_render_html <now_epoch> -- html body, items on stdin, same
# grouping as the text renderer.
needsyou_render_html() {
  local now="$1" items; items=$(cat)
  local wrap='font-family:-apple-system,Segoe UI,sans-serif;color:#222'
  printf '<div style="%s"><h2 style="margin:0 0 4px">Needs You</h2>' "$wrap"
  if [ "$(jq 'length' <<<"$items" 2>/dev/null || echo 0)" -eq 0 ]; then
    printf '<p style="color:#888"><em>nothing needs you</em></p></div>'
    return
  fi
  local repo why url since last_repo="" wait
  while IFS=$'\t' read -r repo why url since; do
    [ -n "$repo" ] || continue
    if [ "$repo" != "$last_repo" ]; then
      [ -n "$last_repo" ] && printf '</ul>'
      printf '<h3 style="border-bottom:1px solid #eee;padding-bottom:4px">%s</h3><ul>' \
        "$(jq -rn --arg r "$repo" '$r|@html')"
      last_repo="$repo"
    fi
    wait=$(needsyou_fmt_wait "$since" "$now")
    printf '<li><a href="%s">%s</a> &mdash; %s <span style="color:#888">(waiting %s)</span></li>' \
      "$url" "$(jq -rn --arg r "$repo" '$r|@html')" "$(jq -rn --arg w "$why" '$w|@html')" "$wait"
  done < <(jq -r 'sort_by(.repo)[] | [.repo, .why, .url, (.since|tostring)] | @tsv' <<<"$items" 2>/dev/null)
  printf '</ul></div>'
}
