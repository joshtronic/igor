# The forge API surface

`lib/forgejo.sh` is the only file that talks to the forge. `_fj`, the
low-level HTTP helper it defines, is private to that file — nothing
outside it calls `_fj` directly (enforced by `bin/test-forgejo-surface.sh`).
Every other file that needs something from the forge calls one of the named
operations below.

This list is the actual artifact: it is what this harness asks a forge to
do, in one place, instead of that surface being implicit in 71 scattered
`_fj` calls (igor#565). Operations are named for what the caller wants, not
the endpoint they happen to hit.

Adding a new need means adding a new named operation here — never a generic
`forgejo_raw_request`-style escape hatch, which would just recreate the
problem this file exists to solve.

The tables below are checked against `lib/forgejo.sh` by the same test, in
both directions: an operation defined without a row here fails, and so does
a row naming an operation that no longer exists. A surface doc nobody checks
drifts the first time someone adds an operation.

## Issues

| operation | needs from a forge |
| --- | --- |
| `forgejo_find_claimable` | list open, `Agent`-labeled issues on a repo, filterable by assignee/label |
| `forgejo_get_issue` | fetch one issue |
| `forgejo_append_issue_body` | read an issue, then replace its body (read-modify-write) |
| `forgejo_set_issue_body` | replace an issue's body outright |
| `forgejo_assign` | set an issue/PR's sole assignee |
| `forgejo_unassign_all` | clear an issue/PR's assignees |
| `forgejo_comment` | post a comment on an issue/PR |
| `forgejo_log_time` | log time spent against an issue/PR |
| `forgejo_open_issue` | create an issue |
| `forgejo_open_issue_assigned` | create an issue with an assignee and labels in one call |
| `forgejo_reopen_issue` | reopen a closed issue |
| `forgejo_close_issue` | close an issue |
| `forgejo_list_open_issues` | list a repo's open issues (not PRs), raw |
| `forgejo_list_open_issue_titles` | list a repo's open issue titles only |
| `forgejo_list_blocked_issues` | list open issues carrying a given label (`Status/Blocked`) |
| `forgejo_recent_closed_issues` | list a repo's recently updated closed issues |
| `forgejo_search_closed_issues` | search a repo's closed issues by query text |
| `forgejo_find_marked_issue` | find the most recent bot-authored issue whose body contains a marker string |
| `forgejo_my_assigned` | list every open issue assigned to the authenticated user, across all accessible repos |

## Labels

| operation | needs from a forge |
| --- | --- |
| `forgejo_add_label` | resolve a label name to id and attach it to an issue/PR |
| `forgejo_remove_label` | resolve a label name to id and detach it from an issue/PR |
| `forgejo_repo_has_label` | check whether a repo defines a label of a given name |
| `forgejo_list_labels` | list every label a repo defines |

## Pull requests

| operation | needs from a forge |
| --- | --- |
| `forgejo_open_pr` | create a PR (unassigned) and optionally request a reviewer |
| `forgejo_get_pr` | fetch one PR, including head/base branch info |
| `forgejo_edit_pr` | patch a PR's title and/or body |
| `forgejo_merge_pr` | merge a PR, with delete-branch-after-merge, surfacing the failure reason on rejection |
| `forgejo_pr_update_branch` | merge a PR's base branch into its head ("update branch") |
| `forgejo_find_pr_by_head` | find the open PR whose head is a given branch |
| `forgejo_my_assigned_prs` | list every open PR assigned to the authenticated user, across all accessible repos |
| `forgejo_list_open_bot_prs` | list a repo's open PRs by a given author, oldest-first |
| `forgejo_open_pulls_oldest` | list every open PR on a repo, oldest-first |
| `forgejo_closed_pulls_recent` | list a repo's closed PRs, most-recently-updated first |
| `forgejo_closed_pulls_all` | list every closed PR on a repo, oldest-first, paginated to completion (exit 2 = page cap, 1 = fetch failure) |
| `forgejo_open_prs` | list every open PR on a repo, paginated to completion |
| `forgejo_bot_prs_for_issue` | find bot PRs that close a given issue |
| `forgejo_prs_covering_issue` | (pure) filter a PR list down to ones covering a given issue |
| `forgejo_open_pr_covers_issue` | one-shot: list open PRs, then filter to ones covering a given issue |
| `forgejo_prs_on_branches` | (pure) filter a covering-PR list down to ones on given branches |
| `forgejo_pr_files` | list a PR's changed files with add/delete counts, paginated to completion |
| `forgejo_pr_diff` | fetch a PR's raw unified diff |
| `forgejo_pr_comments` | list a PR's conversation-tab (issue-level) comments |
| `forgejo_pr_review_comments` | list a PR's inline (file/line) review comments |
| `forgejo_pr_has_comment_containing` | count a user's comments on an issue/PR containing a substring |
| `forgejo_count_bot_comments_matching` | count a user's comments on an issue starting with a prefix |
| `forgejo_attach_pr_screenshots` | upload images from a directory and append a Screenshots section to a PR body |

## Reviews

| operation | needs from a forge |
| --- | --- |
| `forgejo_pr_reviews` | list every review on a PR, unfiltered |
| `forgejo_pr_non_bot_reviews` | list a PR's non-bot reviews, oldest-to-newest |
| `forgejo_pr_actionable_request_changes` | fetch a PR's latest non-bot review, if it's a live REQUEST_CHANGES |
| `forgejo_request_review` | request a reviewer on a PR |

## Commits, branches, CI

| operation | needs from a forge |
| --- | --- |
| `forgejo_get_branch` | fetch a branch's tip commit |
| `forgejo_get_commit` | fetch one commit object (sha, parents, message) |
| `forgejo_compare` | diff two refs (commits one has that the other doesn't) |
| `forgejo_recent_commit_subjects` | list the default branch's recent commit subject lines |
| `forgejo_recent_commits_raw` | list the default branch's recent commits, raw |
| `forgejo_commit_status` | fetch the combined CI status for a commit sha |
| `forgejo_action_job_log` | fetch the plain-text log for one CI job |
| `forgejo_failing_ci_logs` | fetch the failing CI job-log tails for a commit, formatted |

## Repo metadata

| operation | needs from a forge |
| --- | --- |
| `forgejo_repo_exists` | check whether a repo exists and is accessible |
| `forgejo_repo_get_file` | fetch a file's raw contents from a repo's default branch |
| `forgejo_repo_get_file_status` | fetch a file's contents, distinguishing "missing" from "couldn't check" |
| `forgejo_repo_list_dir` | list the entry names in a repo directory |
| `forgejo_repo_dir_has_match` | check whether a repo directory has any file matching a regex |
| `forgejo_attach_image` | upload one image as an issue/PR attachment |

## Bot identity / fleet

| operation | needs from a forge |
| --- | --- |
| `forgejo_whoami` | fetch the authenticated user's login |
| `forgejo_resolve_bot_user` | resolve the bot's login, with retry/backoff on a transient failure |
| `forgejo_list_bot_repos` | list every repo the authenticated user can push to |
