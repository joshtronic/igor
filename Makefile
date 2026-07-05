# Igor's harness -- developer-facing entry points.
#
# `make test` is the contract check CI runs on every PR.
# `make lint` is the optional fuller suite. Tools install via:
#   - shellcheck:   sudo apt install shellcheck
#   - markdownlint: sudo apt install markdownlint (provides the `mdl` binary)

.PHONY: test lint check-sync shellcheck markdownlint

test: check-sync

check-sync:
	bin/check-sync.sh

lint: shellcheck markdownlint

shellcheck:
	@command -v shellcheck >/dev/null || { echo "shellcheck not installed -- apt install shellcheck"; exit 1; }
	shellcheck bin/*.sh lib/*.sh

markdownlint:
	@command -v mdl >/dev/null || { echo "mdl not installed -- apt-get install markdownlint"; exit 1; }
	mdl .
