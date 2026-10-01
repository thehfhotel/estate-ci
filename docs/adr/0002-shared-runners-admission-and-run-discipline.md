# 0002: Shared self-hosted runners: admission, lanes and run discipline

Status: Accepted, 2026-10-02. Decided by the owner question by question. The
implementation plan is in `docs/plan-shared-runner-cicd.md`.

## Context

ADR 0001 moved the estate's CI onto estate-owned infrastructure. A year of
growth later, a single runner host carries every private repository's CI:

- **One host, three runners.** The host has 4 cores and about 11 GB of RAM.
  Two runners carry the `heavy` label; the third does not. The host also runs
  production services, so CI load is production load.
- **Disks.** The SATA disk that holds most CI caches is I/O-bound at peak. The
  NVMe disk is the production root filesystem; there is no spare volume-group
  space to carve out a CI-only volume.
- **GitHub Free.** Private repositories have no merge queue, no branch
  protection, no rulesets and no required checks, and GitHub offers no job
  priority. Nothing technical stops a push to `main` or the merge of a red PR,
  and the only priority lever is which runner labels a job asks for.
- **Queue time exceeds run time.** A 12-day audit (2026-09-20 to 10-01)
  measured 10.8k job-minutes waiting against 6.9k running. Queue p90 was 449 s,
  worst at 21:00–04:00 ICT and on Monday Dependabot bursts. Short jobs gated by
  `needs:` were the worst case: 443 jobs of 40 s or less spent 611 minutes
  queued for 211 minutes of work.
- **Many writers.** Several agent sessions work the estate at once, each
  pushing its own PR, and Dependabot opens many more. A production fix on
  2026-10-01 sat behind PR feedback runs. A deploy chained through
  `workflow_run` with prerequisite polling skipped or failed while its CI
  was still queued, and the fix needed three deploy runs to land.

The goal set by the owner is a fast development cycle: the time from a push
to the change being live in production.

## Decisions

### 1. Priority order

Production deploys and production fixes come first. Then come main-branch
pipelines of merged work, then PR feedback. Dependabot and scheduled jobs
run only when the runners are otherwise idle.

### 2. Lanes, by label

A job whose usual run time exceeds about 3 minutes (Rust builds, image
builds, E2E stacks) declares `runs-on: [self-hosted, hfville, heavy]`. Short
jobs (deploy, verify, route, lint, release automation, small-repo CI) declare
`[self-hosted, hfville]`. The runner without `heavy` therefore only ever takes
short jobs: it is the express lane. The lanes are implemented by `runs-on` in
each workflow; runner configuration does not change.

### 3. Tested-tree skip

On green, PR CI records the tree hash of the merge ref it tested, as a marker
on the runner host's shared cache disk. After a merge, the main pipeline
compares `HEAD^{tree}` against the markers. A match means the exact tree was
already tested: build, deploy and smoke only. No match means full tests. The
logic lives once in estate-ci and every repository inherits it.

### 4. Dependabot

- Dependabot PRs get no CI of their own.
- Updates are grouped: monthly for cargo, GitHub Actions and Docker, weekly
  for npm and bun, scheduled 04:00–07:00 ICT and staggered across
  repositories. `rebase-strategy: disabled` everywhere.
- Security updates open immediately.
- The next bundle in a repository folds the pending Dependabot PRs in, one
  merge commit each, so each can be reverted alone.
- A security update that would wait more than about two days gets its own
  slot.
- A repository with no active work gets a monthly sweep bundle in quiet hours.

### 5. Run hygiene, for every repository

- A change that touches only docs skips the work inside each job.
- A `route` job on the express lane decides which suites the change needs.
- Release-automation PRs (release-please) run no CI.
- PR runs use `cancel-in-progress: true`. Main and deploy runs never cancel.
- Scheduled scans run 04:00–07:00 ICT, staggered.
- Each repository has **one main pipeline**, with deploy as its final
  `needs:` job, gated by the tested-tree check. No deploy chained by
  `workflow_run` and polling, and no separate push-to-main CI workflow whose
  checks the deploy pipeline already runs.
- A test timeout is sized for a loaded host, not an idle laptop. A test that
  passes only when the host is quiet is a flake.

### 6. Merge strategy

All changes go through PRs: PR CI first, then merge. No direct pushes to
`main`, even though GitHub Free cannot enforce that. Work is **bundled per
repository**: ready work from several sessions folds into one PR, each part
its own merge commit with a named owner and owned files. A repository takes
**one merge at a time**, and the next merge waits until the previous main
pipeline has finished.

