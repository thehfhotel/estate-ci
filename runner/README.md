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

### Preinstalled tools

Besides the Docker CLI, buildx and compose, the image carries two CLIs that
jobs would otherwise download on every run, each version-pinned and
sha256-verified at build time (`ARG`s at the top of the relevant `RUN` in the
`Dockerfile`; linux/amd64 only):

| Tool | Where | Used by |
|---|---|---|
| `cloudflared` | `/usr/local/bin/cloudflared` | `.github/actions/evergreen-ssh`, which uses the preinstalled binary when its version equals the action's pin and otherwise downloads the pinned build (60 s limit per attempt) |
| `trivy` | `/usr/local/bin/trivy` | scan steps that call the binary directly instead of restoring it through the Actions cache |

To bump either one, change the `ARG` pair in the `Dockerfile`, and for
`cloudflared` the matching pin in the action, then rebuild and recreate the
runners (an image rebuild never touches a running container).

### Preinstalled toolchains

So `oven-sh/setup-bun`, `actions/setup-node` and `actions/setup-python` stop
downloading per job, the image also carries the toolchain versions the estate's
workflows pin. The list is `toolchains.txt` (exact version, sha256 and URL per
line, linux/x64 only); `seed-toolchains.sh` installs it at build time and fails
the build on a checksum mismatch or a binary that reports the wrong version.
`SEED_DRY_RUN=1 bash seed-toolchains.sh toolchains.txt` downloads and checks
every checksum without installing anything.

Where each action looks, read from the action sources, and so where the image
keeps each tool:

| Action | Looks for | Image keeps it at |
|---|---|---|
| `setup-node` | the tool cache: `$RUNNER_TOOL_CACHE/node/<version>/x64` with a sibling `x64.complete` marker. Any cached version that satisfies the requested range is used (`22` finds `22.x.y`) unless `check-latest` is set. | seed dir, copied at start (below) |
| `setup-python` | the tool cache: `$RUNNER_TOOL_CACHE/Python/<version>/x64` plus `x64.complete`, matched the same way (`3.13` finds `3.13.x`). | seed dir, copied at start |
| `setup-bun` | **not** the tool cache. One binary at `~/.bun/bin/bun`, reused only when `bun --revision` equals the requested version exactly (a range like `1.3` never matches); otherwise it downloads and overwrites that file. | `$HF_TOOLCHAIN_DIR/bun/<version>/bun`; the estate default is copied to `~/.bun/bin/bun` |

