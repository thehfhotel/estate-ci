# estate-ci

Shared GitHub Actions plumbing for the HF Hotel estate: the reusable workflows
and composite actions that every app repo calls instead of keeping its own
near-copy of `deploy.yml`.

| Path | What it is |
|---|---|
| `.github/workflows/deploy-evergreen.yml` | Reusable — buildx build + push to GHCR, then forced-command SSH deploy over the cloudflared tunnel. |
| `.github/workflows/bun-ci.yml` | Reusable — `bun install --frozen-lockfile` → typecheck → test → build, each conditional on the script existing. |
| `.github/actions/evergreen-ssh/` | Composite — pinned, checksum-verified cloudflared plus the deploy key and `known_hosts`. |

Why it exists: the estate had accumulated fourteen near-copies of the same
deploy workflow. Each copy carried its own version of the cloudflared fetch,
the SSH setup, the jq payload and the concurrency group — which means each copy
also carried its own drift, and a fix landed in one of them and nowhere else.
Repo topology is decided by the change map (`hf-erp-portal`
`docs/adr/0006-repos-group-by-change-not-audience.md`); federated repos with
shared CI plumbing is rule 5 of that ADR, and this repo is the plumbing.

## This repo is PUBLIC, on purpose

**A public repository cannot call a reusable workflow that lives in a private
repository.** There is no setting, no token, and no `secrets: inherit` trick
that changes this — GitHub resolves a `uses:` across repositories against the
*caller's* visibility, and a private callee is simply not resolvable from a
public caller. The reverse direction works fine: a private repo can call a
public reusable workflow.

Six estate repos are public — `new-hotel`, `loyalty-app`, `income-ledger`,
`expense-ledger`, `HF-finance`, `reimbursement` — so a private `estate-ci`
would serve only the private half of the estate and the public half would keep
its fourteen copies. A public `estate-ci` serves all of them. Visibility here
is a consequence of that arithmetic, not a preference.

### What public costs, and the rule that pays for it

Everything in this repo is world-readable, forever, including anything a force
push "removes". So:

- **The hfville Tailscale IP is a secret and is never committed here.** hfville
  is reachable from CI only over the tailnet (`100.64.x.x`); that address, and
  the fact that a given service sits behind it, is internal network topology.
  It is passed to `deploy-evergreen.yml` as the optional `deploy_host` secret
  and defaults to the *public* hostname `evergreen.thehfhotel.org` when unset.
  There is deliberately no tailnet address in any file in this repo — if you
  find yourself typing `100.` into a YAML file here, stop; it belongs in the
  caller's repository secrets.
- Same rule for LAN addresses (`192.168.x.x`), internal-only hostnames, and
  anything else that maps the estate's private network. Reference the *location*
  of a value, never the value.
- No secret values, obviously. Note this includes ones that look inert: a
  Cloudflare Access team domain or an application AUD is not a credential, but
  together they describe the auth topology, so they arrive through
  `env_payload` like everything else.

The private `hf-erp-portal` repo owns Cloudflare-as-code and the estate's
network context. That is where topology lives.

## Callers SHA-pin

Pin every `uses:` to a full 40-character commit SHA with the human-readable
version in a trailing comment. A branch or tag ref means a push to this repo
silently changes what every caller runs — including the workflow that deploys
to production.

```yaml
# .github/workflows/deploy.yml — a caller repo
name: Build & Deploy

on:
  push:
    branches: [main]
  workflow_dispatch:

jobs:
  ci:
    uses: thehfhotel/estate-ci/.github/workflows/bun-ci.yml@0000000000000000000000000000000000000000 # v0.1.0

  deploy:
    # LOAD-BEARING. deploy-evergreen.yml does not run your tests — it cannot
    # know what they are. Without this `needs:`, a red suite does not stop a
    # push to main from reaching production. That has happened twice in this
    # estate; both scars are commented in housekeeping and income-ledger.
    needs: [ci]
    uses: thehfhotel/estate-ci/.github/workflows/deploy-evergreen.yml@0000000000000000000000000000000000000000 # v0.1.0
    # The called workflow's GITHUB_TOKEN scopes come from the CALLING job.
    # Without packages:write here, the build job cannot push to GHCR.
    permissions:
      contents: read
      packages: write
    with:
      app_name: housekeeping
      image: ghcr.io/thehfhotel/housekeeping
      host_port: "4070"
      compose_path: docker-compose.yml
    secrets:
      ssh_key: ${{ secrets.EVERGREEN_HOUSEKEEPING_DEPLOY_SSH_KEY }}
      host_key: ${{ secrets.EVERGREEN_HOST_KEY }}
      # Pre-materialized: a reusable workflow cannot enumerate your secrets,
      # so you render them here, one KEY=VALUE per line. Each ${{ secrets.* }}
      # component stays masked in the logs. Fixed internal container URLs are
      # not secrets and can be literals.
      env_payload: |
        CF_ACCESS_TEAM_DOMAIN=${{ secrets.CF_ACCESS_TEAM_DOMAIN }}
        CF_ACCESS_AUD_ROOT=${{ secrets.CF_ACCESS_AUD_ROOT }}
        CF_ACCESS_AUD_STAFF=${{ secrets.CF_ACCESS_AUD_STAFF }}
        KIOSK_EMAILS=${{ secrets.KIOSK_EMAILS }}
        NOTIFY_HUB_URL=http://hf-erp-portal:3000
        NOTIFY_INGRESS_TOKEN=${{ secrets.NOTIFY_INGRESS_TOKEN }}
        PUBLIC_URL=https://housekeeping.thehfhotel.org
```

