# AGENTS.md

This file is a stub. igor's actual worker-contract system prompt --
what an unattended issue-work session actually reads -- is sourced
live from the Distillery (`joshtronic/distillery`, skill
`worker-contract`) at `origin/master`, via `lib/context-source.sh`'s
last-good cache. There is no in-repo fallback (igor#485); editing
this file does not change what the worker sees.

This stub exists only so `bin/check-sync.sh` has a local document to
validate against when the Distillery cache is unseeded and
unreachable (a fresh host, or a CI container with no cache and no
Distillery SSH access) -- see the comment at the top of
`bin/check-sync.sh` for how it decides which document to check. It
carries only the OUTCOME sentinels that check-sync's tick.sh sync gate
looks for; it deliberately does not duplicate the worker-contract's
`agent-*.sh` helper references, so the helper-existence check is a
no-op in that fallback mode (the sourced worker-contract is the
authoritative check; see igor#487).

<!-- OUTCOME: pr -->
<!-- OUTCOME: report -->
<!-- OUTCOME: blocked -->
<!-- OUTCOME: noop -->