**The bind-mount caveat.** `compose.yml` mounts a host directory over
`RUNNER_TOOL_CACHE`, so anything baked into the image at that path is hidden at
run time. The image therefore keeps node and python in a seed directory
(`/opt/toolcache-seed`, built at the path the mount normally has, because
Python's pip scripts carry absolute shebangs), and `entrypoint.sh` runs
`hf-seed-toolcache` at start: it copies each `<tool>/<version>/<arch>` the mount
does not already hold, never overwrites one, writes the `.complete` marker last,
and takes a lock in the cache so runners that start together do not fight over
the shared directory. A failure is logged and the runner starts anyway, with
`setup-*` downloading as before. Python is seeded only when `RUNNER_TOOL_CACHE`
is the path the image was built for.

Bun cannot work that way (one slot, exact match), so `bun-ci.yml` copies the
image's copy of the exact version it was asked for into `~/.bun/bin/bun` before
`setup-bun` runs; `setup-bun` then reports "Using existing Bun installation".
A job that calls `setup-bun` itself gets the estate default for free and can do
the same for another version:

```yaml
      - run: |
          src="${HF_TOOLCHAIN_DIR:-/opt/hf-toolchains}/bun/1.4.2/bun"
          # copy, never symlink: setup-bun's copy fallback writes through a symlink
          [ -x "$src" ] && mkdir -p ~/.bun/bin && rm -f ~/.bun/bin/bun && cp "$src" ~/.bun/bin/bun || true
      - uses: oven-sh/setup-bun@<sha>
        with:
          bun-version: 1.4.2
          no-cache: true
```

Not baked: Rust toolchains (`dtolnay/rust-toolchain` drives `rustup`, which keeps
toolchains in the runner user's home, already persistent per runner container)
and `pnpm`.

Host notes for a rollout (do it while the runners are idle):

- The image grows by roughly 1.7 GB, and the shared tool cache by roughly 1.5 GB
  the first time a runner starts (estimates from the archive sizes; check `du`
  after the first build). Delete lines from `toolchains.txt` to trim.
- Build with the usual `docker build`; recreate the runners afterwards (an image
  rebuild never touches a running container). Only the first runner to start
  copies; the others find the markers and skip.
- Nothing else changes: `compose.yml` and the hooks are untouched.
- A seeded cache does not make `setup-node` upgrade: it keeps using the
  cached patch version. Rebuild the image with newer lines to move it.

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

After the wipe and the credential sweep the same hook runs the size-gated
cache prune described under "Cache pruning" below.

The script is deliberately non-fatal (`exit 0` on every path, even a failed
`rm`) — a hook that fails would fail the job it runs after, which is worse
than an occasionally-stale workspace.

A containerized job step that runs as root (e.g. a `docker run ...`-mounted
tool, or a `container:` job) can leave root-owned files that the hook's own
unprivileged `rm -rf` can't remove, so when a docker socket is mounted in
(see "Docker access" above) the wipe instead runs as root inside a
throwaway `HOOK_WIPE_IMAGE` container (default `alpine:3.20`, override via
env var), falling back to the plain `rm -rf` if docker isn't available.

Persistence cuts both ways: the same `$HOME` also carries over between jobs,
so the hook additionally sweeps well-known credential locations there every
time — the whole of `~/.ssh`, `~/.docker/config.json`, `~/.config/gh`,
`~/.netrc`, `~/.git-credentials`, `~/.aws` and `~/.kube` (whichever exist) —
so a deploy SSH key, a `docker login` token, `gh auth login` state, or a
cloud CLI config a job wrote there never survives to be read by the next job
on this runner.

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

### A shared cache root across runners

Bind-mount one directory — the *identical* absolute path — into every
runner container on a box (e.g. `/srv/ci-cache:/srv/ci-cache`), export
that same path as an env var such as `HF_CI_CACHE` on each runner, and
workflows can derive per-tool cache locations from it (`CARGO_HOME`,
`CARGO_TARGET_DIR`, `npm_config_cache`, a buildx `BUILDX_CONFIG` state
dir, …) so language/package/layer caches persist across jobs and across
which runner in the pool happens to pick a job up, instead of being
downloaded or rebuilt cold every time. The identical-path requirement is
the same one `RUNNER_WORKDIR` calls out above: DooD (`container:` jobs,
or a job's own `docker run -v ...`) resolves any bind-mount source path
on the **host** daemon, so a runner-relative or per-runner path would
silently mount an empty directory in the sibling container rather than
sharing anything. Keep the cache root outside `RUNNER_WORKDIR` and outside
`$HOME` so the job-completed hook above — which wipes both — never
touches it. The hook's cache prune (next section) keeps it bounded.

If a cache root (or any one `<repo>` directory under it) lives on a
different disk than its siblings — for example one repo's cache bind-mounted
from a faster device over its path under the shared root — nothing else
changes: workflows still use the same paths, and the prune measures free
space per filesystem. Mounts made on the host AFTER a runner container was
created do not appear in that container, so recreate the runners
(`docker compose up -d --force-recreate`) after adding such a mount.

## Cache pruning

Persistent caches under `$HF_CI_CACHE` grow without bound: every commit, lockfile
bump or toolchain change opens a new set of cargo artifacts under new hashes,
and nothing ever deletes the old ones. The job-completed hook prunes them. It
is enabled when `HF_CI_CACHE` is set in the runner's environment, and costs one
`df` per cache root per job unless a prune is actually due.

**What it prunes.** Every `$HF_CI_CACHE/<repo>/target*` directory is treated as
a cargo target dir. Per profile directory (`debug`, `release`, ...):

- `deps`, `build` and `.fingerprint`: entries are named `<stem>-<16 hex>[.ext]`.
  Variants are grouped by stem and the newest K per stem are kept; every file or
  directory of an older variant is removed. "Newest" is by mtime, so the variant
  a build in flight needs is always among the kept ones.
- `incremental/<crate>-<hash>`: the newest K-1 per crate (at least 1) are kept.
- `cargo-timings` (older than 1 day), `tmp` and `sqlx-prepare-check` (older than
  7 days) entries under the target dir (`HF_CI_PRUNE_JUNK` to change the list).
- Nothing modified in the last `HF_CI_PRUNE_MIN_AGE_MIN` minutes (60) is touched.

**Levels, per filesystem.** The level is decided PER CACHE ROOT from the free
space of the filesystem that root lives on (`df`), not from one global figure:

| Level | When | Keep per stem | Also |
|---|---|---|---|
| 0 | at least 40 GB free | | once every 24 h a level-1 sweep runs anyway (stamp file `$HF_CI_CACHE/.prune-stamp`) |
| 1 | under 40 GB free | 3 | `docker volume prune -f` |
| 2 | under 20 GB free | 2 | all `incremental` dirs removed |
| 3 | under 10 GB free | 1 | every own-crate artifact set removed (executables at the top of the profile dir, `test_*`), and the `test-backend.lock` guard is ignored |

The thresholds are `HF_CI_PRUNE_L1_GB`/`L2_GB`/`L3_GB`, the keep counts
`HF_CI_PRUNE_K1`/`K2`/`K3`. A disk that also hosts production workloads should
keep the defaults or raise them: pruning starts early enough that the cache can
never be what fills it.

**Safety rules.**

- A root whose `<repo>/test-backend.lock` is held (a test job holds it for its
  whole compile and test) is skipped, except at level 3. The prune holds the
  lock itself while it deletes in that repo, so a test job cannot start
  mid-delete.
- `docker volume prune -f` removes only anonymous volumes on Docker 23 or
  newer; on an older daemon it would also remove unused NAMED volumes, so the
  hook refuses to run it there. Running volumes are never touched.
- Single instance, bounded: the prune runs as root in ONE detached sibling
  container named `hf-ci-prune` (so a second launch fails fast while one runs),
  at idle I/O priority, with a 30-minute hard timeout. Root is required because
  a job that builds inside a `container:` leaves a root-owned target dir that the
  runner user cannot delete. The container image is `HF_CI_PRUNE_IMAGE`, or by
  default the image the runner itself runs (it needs bash, GNU find/awk, flock
  and the Docker CLI). Without a usable image it falls back to an inline
  best-effort prune as the runner user.
- It appends one block per run to `$HF_CI_CACHE/prune.log` (free space before
  and after, what was removed, trimmed at 1 MB) and never fails the job.
- Kill switch: `HF_CI_PRUNE=0` in the runner environment.

**Dry run.** `PRUNE_DRY_RUN=1` prints, per root, what would be removed (counts,
sizes, the heaviest stems) and deletes nothing; it also ignores the gate, previews the level-1
sweep even when the daily stamp is fresh, and `HF_CI_PRUNE_LEVEL=1|2|3` forces a level so you can preview the
harsher ones. Run it once before arming the hook, on the real cache, in a
container so nothing else in the hook runs. The hook script can be `source`d
(its main flow is guarded), so sourcing it and calling `hf_prune_main` is the
whole test:

```sh
docker run --rm --user 0:0 --entrypoint bash \
  -e PRUNE_DRY_RUN=1 -e HF_CI_PRUNE_LEVEL=1 -e HF_CI_CACHE="$HF_CI_CACHE" \
  -v "$HF_CI_CACHE:$HF_CI_CACHE" -v /var/run/docker.sock:/var/run/docker.sock \
  <runner-image> -c 'source /path/to/job-completed.sh; hf_prune_main'
```

Do not run the whole hook on the host to test it: its credential sweep deletes
the `$HOME` locations listed above.

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