A host that is not `evergreen.thehfhotel.org` adds one more secret, and only a
secret:

```yaml
    secrets:
      ssh_key: ${{ secrets.HFVILLE_DEPLOY_SSH_KEY }}
      host_key: ${{ secrets.HFVILLE_HOST_KEY }}
      deploy_host: ${{ secrets.HFVILLE_DEPLOY_HOST }}   # tailnet IP — never a literal
```

`secrets: inherit` also works and is deliberately **not** used in the estate:
listing the secrets explicitly is what makes a caller's blast radius reviewable
in the diff.

### `deploy-evergreen.yml`

| Input | Req | Default | Notes |
|---|---|---|---|
| `app_name` | yes | — | Concurrency group `deploy-evergreen-<app_name>`; matches `/srv/run-deploy-<app>.sh` on the host. |
| `image` | yes | — | Full image ref, e.g. `ghcr.io/thehfhotel/housekeeping`. Also names the `:buildcache` tag. |
| `host_port` | yes | — | Written to the container `.env` as `HOST_PORT`. A string, so quote it. |
| `context` | no | `.` | Docker build context. |
| `dockerfile` | no | `Dockerfile` | Path from the repo root. |
| `compose_path` | no | `docker-compose.yml` | Renamed to `docker-compose.yml` inside the tarball; the run-deploy shim looks for nothing else. |
| `platforms` | no | `linux/amd64` | |
| `force_deploy` | no | `false` | Skip the build, re-roll `:latest`. Secret rotation or a wedged container — an empty commit is *not* an alternative, it deploys nothing and reports green. |

| Secret | Req | Notes |
|---|---|---|
| `ssh_key` | yes | The app's own key, forced-command pinned in the host's `authorized_keys`. |
| `host_key` | yes | `known_hosts` entry. `StrictHostKeyChecking=yes` — this is the pin. |
| `env_payload` | no | `KEY=VALUE` lines appended to the container `.env` after `IMAGE_TAG` and `HOST_PORT`. Validated before it is written; no multi-line values (docker compose's `.env` parser does not support them — base64 anything with a newline). |
| `deploy_host` | no | Defaults to `evergreen.thehfhotel.org`. Anything tailnet-only goes here. |

Output: `image_tag` — the SHA tag deployed, empty on `force_deploy`.

Two details worth knowing before you edit it:

- **The `success-or-skipped` gate is load-bearing.** The deploy job runs on
  `always() && (needs.build.result == 'success' || needs.build.result ==
  'skipped')`. `always()` is needed because `force_deploy` *skips* the build
  and a skipped `needs` would otherwise skip the deploy too. The explicit
  disjunction is what keeps "skipped" from being read as blanket permission:
  rewriting it as `result != 'failure'`, or leaning on `always()` alone, lets a
  red build re-roll `:latest` onto production inside a green run.
- **`concurrency` groups are scoped to the calling repository.** Two different
  repos passing the same `app_name` do not serialize against each other. Where
  two pipelines share host state, the callers have to arrange that themselves
  (HF-finance puts both its deploys in one group for exactly this reason).

### `bun-ci.yml`

| Input | Default | Notes |
|---|---|---|
| `working-directory` | `.` | Where `package.json` lives. |
| `bun-version` | `1.3` | |
| `run_build` | `true` | Runs `bun run build` when the script exists. Off for repos that build only inside the Dockerfile. |
| `runs-on` | `ubuntu-latest` | |

Typecheck runs if a `typecheck` script exists. Tests run via the package's own
`test` script if it has one, else bare `bun test` if any `*.test.*`/`*.spec.*`
file exists, else a skip notice — because `bun test` with no test files exits
non-zero, and "no tests yet" must not masquerade as a red suite. A skipped step
still leaves the job green: this workflow trusts your `package.json` to declare
what you want checked.

## Change policy

A commit here can change what runs on every estate repo's path to production.
Treat `main` as a release surface, not a scratchpad.

- **`main` is protected**: no direct pushes, PR + review required, and the
  workflows in this repo are reviewed as production code — an unreviewed change
  to `deploy-evergreen.yml` is an unreviewed change to every estate deploy.
- **Callers advance their pins deliberately.** Merging here ships nothing.
  Every caller repo moves its own SHA in its own reviewed PR, on its own
  schedule, and watches its own first deploy after the bump. Dependabot may
  open the bump PR; merging it is still a decision, not a formality — the
  first repo to advance is the canary.
- **Roll back by reverting the pin**, in the caller. A caller sitting on an
  older SHA is a supported state, not drift, which is the whole point of
  pinning; the estate does not need to be on one version at once.
- **Breaking interface changes get a new input with a safe default**, or a new
  workflow file, rather than a redefinition of an existing one. Callers on old
  pins keep working, and the change lands per repo as each advances.
- **Pinned third-party actions and the cloudflared build** are bumped here and
  only here — one file for the estate. The composite action carries the
  cloudflared version *and* its sha256; change both together.
