# Putting CI containers in the CI cgroup slice

ADR 0002, decision 10; plan item B3.

The runners mount the host Docker socket, so every container a job starts is a
**sibling** of production containers, outside any limit placed on the runner
containers. The estate puts all CI containers in one cgroup v2 slice
(`hf-ci.slice`: low CPU weight against production, a shared memory ceiling, an
I/O cap), and a container joins it only if it is *asked* to, with
`--cgroup-parent`. This page is how to ask, for every way a job can start a
container.

The slice is created and tuned on the host. Its name is the estate value and is
not a secret: `hf-ci.slice`. Docker's systemd cgroup driver wants a **slice
name** (ending in `.slice`), not a path.

## Where this repo's reusable workflows stand

Neither `bun-ci.yml` nor `deploy-evergreen.yml` starts a job `container:` or
`services:`, so neither has a `cgroup-parent` input. The convention for any
reusable workflow here that gains one: an input `cgroup-parent` (string, default
empty), appended as `--cgroup-parent=<value>` to `container.options` and to
every service's `options` when non-empty, and unchanged when empty.

The only container `deploy-evergreen.yml` starts is the BuildKit builder that
`docker/setup-buildx-action` creates. The `docker-container` driver's
`cgroup-parent` option is applied **only when the Docker daemon uses the
`cgroupfs` cgroup driver** (docker/buildx, `driver/docker-container`), so on a
systemd-driver host it is ignored. Getting the builder into the slice is a host
configuration, not a workflow input (ADR decision 10: "runner and builder
containers join the slice through their configuration").

## Callers: how to ask

Pass the option in whatever starts the container. To avoid hardcoding the name
in every repository, keep it in one organization Actions variable,
`HF_CI_CGROUP_PARENT` (value `hf-ci.slice`); an unset variable renders to
nothing, so the same workflow also runs where there is no slice.

A job container and service containers:

```yaml
jobs:
  e2e:
    runs-on: [self-hosted, <site>, heavy]
    container:
      image: ghcr.io/<owner>/ci-image:1
      options: >-
        ${{ vars.HF_CI_CGROUP_PARENT && format('--cgroup-parent={0}', vars.HF_CI_CGROUP_PARENT) || '' }}
        --user 1001:1001
    services:
      db:
        image: postgres:17
        options: >-
          ${{ vars.HF_CI_CGROUP_PARENT && format('--cgroup-parent={0}', vars.HF_CI_CGROUP_PARENT) || '' }}
          --health-cmd pg_isready
```

Hardcoding is equally fine: `options: --cgroup-parent=hf-ci.slice`.

| How the container starts | How it joins the slice |
|---|---|
| job `container:` | `options: --cgroup-parent=hf-ci.slice` |
| `services:` | the service's own `options: --cgroup-parent=hf-ci.slice` |
| `docker run` / `docker create` in a `run:` step | `--cgroup-parent=hf-ci.slice` |
| `docker compose` in a `run:` step | `cgroup_parent: hf-ci.slice` on each service |
| `docker build` / `buildx` | the builder; host configuration (see above) |
| `uses: docker://...` and Docker container actions | no knob: the runner builds the command. Prefer a `run:` step with `docker run`, or accept that these stay outside the slice. |

`options` is passed to `docker create`, so `--cgroup-parent` is a valid entry;
only `--network` and `--entrypoint` are refused by GitHub.

## What a stray looks like

A CI container that is not in the slice still works, it is just unlimited and
competes with production at full weight. The host's nightly stray check
(plan item A5) reports any CI container outside `hf-ci.slice`; a repository
that shows up there is missing one of the options above.
