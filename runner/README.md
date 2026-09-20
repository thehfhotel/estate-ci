# Self-hosted runner image

A generic, org-agnostic self-hosted GitHub Actions runner: `Dockerfile` +
`entrypoint.sh`. It knows nothing about any particular org, org URL, runner
group, label set, or host — every one of those arrives as an environment
variable from whatever starts the container. That's deliberate: this repo is
public, and none of that belongs in it (see the top-level README's rule on
topology).

**Only public repos carry this file. A repo that is itself public never
registers a runner built from it with a self-hosted label — that would put a
runner with docker-socket access at the mercy of anyone who can open a PR
against a public repo. Private repos never fall back to a GitHub-hosted
runner (`ubuntu-latest`, `macos-*`, `windows-*`) except a narrowly-scoped,
manually-triggered job that genuinely needs an OS this image can't provide.**

## Build

```sh
docker build -t <local-tag> runner/
```

The base image tag is pinned in the `FROM` line; bump it there when you want
a newer runner floor (self-update keeps the running binary current between
rebuilds regardless — see the comment in the Dockerfile).

## Run

`compose.yml` in this directory is a generic template for one instance —
copy it per runner and fill in the host paths and env values for your own
box (state dir, work dir, tool cache dir must all be host paths; `RUNNER_NAME`
and the service/container name must be unique per instance).

Every value below is a compose *substitution* (`${VAR:?...}`), resolved by
`docker compose` itself before the container ever starts — not a container
env var read by the entrypoint at runtime. That means `docker compose up`
fails immediately with a "variable is not set" error unless these are
available to compose, which in practice means a `.env` file sitting next to
`compose.yml` (compose loads it automatically) or the vars already exported
in your shell. Put `RUNNER_URL`, `RUNNER_NAME`, `RUNNER_GROUP`,
`RUNNER_LABELS`, `RUNNER_WORKDIR`, `RUNNER_STATE_DIR`, `RUNNER_TOOLCACHE_DIR`
and `TZ` in that `.env` (mode `0600` if any of them are sensitive on your
box — none are secrets by default, but treat host paths as you would any
other local config).

The container expects these env vars (all required unless noted):

| Var | Meaning |
|---|---|
| `RUNNER_URL` | The GitHub org (or repo) URL to register against. |
| `RUNNER_NAME` | This runner's registered name. Must be unique per org/group. |
| `RUNNER_GROUP` | Runner group to join. |
| `RUNNER_LABELS` | Comma-separated custom labels (in addition to the automatic `self-hosted,linux,x64`). |
| `RUNNER_WORKDIR` | Absolute path used as `--work`. Bind-mount the *same* absolute path from the host so container actions and `uses: docker://` (which run as sibling containers via the mounted docker socket) can see the job's files. The entrypoint creates this directory and `chown`s it to the runner user if it doesn't already own it — the host-side bind-mount target is otherwise typically root-owned (or created root-owned by Docker), which would fail every job at checkout. |
| `RUNNER_TOOL_CACHE` | Optional. If set, exported and used as the runner's tool cache directory — bind-mount it from the host so `actions/setup-*` downloads survive a container recreate. |

Persistent identity: bind-mount a per-runner directory at `/runner`. On
first start (no `/runner/config.sh`) the entrypoint seeds it from the image's
own runner install; after that, `/runner` — not the image — is what carries
this runner's registration and self-update state across container restarts
and image rebuilds.

Registration: before first start, write a short-lived registration token to
`/runner/registration-token` (mode `0600`). The entrypoint reads it once,
registers, and deletes the file. If the runner is already registered
(`/runner/.runner` present), the token is never read even if the file exists
— delete it yourself once registration has happened.

Docker access: mount `/var/run/docker.sock`. The entrypoint looks up (or
creates) the group that owns the mounted socket's GID and adds `runner` to it
before starting the runner process, so the container needs no baked-in GID
and the runner user can use Docker without being root. (A `group_add` on the
container itself is not enough on its own — the target user's supplementary
groups come from `/etc/group` at the point the process is `gosu`'d into, not
from anything injected only at the container/cgroup level — which is why the
entrypoint does this explicitly.) This image installs the Docker CLI, buildx
and compose plugins for exactly that — building and shipping images IS the
job.

## What this buys, and what it doesn't

