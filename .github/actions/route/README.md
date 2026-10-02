# route

Path-based suite selection, built for a tiny first job on the **express lane**
(the runner without the `heavy` label). It decides, from the files a change
touches, whether tests are needed at all and which suites. ADR 0002, decision 5
("a `route` job decides which suites the change needs; a change that touches only
docs skips the work inside each job").

It fails **open**. Anything it cannot determine outputs "run everything": no
base commit (first push, new branch, `workflow_dispatch`, `schedule`), a base it
cannot fetch, an empty diff, a changed file that no suite claims. It never skips
tests on a guess.

## Use

```yaml
on:
  pull_request:
  push:
    branches: [main]

jobs:
  route:
    runs-on: [self-hosted, <site>]          # express lane: no `heavy`
    timeout-minutes: 5
    permissions:
      contents: read
    outputs:
      docs_only: ${{ steps.route.outputs.docs_only }}
      suites: ${{ steps.route.outputs.suites }}
    steps:
      - uses: actions/checkout@<sha>
        with:
          persist-credentials: false         # fine: the action authenticates its own fetch
      - id: route
        uses: thehfhotel/estate-ci/.github/actions/route@<sha>
        with:
          suites: |
            backend: backend/** Cargo.toml
            web:     web/** package.json bun.lock
          shared-globs: |
            .github/workflows/**
            .github/actions/**
            Cargo.lock

  test-backend:
    needs: [route]
    if: needs.route.outputs.docs_only != 'true' && fromJSON(needs.route.outputs.suites).backend
    runs-on: [self-hosted, <site>, heavy]
    steps: [...]
```

For one test job per selected suite, feed `suite_list` to a matrix:
`matrix: { suite: "${{ fromJSON(needs.route.outputs.suite_list) }}" }`. An empty
list makes GitHub fail the matrix job, so guard the job with
`if: needs.route.outputs.docs_only != 'true' && needs.route.outputs.suite_list != '[]'`.

A skipped job counts as success for `needs`, so a docs-only change goes green
with every test job skipped. See `docs/final-deploy-needs.md` for how a deploy
job reads that correctly.

## Inputs

| Input | Default | Meaning |
|---|---|---|
| `suites` | empty | One suite per line, `name: glob [glob...]`. Empty means no suites: only `docs_only` is computed. |
| `docs-globs` | `**/*.md`, `docs/**`, `LICENSE*`, issue and PR templates | A change is docs-only when every changed file matches one of these. |
| `shared-globs` | `.github/workflows/**`, `.github/actions/**` | Any match turns **every** suite on. Add lockfiles and shared config. |
| `unmatched` | `all` | A changed file that is neither docs nor in any suite: `all` runs everything (the safe default), `none` ignores it. |
| `base-sha` | derived | Commit to diff against. Derived from the event: the PR base for `pull_request`, the previous tip (`github.event.before`) for `push`. |
| `token` | `github.token` | Used to fetch the base commit. `contents: read` is enough. |

Glob syntax, anchored at the repository root: `**/` crosses any number of
directories (or none), `**` matches anything, `*` and `?` do not cross a `/`, a
trailing `/` means everything below. No brace expansion and no character
classes: list the globs separately.

### Services that hold a person-started session

Some services keep a session that only a person can open again, such as a
login someone must confirm by hand. Restarting one costs that person a round
trip, so it must never be rebuilt or redeployed as a side effect. For every
such service:

- **Gate it on its own suite *and* `run_all != 'true'`.** `run_all` is true
  on a shared hit, on an unclaimed file under `unmatched: all`, and in every
  fail-open case (no base, a first push or new branch, `workflow_dispatch`,
  `schedule`, a base that cannot be fetched, an empty diff). For example:
  `fromJSON(needs.route.outputs.suites).svc && needs.route.outputs.run_all != 'true'`.
  `suite_list` also includes the service whenever `run_all` is true. A diff
  that trips `run_all` therefore holds back the service's own change too;
  ship it through a `workflow_dispatch` input that selects the service by
  name (a dispatch alone does not pass the gate: `route` reports
  `run_all=true` there).
- **Keep `run_all` rare.** Point `shared-globs` at a path that never exists
  (do not pass an empty value: GitHub then applies the input's default, which
  is the workflow globs) and add the workflow globs to the suites that really
  need to re-run on a CI change. Claim every other path in some suite, or set
  `unmatched: none`. Otherwise workflow edits and unclaimed files trip
  `run_all`.
- **List it per repo.** Name the service in the calling workflow's header so
  the next editor sees the rule.
- **Prove it per PR.** Record the `route` job's `suites` output (or its
  `route: ...` log line) for the PR, showing the service's suite is `false`.
  After the deploy, confirm the container's start time did not change.

## Outputs

| Output | Meaning |
|---|---|
| `docs_only` | `'true'` when every changed file is documentation. |
| `run_all` | `'true'` when the action could not narrow the change; every suite is then `true`. |
| `suites` | JSON object, suite name to boolean: `{"backend":true,"web":false}`. Always has every mapped suite. |
| `suite_list` | JSON array of the selected suite names, for a matrix. |
| `changed_count` | Number of changed files (0 when no diff was computed). |
| `reason` | One line saying why. Also printed in the log as `route: ...`. |

## How it works

1. Picks the base: the PR base, or the previous tip on a push. A zero SHA, no
   base, or an event that is neither means run everything.
2. Fetches just that commit (depth 1, no blobs: the diff compares trees) with
   the `token`, unless the checkout already has it. It adds its own
   Authorization header only when the checkout did not persist one, so it
   works with `persist-credentials: false` and does not double up with `true`.
3. `git diff --name-only --no-renames <base> HEAD`. Over-inclusive rather than
   under-inclusive: on a PR the merge ref is compared with the base SHA from the
   event, so changes that landed on the base branch since count as changed.
4. A file matching `shared-globs` turns everything on; a file matching a suite's
   globs turns that suite on; a file matching only `docs-globs` is ignored; any
   other file follows `unmatched`.

Keep route in its own job: the blob-less fetch leaves the workspace as a
partial clone, which is fine for a job that does nothing else with git.

## Testing

`bash .github/actions/route/test.sh` builds throwaway repos and checks the
outputs, including every fail-open path. Nothing runs it in CI (this repo has no
CI); run it by hand after touching `route.sh`.
