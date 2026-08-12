# Worker contract (CI-mode fallback)

The real worker contract is the Distillery's `worker-contract` skill,
sourced at runtime via `context_surface worker-contract`
(`lib/context-source.sh`, `lib/worker-doc.sh`). This file is only the
CI-mode sentinel fallback that `bin/check-sync.sh` validates against
when no prompt cache is seeded.

MANDATORY: security-review my own diff before exit -- the full
contract is the Distillery's worker-contract skill.

Helpers: `agent-block.sh`, `agent-report.sh`, `agent-ask.sh`.

<!-- OUTCOME: pr -->
<!-- OUTCOME: report -->
<!-- OUTCOME: blocked -->
<!-- OUTCOME: noop -->
