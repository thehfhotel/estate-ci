# One pipeline, deploy as the final `needs:` job

ADR 0002, decision 5; plan item B5. Each repository has **one** main pipeline.
Deploy is its last job, reached through `needs:`, and the tested-tree check
decides whether the tests ahead of it run at all. This replaces a deploy
workflow chained to CI with `workflow_run` and a polling step.

## What it replaces, and why

The old shape: a CI workflow on push to `main`, and a separate deploy workflow
triggered by `workflow_run` when CI completes, which polls for its prerequisites.
On a shared runner pool that failed in a specific way. The deploy ran while its
CI was still queued, saw no finished prerequisite, and skipped or failed; the
fix for a production incident needed three deploy runs to land (ADR 0002,
context). A `workflow_run` workflow also runs against the default branch's latest commit,
which is not necessarily the commit CI tested, the wrong default for a job that
ships to production.

With `needs:` there is no polling and nothing to race. A queued test job keeps
the deploy job queued behind it; a failed one stops it; both are plain
dependencies in one run, in one place to read.

Also delete the separate push-to-main CI workflow when this pipeline is a
superset of it, so main does not run its checks twice (decision 5).

## The pipeline

One workflow file. `<sha>` is the 40-character pin of the estate-ci commit (see
the README on pinning).

```yaml
name: CI and deploy

on:
  pull_request:
  push:
    branches: [main]

# docs/concurrency.md. Per-commit group on push: this pipeline uses `route`, so
# no push may queue behind (and be replaced by) another. A `github.ref` group
# would let a newer push drop an older pending run, whose suites then never run
# on main. The deploy job's own group serializes the deploys.
concurrency:
  group: ${{ github.workflow }}-${{ github.event.pull_request.number || github.sha }}
  cancel-in-progress: ${{ github.event_name == 'pull_request' }}

permissions:
  contents: read

jobs:
  # Express lane, seconds: what does this change need?
  route:
    runs-on: [self-hosted, <site>]
    timeout-minutes: 5
    outputs:
      docs_only: ${{ steps.route.outputs.docs_only }}
      suites: ${{ steps.route.outputs.suites }}
    steps:
      - uses: actions/checkout@<sha>
        with:
          persist-credentials: false
      - id: route
        uses: thehfhotel/estate-ci/.github/actions/route@<sha>
        with:
          suites: |
            backend: backend/** Cargo.toml
            web: web/** package.json bun.lock

  # Push to main only: was this exact tree already tested green on a PR?
  tree:
    if: github.event_name == 'push'
    runs-on: [self-hosted, <site>]
    timeout-minutes: 5
    permissions:
      contents: read
      actions: read
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

  web:
    needs: [route, tree]
    # `tree` is skipped on a pull_request, and a skipped need skips its
    # dependents unless the `if` carries a status function: hence the
    # !failure() && !cancelled() on every job below.
    if: >-
      !failure() && !cancelled() &&
      needs.route.outputs.docs_only != 'true' &&
      fromJSON(needs.route.outputs.suites).web &&
      needs.tree.outputs.result != 'skip-tests'
    uses: thehfhotel/estate-ci/.github/workflows/bun-ci.yml@<sha>
    with:
      runner_labels: '["self-hosted","<site>"]'

  backend:
    needs: [route, tree]
    if: >-
      !failure() && !cancelled() &&
      needs.route.outputs.docs_only != 'true' &&
      fromJSON(needs.route.outputs.suites).backend &&
      needs.tree.outputs.result != 'skip-tests'
    runs-on: [self-hosted, <site>, heavy]
    timeout-minutes: 30
    steps:
      - uses: actions/checkout@<sha>
        with:
          persist-credentials: false
      - run: ./ci/backend-tests.sh

  # Pull request only: the last job of a green run vouches for the tree.
  record:
    needs: [route, web, backend]
    # Status functions first: a failed or cancelled job anywhere in the chain
    # stops it, and a need that was skipped (docs-only route, a suite not
    # selected) never counts as a pass. Record only when a suite really ran green.
    if: >-
      ${{ !failure() && !cancelled() &&
      github.event_name == 'pull_request' &&
      needs.route.outputs.docs_only != 'true' &&
      (needs.web.result == 'success' || needs.backend.result == 'success') }}
    runs-on: [self-hosted, <site>]
    timeout-minutes: 5
    steps:
      - uses: actions/checkout@<sha>
        with:
          persist-credentials: false
      - uses: thehfhotel/estate-ci/.github/actions/tested-tree@<sha>
        with:
          mode: record

  # Push to main only: the final job.
  deploy:
    needs: [route, tree, web, backend]
    if: >-
      github.event_name == 'push' &&
      !failure() && !cancelled() &&
      needs.route.outputs.docs_only != 'true'
    uses: thehfhotel/estate-ci/.github/workflows/deploy-evergreen.yml@<sha>
    permissions:
      contents: read
      packages: write
    with:
      app_name: <app>
      image_name: <app>
      host_port: "<port>"
      runner_labels: '["self-hosted","<site>"]'                  # deploy: express lane
      build_runner_labels: '["self-hosted","<site>","heavy"]'    # image build: heavy lane
    secrets:
      ssh_key: ${{ secrets.<APP>_DEPLOY_SSH_KEY }}
      host_key: ${{ secrets.EVERGREEN_HOST_KEY }}
```

