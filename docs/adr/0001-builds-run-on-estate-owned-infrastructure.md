# 0001: Builds run on estate-owned infrastructure

Status: Accepted, 2026-09-20.

## Context

The estate's GitHub organization is on the Free plan: 2,000 private-repo
Actions minutes/month and 500 MB of GitHub Packages storage, both included;
usage past that is billed per-minute / per-GB. The estate now runs on the
order of twenty private repositories, most with a CI workflow (bun-ci.yml or
equivalent) gating a deploy on every push to their default branch, plus a
handful of scheduled security/health jobs. Measured against that cadence,
staying on GitHub-hosted runners and GHCR storage at the estate's actual
build frequency would cost on the order of **$200/month** once the included
minutes and storage are exhausted — against an owner-set cap of ฿200/month
for anything GitHub-billed.

Two levers bring that to $0: run the builds themselves somewhere the estate
already pays for (compute that exists regardless, rather than metered
minutes), and stop storing built images in GitHub Packages. The estate
already operates always-on boxes for production services; using spare
capacity on one of them for CI removes the metered cost of both the runner
minutes and the image registry in one move, at the cost of taking on the
operational burden that GitHub previously carried for free.

## Decision

Private-repo CI and deploy jobs run on **self-hosted runners** registered
against the org, backed by a container image built and hosted here
(`runner/Dockerfile`, `runner/entrypoint.sh`) and operated on estate-owned
infrastructure. Built images are pushed to a **private container registry**
also run on estate-owned infrastructure, reachable only over the estate's
private network, rather than to GHCR.

Both reusable workflows in this repo (`bun-ci.yml`, `deploy-evergreen.yml`)
take the runner selection and the registry as inputs/secrets rather than
hardcoding either:

- `runner_labels` (both workflows): a JSON array of labels. Empty (the
  default) keeps a caller on GitHub-hosted `ubuntu-latest`, so every existing
  caller is unaffected until it opts in.
- `image_name` + the optional `image_registry` / `registry_user` /
  `registry_token` secrets (`deploy-evergreen.yml`): lets a caller name a
  bare app segment and have the registry resolved and authenticated for it —
  GHCR by default, the estate's own registry when `image_registry` is set —
  instead of hardcoding a registry host in the caller's own workflow file.

This repo is **public**, and self-hosted runner labels are never combined
with it: a self-hosted runner trusts every job scheduled on it with access to
a Docker socket, and a public repository accepts pull requests from anyone.
The estate's rule is symmetric and absolute — **a public repo never carries a
self-hosted label; a private repo never falls back to a GitHub-hosted
runner**, except a narrowly-scoped, manually-triggered job restricted by
`workflow_dispatch` and a path filter for the rare case that genuinely needs
an OS the self-hosted fleet can't provide. Concrete label sets, the
registry's hostname, and every other host-identifying detail live in the
estate's private ops repository, never in this public one.

## Consequences

**Single point of failure.** GitHub's hosted runner fleet is redundant and
managed by GitHub; the estate's self-hosted runners are not. If the host
running them is down, degraded, or its docker daemon wedges, every private
repo's CI and deploy pipeline stops — including the deploy pipeline for
whatever might be needed to fix the host itself. This is an accepted
trade-off for $0 spend, not an oversight: the estate already accepts
equivalent single-host risk for several production services.

**Docker-socket trust model.** Every job on a self-hosted runner effectively
has root-equivalent access to that host via the mounted Docker socket. This
is why the runner label is restricted to private repos only, why runners are
scoped to a dedicated runner group rather than the org default, and why the
per-runner resource limits (memory, CPU) exist — a single misbehaving or
resource-hungry job must not be able to starve or crash the shared runner
host out from under every other repo's pipeline.

**No GitHub-managed registry retention or scanning.** GHCR's built-in
vulnerability scanning and package retention policies don't apply to the
estate's own registry; garbage collection, disk hygiene and any image
scanning have to be built and run by the estate itself instead of consumed
as a platform feature.

**Escape hatch.** Nothing here is a one-way door. Any caller can drop back to
GitHub-hosted runners for a single workflow, or the whole estate, by clearing
its `runner_labels` input back to empty (the default already resolves to
`ubuntu-latest`) — no code change to this repo required, no data migration,
just a caller-side input change and, for the registry, pointing
`image_registry` back at GHCR or unsetting `image_name` to fall back to the
legacy `image` input entirely. The reverse move — going back to GitHub-hosted
minutes and GHCR storage — is deliberately kept this cheap precisely because
it's the fallback if the estate's own infrastructure ever stops being the
better trade.
