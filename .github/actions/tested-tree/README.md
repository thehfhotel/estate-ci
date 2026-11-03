# tested-tree

Skip the second full test run of a tree that already passed. ADR 0002,
decision 3: after a merge, the main pipeline compares `HEAD^{tree}` with the
trees PR CI already tested green. A match means build, deploy and smoke only.

Two modes, one action:

| Mode | Runs | Does |
|---|---|---|
| `record` | last job of a green `pull_request` run, after every test job | writes the tree hash of the merge ref it tested to a marker file, and posts it as a commit status on the PR head |
| `check` | first job of the `push` to main pipeline | outputs `skip-tests` or `full` |

Two proofs, one verification. The marker file lives on the runner box that ran
`record`. When jobs of one pipeline can land on different boxes, `check` may run
where there is no marker; it then finds the proof in the commit status instead.
Either way the same API verification decides (see "Why `check` is hardened").

## Use

```yaml
# pull_request: the last job, after every test job. Record only when the tests
# actually SUCCEEDED: a skipped or failed suite must never vouch for a tree.
record:
  needs: [route, test-backend, test-web]     # every job whose result you rely on
  # !failure() && !cancelled() first: nothing is recorded when a job failed or the
  # run was cancelled, and a skipped need (docs-only route) is never a pass. The
  # contains() guards also catch one need cancelled on its own beside a green one.
  if: >-
    ${{ !failure() && !cancelled() &&
    !contains(needs.*.result, 'failure') && !contains(needs.*.result, 'cancelled') &&
    github.event_name == 'pull_request' &&
    needs.route.outputs.docs_only != 'true' &&
    (needs.test-backend.result == 'success' || needs.test-web.result == 'success') }}
  runs-on: [self-hosted, <site>]             # express lane, and NOT a job container
  timeout-minutes: 5
  permissions:
    contents: read
    statuses: write                          # optional: the cross-box commit status
  steps:
    - uses: actions/checkout@<sha>           # default ref: the merge commit (record checks HEAD is it)
      with:
        persist-credentials: false
    - uses: thehfhotel/estate-ci/.github/actions/tested-tree@<sha>
      with:
        mode: record

# push to main: the first job; the test jobs run unless it says skip-tests
tree:
  if: github.event_name == 'push'
  runs-on: [self-hosted, <site>]
  timeout-minutes: 5
  permissions:
    contents: read                           # the merge commit
    actions: read                            # the recorded run
    pull-requests: read                      # commit -> merged PR (no-marker path)
    statuses: read                           # the PR head's statuses (no-marker path)
  outputs:
    result: ${{ steps.tree.outputs.result }}
  steps:
    - uses: actions/checkout@<sha>
      with:
        persist-credentials: false
    - id: tree
      uses: thehfhotel/estate-ci/.github/actions/tested-tree@<sha>
      with:
        mode: check
```

Skipped suites (the route said a suite is not needed) count as tested only when
at least one suite really ran green; if `route` said docs-only, or no test job
succeeded, record nothing. Test jobs on the push side gate on `needs.tree.outputs.result != 'skip-tests'`. The whole
pipeline, deploy as the final `needs:` job included, is in
`docs/final-deploy-needs.md`.

## Permissions

Declare them on the job; a job with a `permissions:` block gets nothing it does
not list.

| Job | Permission | Why |
|---|---|---|
| `record` | `contents: read` | checkout |
| `record` | `statuses: write` | post the `estate-ci/tested-tree` commit status. Optional: without it the POST is refused, a warning is logged and only the local marker is written (the result is still `recorded`) |
| `check` | `contents: read` | checkout; read the merge commit |
| `check` | `actions: read` | read the recorded run |
| `check` | `pull-requests: read` | "List pull requests associated with a commit" (no-marker path) |
| `check` | `statuses: read` | "List commit statuses for a reference" (no-marker path) |

Per GitHub's REST permission tables, "List pull requests associated with a
commit" needs the *Pull requests* read permission and "List commit statuses for
a reference" needs the *Commit statuses* read permission (workflow keys
`pull-requests` and `statuses`); on a private repository `contents: read` alone
covers neither. The last two matter only when the box has no marker; a `check`
job that lacks them still works wherever the marker is local, and otherwise
answers `full` with a reason that names the missing permission.

## Outputs

| Output | `record` | `check` |
|---|---|---|
| `result` | `recorded` or `noop` | `skip-tests` or `full` |
| `skip` | `'false'` | `'true'` only when `result` is `skip-tests` |
| `reason` | one line | one line: why it decided what it did |

The reason is also printed in the log as `tested-tree: mode=... reason: ...`
and appended to the step summary, so a deploy that skipped its tests says which
PR run vouched for the tree.

## When it hits

A hit needs the tree on `main` to equal the tree of the merge ref the PR run
tested. A rebase or squash merge of a PR whose base has not moved gives exactly
that. If another PR merged in between, the trees differ and `main` runs the full
tests; that is correct, and it costs one run. Merging one PR at a time per
repository (ADR 0002, decision 6) keeps the hit rate high.

## Commit status