What each event does:

| Event | route | tree | tests | record | deploy |
|---|---|---|---|---|---|
| `pull_request`, code change | picks suites | skipped | selected suites | runs after a green run | skipped |
| `pull_request`, docs only | `docs_only` | skipped | skipped | runs | skipped |
| push to `main`, tree already tested | picks suites | `skip-tests` | skipped | skipped | build and deploy |
| push to `main`, tree not tested | picks suites | `full` | selected suites | skipped | after green tests |
| push to `main`, docs only | `docs_only` | any | skipped | skipped | skipped |

## Reading `needs` correctly

`deploy` must run when a test job was **skipped** (the tree was already tested,
or the route said the suite is not needed) and must not run when one **failed**
or the run was cancelled. A job's `needs.<id>.result` is `success`, `failure`,
`cancelled` or `skipped`, and the `if` decides what to do with each:

- `!failure() && !cancelled()` is true when no job in the chain failed and the
  run was not cancelled; `success` and `skipped` both pass. That is the
  condition used above. Both are status functions, so they also switch off the
  implicit `success()`; no `always()` is needed with them.
- Without a status function in the `if:`, GitHub adds an implicit `success()`,
  and a skipped need then skips the job. Without `!failure()` but with `always()`
  alone, a failed test job lets the deploy through. That has reached production
  in this estate before; see the comments in `deploy-evergreen.yml`.
- If you prefer to read results explicitly, the equivalent is
  `needs.web.result == 'success' || needs.web.result == 'skipped'` for each test
  job, `&&`-ed together. It is longer and says the same thing.

A `tree` job that cannot decide still succeeds, with `full`, so a broken marker
never blocks a deploy: it only buys the tests back. Only a crash of the job
itself (a runner failure, say) fails it, and that rightly stops the deploy.

Two more rules for the `deploy` job:

- `needs:` lists **every** job that must be green, the test jobs and `route` and
  `tree`. A job missing from `needs:` is a job that cannot stop the deploy.
- `deploy-evergreen.yml` does not run tests and refuses a `pull_request` caller.
  The `needs:` and the `push` gate above are what keep a red or unreviewed tree
  off production.

A suite name with a `-` in it needs bracket access: `fromJSON(...)['web-app']`,
not `.web-app`.

A docs-only push skips the deploy, and a previous deploy that failed or was
dropped is not retried by it; re-run it with `force_deploy` (see the README).

Add `workflow_dispatch` to the deploy job's event check if the pipeline also
runs from the Actions tab (a forced re-roll uses `force_deploy`, see the README).

## When the tested-tree check hits

A hit needs the tree on `main` to equal the tree the PR run tested, which is the
tree of the merge ref at the time of that run. A rebase or squash merge of a PR
whose base has not moved since gives exactly that tree. If another PR merged in
between, the trees differ and `main` runs the full tests, which is correct and
costs one run. That is one reason a repository takes one merge at a time and
lets the previous main pipeline finish first (ADR decision 6).

## Migrating a repository

1. Merge the CI workflow and the deploy workflow into one pipeline as above;
   keep the repository's existing test jobs, putting short ones on the express
   lane and heavy ones on `heavy` (see the README on lanes).
2. Delete the `workflow_run` deploy workflow and its polling step, and the
   separate push-to-main CI workflow if this pipeline covers it.
3. Add the concurrency block (`docs/concurrency.md`; the per-commit group, since the pipeline uses `route`) and the `route`, `tree` and
   `record` jobs.
4. Make `deploy`'s `needs:` the complete list.
5. Watch the first merge: the `tree` log line and step summary say why it chose
   `skip-tests` or `full`.
