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

The container expects these env vars (all required unless noted):

| Var | Meaning |
|---|---|
| `RUNNER_URL` | The GitHub org (or repo) URL to register against. |
| `RUNNER_NAME` | This runner's registered name. Must be unique per org/group. |
| `RUNNER_GROUP` | Runner group to join. |
| `RUNNER_LABELS` | Comma-separated custom labels (in addition to the automatic `self-hosted,linux,x64`). |
| `RUNNER_WORKDIR` | Absolute path used as `--work`. Bind-mount the *same* absolute path from the host so container actions and `uses: docker://` (which run as sibling containers via the mounted docker socket) can see the job's files. |
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

Docker access: mount `/var/run/docker.sock` and give the container whatever
supplementary group owns that socket on the host, so the runner user can use
Docker without being root. This image installs the Docker CLI, buildx and
compose plugins for exactly that — building and shipping images IS the job.

## What this buys, and what it doesn't

- Runners here are **persistent, not ephemeral** — they self-update and stay
  registered between jobs, rather than being torn down and re-registered per
  job. That trades per-job filesystem isolation (illusory anyway with a
  shared docker socket) for not needing a long-lived registration PAT sitting
  on disk and a rebuild cadence to keep up with runner releases.
- The docker socket mount means any job on this runner can, in effect, do
  anything Docker can do on the host. Only run this for repos you already
  trust with equivalent access — never for a public repo (see above).