`record` also posts, on the PR head SHA (`github.event.pull_request.head.sha`),
`POST /repos/{repo}/statuses/{head_sha}`:

| Field | Value |
|---|---|
| `state` | `success` |
| `context` | `estate-ci/tested-tree` |
| `target_url` | the run URL |
| `description` | `run=<run_id> attempt=<run_attempt> merge=<merge_commit_sha> tree=<tree_sha>` (about 110 characters; GitHub allows 140, and a longer description is not posted) |

Nothing is posted for a fork PR, for any event but `pull_request`, or when the
head SHA is unavailable. A refused POST (no `statuses: write`) is a warning, not
a failure. The status shows up as a check on the PR; it is informational, so do
not make it a required check.

`check`, when this box has no marker for `HEAD^{tree}`: lists the merged PRs of
`GITHUB_SHA` (`GET /repos/{repo}/commits/{sha}/pulls`; same-repository PRs only,
first three), reads each PR head's statuses (newest first, up to three pages of
100), keeps the `estate-ci/tested-tree` successes whose four fields parse
strictly (digits for run and attempt, 40 lowercase hex for merge and tree) and
whose tree equals `HEAD^{tree}`, and runs the same verification as for a marker,
plus one more condition: the run's `head_sha` must be that PR head. A present
but bad local marker is not rescued by a status; the status path is for a
missing marker only. Squash, rebase and merge-commit merges all resolve to their
PR through the commits endpoint.

## Marker

`${HF_CI_CACHE}/shared/tested-trees/<owner>__<repo>/<tree-sha>`, JSON:

```json
{"run_id": 123, "run_attempt": 1, "repository": "owner/repo",
 "merge_commit_sha": "<merge ref commit>", "tree_sha": "<its tree>"}
```

`record` writes it atomically (temp file, then rename) from
`git rev-parse "$GITHUB_SHA^{tree}"`; for `pull_request`, `GITHUB_SHA` is the
merge commit. It writes nothing for a fork PR, for any event but
`pull_request`, or when `HF_CI_CACHE` is unset. It never fails the job.

## Why `check` is hardened

A PR run executes the PR branch's own workflow files, so a marker file on disk
is only a claim: that workflow could write one without testing anything, or
name some other, older green run. `check` trusts a marker only after the GitHub
API confirms all of:

1. the recorded run attempt exists in **this** repository, its head repository
   is this repository (no fork), it is `completed`, its event is `pull_request`,
   its conclusion is `success`, and the attempt number matches;
2. the recorded merge commit exists and its tree SHA equals `HEAD^{tree}`;
3. **the run produced that merge commit**: the run's `head_sha` (the PR head
   commit) is one of the merge commit's parents. Without this tie, a marker
   could pair any old green run with an untested merge commit that happens to
   have the right tree;
4. the marker file itself parses, names this repository, and carries the tree
   it is filed under.

On the commit-status path, steps 1 to 3 are the same and step 4 is replaced by
the strict parse above, plus: the run's `head_sha` is the head of the PR the
status was read from. A status is, like a marker, only a claim: anyone who can
write statuses can post one, and it counts for nothing unless the run it names
verifies.

The token is handed to `curl` through a config on stdin, never on its command
line.

**Fail closed.** No proof at all (no marker, and no matching status), unparsable JSON, a malformed field, an API
error, a mismatch, an unset `HF_CI_CACHE`, a missing `jq` or `curl`, a missing
token, or an event that is not `push` all output `full`. The only path to
`skip-tests` is every check passing. Note what this does not stop: someone with
write access can still make a workflow that is green without testing; the check
raises the bar from "write a file or a status" to "get a green PR run that produced a merge
commit with that exact tree". Markers are plain files writable by any job on the
same runner user, which is acceptable inside one organisation because a forged
marker still needs a parent-bound green run to pass `check`.
Because the conclusion is the whole run's, a PR run with an unrelated red job
yields no usable marker, and the main run tests in full. That is the safe side.

If the merge commit has been garbage collected by the time the API is asked
(a very old PR), the answer is `full`.

## Host requirements

These are not this action's job; they are what the runner host must provide.

- `HF_CI_CACHE` exported on the runners (still required by both modes). Where
  it is bind-mounted at the identical absolute path on every runner (see
  `runner/README.md`, "A shared cache root across runners"), a marker written by
  one runner is visible to every other on that box. Across boxes the marker is
  not shared; the commit status carries the proof instead.
- The host hook (`runner/hooks`) prunes markers after 30 days, by mtime,
  including stray `.tmp.*` files. The action never deletes markers.
- `jq` and `curl` on the runner image (both are in `runner/Dockerfile`).
- A job container (`container:`) does not see `HF_CI_CACHE`: run both jobs
  directly on the runner.

## Testing

`bash .github/actions/tested-tree/test.sh` (needs `jq`, `curl`, `python3`):
a throwaway repo, a cache directory and a mock API (which also records the
status POSTs). It covers `record` with and without `statuses: write`, the marker
`skip-tests` path, the commit-status `skip-tests` path and every `full` path. Nothing runs it in CI; run it by hand
after touching `tested-tree.sh`.
