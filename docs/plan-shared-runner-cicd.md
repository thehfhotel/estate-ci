# Plan: implementing ADR 0002 (shared-runner CI/CD)

This is the working plan for `docs/adr/0002-shared-runners-admission-and-run-discipline.md`.
Unlike the ADR, it changes as work lands; tick items here in the PR that
delivers them.

Ground rules for the work itself:
- The ADR applies to its own rollout: one bundled PR per repository, Sonnet
  workers, cheap local checks only, and CI as the gate.
- Change the host only while runners are idle, and report df and
  service status before and after.
- Each wave says how its effect is measured. Collect a "before" number before
  the wave lands.

## Wave A: host only, no CI runs

| # | Item | ADR | Done when |
|---|---|---|---|
| A1 | BuildKit builder GC capped at about 30 GB; root floor of 40 GB free in the prune hook (CI data pruned first, oldest first); largest repo cache capped at 40 GB; the 20 GB emergency level kept | 9 | `df /` and the builder `du` before and after are recorded in the PR or ops note; the hook's dry run shows the new order |
| A2 | Reclaim the old SATA copy of the moved cache once the NVMe trial is judged good (p50/p90 of the heavy jobs against the baseline) | 9 | Trial verdict written; old copy removed |
| A3 | A `hf-ci` cgroup v2 slice (CPUWeight 25, MemoryMax about 8 GB, `io.max` on the NVMe); runner containers and the builder join it through `cgroup-parent` | 10 | `systemd-cgls` shows them under the slice; a heavy build under load leaves production latency flat |
| A4 | A job-started hook beside job-completed; both append one row per job (repo, workflow, job, lane, queued_at, started_at, finished_at, conclusion, head_sha) | 11 | Rows appear for every job over a full day |
| A5 | A nightly stray check: any container started by a runner job that is outside `hf-ci` is reported | 10, 12 | Fires on a deliberate stray, silent otherwise |

Status of Wave A (2026-10-02):
- **A1** done: builder GC cap, 40 GB root floor and the largest-repository cap (`HF_CI_CACHE_CAPS`) in the prune hook.
- **A4** done: `runner/hooks/job-started.sh` and `job-completed.sh` append one JSON row per
  hook call (`runner/README.md`, "Job rows"). `queued_at` and `conclusion` stay null; Wave D1
  fills them from the API by run id.
- **A5** done report-only: `runner/ops/stray-check.sh`, run nightly from the host's cron. It
  reports every CI container until A3 puts them in the slice; alerting is Wave D3.
- **A3** staged for the owner. Finding: systemd reads the dash in `hf-ci.slice` as a hierarchy
  separator, so the slice is `/hf.slice/hf-ci.slice` and the CPU weight has to sit on the
  parent `hf.slice` to rank against production. Names in B3 and the stray check are unchanged.
- Prune fixes shipped with A4: third-party cargo artifacts are deleted by atime (3 days), only
  the repository's own crates by keep-newest-K; tested-tree markers older than 30 days are
  pruned (B2's retention); the "freed" counter now sums across the prune's subshells.

## Wave B: estate-ci building blocks (this repo, one PR per piece)

| # | Item | ADR |
|---|---|---|
| B1 | `route` composite action: path-based suite selection; docs-only short-circuit; runs on the express lane | 5 |
| B2 | Tested-tree marker: `record` (green PR run writes the merge-ref tree hash) and `check` (main reads `HEAD^{tree}` → `full` or `skip-tests` output); markers on the shared cache disk, pruned after 30 days | 3 |
| B3 | Standard job containers: reusable workflow inputs that add `--cgroup-parent=hf-ci.slice` to `container.options` and service containers | 10 |
| B4 | Standard concurrency: PR groups cancel in progress; main and deploy groups never cancel | 5 |
| B5 | `deploy-evergreen.yml` takes the tested-tree output and becomes the final `needs:` job pattern; documented replacement for `workflow_run` + polling deploy chains | 5 |
| B6 | Runner image preinstalls every toolchain version the estate pins (for example the Bun version a repository holds back), so `setup-*` steps stop downloading per job | 5 |
| B7 | Lane guidance in the README: which jobs say `heavy`, which do not; test-timeout guidance for a loaded host | 2, 5 |

## Wave C: adoption, one bundled PR per repository

Order is by queue impact, heaviest first. Each PR:
- switches `runs-on` to the lanes;
- adds the route job, the tested-tree record/check and B3/B4;
- makes deploy the final `needs:` job (replacing any `workflow_run` deploy);
- removes a duplicate push-to-main CI when the deploy pipeline is a superset;
- stops CI on release-please PRs;
- sets `dependabot.yml` per ADR decision 4: grouped, rebase disabled,
  04:00–07:00 ICT, staggered;
- folds in that repository's pending Dependabot PRs.

1. The Rust PMS (largest cache, longest heavy jobs).
2. The loyalty app (Rust + E2E; replace its `workflow_run` deploy).
3. The attendance app (Python suite).
4. The CRM, the data/MCP repository, finance, ledgers.
5. The remaining Bun/Next repositories through `bun-ci.yml`.

The run order follows the ADR's own rules: production fixes in flight go first,
and a repository's adoption PR waits for its current work so the two fold
together.

## Wave D: observability and alerts

| # | Item | ADR |
|---|---|---|
| D1 | The job table from A4 is loaded into the estate data store; derived views give merge-to-live per repo, queue p50/p90 per lane, red-run rate, runs per repo per day | 11 |
| D2 | A weekly summary line in the owner's Monday pack | 11 |
| D3 | Alerts on the existing monitoring channel, each with a recovery notice: runner offline > 15 min; main/deploy run queued > 30 min; failed production deploy; NVMe below the 40 GB floor after prune | 11 |
| D4 | The weekly summary flags repositories whose workflows bypass the shared pieces | 12 |

## Exit criteria

- Merge-to-live p50 and p90 per repository are measured before Wave C and
  after it, and the improvement is reported.
- Queue p90 for the express lane is under 1 minute, and under 5 minutes
  overall. If the overall p90 stays above 5 minutes for two weeks after
  Wave C, the second-host question opens (ADR decision 11).
- No production latency regressions attributable to CI in the first two weeks
  after A3.
