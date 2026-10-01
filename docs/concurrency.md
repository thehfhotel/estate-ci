# Standard concurrency

ADR 0002, decision 5; plan item B4. PR runs cancel in progress. Main and
deploy runs never cancel.

Why: on a shared runner pool every superseded PR run is a full pipeline for
everyone else. A new push to a PR makes the previous run's result worthless, so
it should stop. A run on `main`, or a deploy, is the opposite: it may already
have pulled images or started a migration, and killing it midway leaves
production half-changed.

## The caller snippet

`concurrency` on a workflow belongs to the **calling** workflow. A reusable
workflow cannot cancel its caller's other jobs, so the estate's standard goes at
the top of each repository's pipeline file, next to `on:`:

```yaml
concurrency:
  group: ${{ github.workflow }}-${{ github.event.pull_request.number || github.ref }}
  cancel-in-progress: ${{ github.event_name == 'pull_request' }}
```

| Run | Group | Cancels the earlier run? |
|---|---|---|
| `pull_request` | `<workflow>-<PR number>` | yes |
| `push` to `main`, `workflow_dispatch`, `schedule` | `<workflow>-<ref>` | no |
| deploy (inside `deploy-evergreen.yml`) | `deploy-evergreen-<app_name>` | no, already set there |

A pipeline that only runs on pull requests can say it plainly:

```yaml
concurrency:
  group: ${{ github.workflow }}-${{ github.event.pull_request.number }}
  cancel-in-progress: true
```

Notes:

- `github.workflow` keeps two workflows in one repository from sharing a group.
  Group names are case insensitive and scoped to the repository.
- PR runs never deploy: `deploy-evergreen.yml` refuses a `pull_request` caller
  outright, and a caller gates its deploy job to `push`. Cancelling a PR run
  therefore can never interrupt a deploy.
- The deploy group is per app and is set **inside** `deploy-evergreen.yml`, on
  the deploy job, with `cancel-in-progress: false`. A caller does not repeat it.

## Pitfalls

**"Never cancel" is not "never drop".** A group holds one running run and one
pending run. When a third run arrives, the older *pending* run is cancelled and
replaced, whatever `cancel-in-progress` says. On `main`, three quick merges give:
the first runs, the second is dropped, the third runs after the first. That is
usually right for deploys (the last one wins and carries the earlier changes),
but the dropped run's checks never happen. If every commit on `main` must get
its own full pipeline, put the commit in the group so nothing queues behind
anything, and let the deploy job's own group serialize the deploys:

```yaml
concurrency:
  group: ${{ github.workflow }}-${{ github.event.pull_request.number || github.sha }}
  cancel-in-progress: ${{ github.event_name == 'pull_request' }}
```

Newer GitHub plans add a `queue: max` property that lets up to 100 runs wait in a
group instead of replacing the pending one; check that the property is accepted
on this plan before relying on it.

**Do not reuse a caller group name inside a called workflow.** A group taken by
the calling workflow and the same string requested by one of its called jobs
deadlocks (GitHub reports "a deadlock was detected for concurrency group" and
cancels the job). The estate's callee group
(`deploy-evergreen-<app>`) never starts with `<workflow>-`, so the standard
caller snippet cannot collide with it. Keep it that way for any new callee.

**`cancel-in-progress` on a shared deploy group would be dangerous**, which is why
the one in `deploy-evergreen.yml` is off and carries a comment saying so. Do
not "unify" it with the PR rule.