### 7. Multi-session protocol

The rules for agent sessions live in the agents' global instructions, not in
this repository:
- one change, one run;
- bundle per repository;
- look at the queue before pushing;
- one merge per repository at a time;
- Dependabot only through bundles;
- production fixes first.

A small `ci-queue` helper shows runner state and per-repository queued and
running counts. There is no standing integrator role. A temporary
coordinator, when one runs, hands out push and merge slots.

### 8. Pre-CI compute in Claude cloud sessions

Claude cloud sessions (a VM of about 4 vCPU and 16 GB, with Docker, Postgres
and Redis) are used before CI:
- as a pre-CI gate for bundles and risky changes;
- to rehearse CI changes;
- as a build-speed lab;
- for flake hunting.

They never build production images and never hold production secrets.
Repositories holding financial data are excluded. Rules learned on first use:
- A one-off run is a routine set to run once. `claude --cloud` cannot start
  non-interactively.
- Routines attach every connected connector by default, so CI routines clear
  them.
- A routine polls its long jobs in the foreground rather than ending its turn.
- A pre-check mirrors the repository's exact bootstrap (package manager setup,
  toolchain file, runtime major) on the target runtime.
- Pushes to non-default branches trigger no runs, so `claude/*` branches are
  free.

First result: the pre-check of a Dependabot bundle ran the full backend and
frontend suites in the cloud and found the one job that would have failed CI
(new clippy lints from a toolchain bump). The fix landed before any runner
was used.

### 9. Storage budget on the shared NVMe

The NVMe root is shared with production, so CI gets a hard budget:
- the BuildKit builder is capped at about 30 GB by its GC policy;
- the largest repository cache is capped at 40 GB;
- **production keeps at least 40 GB free**. Below that, CI-owned data on the
  NVMe is pruned first, oldest first. The existing 20 GB level remains the
  emergency drop of all CI caches.

Other caches stay on SATA until a measured gain and room in the budget justify
moving them.

### 10. CI and production on one host

The runners mount the host Docker socket, so job and service containers start
as siblings of production containers, outside every limit placed on the runner
containers. All CI containers go into **one cgroup v2 slice**:
- **CPU:** a weight of 25 against production's 100. Production wins 4:1
  under contention, and CI still uses idle CPU at full speed.
- **Memory:** a combined limit of about 8 GB for all CI.
- **Disk:** an `io.max` bandwidth cap on the NVMe. The host's I/O schedulers
  do not support `io.weight`.

Runner and builder containers join the slice through their configuration. Job
and service containers join it through `--cgroup-parent`, which estate-ci's
reusable workflows set. A nightly check reports any CI container running
outside the slice. A second host is reconsidered only on the evidence in
decision 11.

### 11. Observability

A collector on the runner host (job-started and job-completed hooks) writes
one table:
- merge-to-live time per repository;
- queue wait p50/p90 per lane;
- red-run rate;
- runs per repository per day;
- free space per disk;
- CI memory pressure.

A weekly summary line goes to the owner. Alerts fire only on confirmed
problems, and each alert has a matching recovery notice:
- a runner offline for more than 15 minutes;
- a main or deploy run queued for more than 30 minutes;
- a failed production deploy;
- NVMe free space below the 40 GB floor after the prune has run.

Alerts use the existing monitoring channel. If queue p90 stays above 5 minutes
for two weeks after these decisions are in place, a second host is on the
table.

### 12. Enforcement

GitHub Free cannot enforce any of this, so policy is carried in code wherever
it can be:
- estate-ci's reusable workflows and composite actions implement the route
  job, the tested-tree check, lanes, concurrency and the cgroup parent;
- application repositories call them, pinned by commit SHA, and the pins move
  through the monthly Actions update in a bundle;
- the collector's weekly summary flags any repository whose workflows bypass
  the shared pieces.

Agent rules (decision 7) cover what code cannot.

## Consequences

- **Faster path to live.** Merged work and fixes stop queueing behind PR
  feedback and Dependabot. A merged tree that was already tested skips its
  second full test run.
- **More careful bundles.** Bundles mean fewer runs, but failures are harder
  to attribute. One merge commit per part, with named owners, keeps any part
  revertible and attributable.
- **More in estate-ci.** estate-ci grows from deploy plumbing into the
  estate's CI policy. Changes to it affect every repository and go through
  the same PR discipline.
- **Discipline, not enforcement.** Until a plan change buys branch protection,
  a careless push can still reach `main`. The collector makes that visible
  after the fact. It cannot prevent it.