- Runners here are **persistent, not ephemeral** — they self-update and stay
  registered between jobs, rather than being torn down and re-registered per
  job. That trades per-job filesystem isolation (illusory anyway with a
  shared docker socket) for not needing a long-lived registration PAT sitting
  on disk and a rebuild cadence to keep up with runner releases. The cost of
  that trade — a job's checkout can leak into the next job's on the same
  runner — is what the job-completed hook below exists to pay down.
- The docker socket mount means any job on this runner can, in effect, do
  anything Docker can do on the host. Only run this for repos you already
  trust with equivalent access — never for a public repo (see above).

## Workspace hygiene: the job-completed hook

Because runners are persistent (see above), the same `work-N` directory is
reused, unwiped, across every job that lands on it. A job that does a sparse
or otherwise narrowed checkout leaves that narrowed tree sitting there for
the *next* job of the same repo on the same runner — which then fails at a
step like "no package.json" or "no Dockerfile" for a reason that has nothing
to do with its own change, and everything to do with the previous job.

`hooks/job-completed.sh` fixes this by wiping `$GITHUB_WORKSPACE` after every
job, unconditionally, so the next job always starts from a clean checkout.
Wire it up with the runner's [`ACTIONS_RUNNER_HOOK_JOB_COMPLETED`](https://docs.github.com/en/actions/hosting-your-own-runners/managing-self-hosted-runners/running-scripts-before-or-after-a-job)
env var, pointed at the script's path *inside the container*:

```yaml
    environment:
      ACTIONS_RUNNER_HOOK_JOB_COMPLETED: /runner-hooks/job-completed.sh
    volumes:
      - ./hooks:/runner-hooks:ro
```

The script is deliberately non-fatal (`exit 0` on every path, even a failed
`rm`) — a hook that fails would fail the job it runs after, which is worse
than an occasionally-stale workspace.

Before wiping anything, the script checks that `$GITHUB_WORKSPACE` sits under
`RUNNER_WORK_PREFIX`. That variable is optional: left unset, it defaults to
the directory two levels above `$GITHUB_WORKSPACE` itself (a job's workspace
is normally `<work-dir>/<repo>/<repo>`, so two levels up recovers
`<work-dir>`), which is a no-op guard on an ordinary single-purpose runner.
Set `RUNNER_WORK_PREFIX` explicitly — to the host-path prefix shared by every
`RUNNER_WORKDIR` on your box — when several runners or repos share one host
and you want the hook to refuse to touch anything outside a known work root.

## Scaling past one runner

### The `heavy` label lane

`RUNNER_LABELS` is free-form, so a fleet of otherwise-identical runners can
carve out one lane for jobs that need more resources than you want every job
to have by default: give exactly one runner an extra `heavy` label (e.g.
`RUNNER_LABELS: <site>,docker,heavy`) and target it from the workflow side
with `runs-on: [self-hosted, <site>, heavy]`. Ordinary jobs keep matching on
`[self-hosted, <site>]` and land on whichever runner in that group is free,
never the heavy one specifically — `heavy` only *adds* a runner to the pool
that can take heavy jobs, it doesn't remove it from the pool for everything
else, unless you also give it a label combination that excludes it from the
plain lane.

### `cpu_shares` for production priority

When a runner container shares a host with production containers, a
CPU-hungry build can starve them under contention even with a `cpus` limit
set (`cpus` caps a container's ceiling; it doesn't set its priority relative
to others). Docker's `cpu_shares` (cgroup CPU weight, default `1024`) is the
knob for that: give runner containers a share below `1024` — e.g. `256` — so
the kernel scheduler favors production containers first whenever the host is
actually saturated, while a quiet host still lets the runner use as much CPU
as `cpus` allows.

### Docker daemon DNS for a private registry

If your registry lives at a name that only resolves through your own DNS
(for example, a mesh-VPN "MagicDNS"-style private hostname rather than
public DNS), a plain `docker pull`/`docker build --pull` from *inside* a
container on Docker's default bridge network can fail to resolve it — the
default bridge does not inherit the host's resolver. Point the docker daemon
itself at a resolver that knows that name via the `dns` key in
`/etc/docker/daemon.json` (or the container-runtime equivalent), then restart
the daemon; this affects every container on the default bridge network on
that host, including sibling containers a job builds via the mounted docker
socket.
