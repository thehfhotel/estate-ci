# Post-deploy smoke check and rollback (`deploy-evergreen`, CI-3)

Owner priority: never ship broken. Until now the shim's own health wait was the only check after
`docker compose up`, and only four repos had a verify job of their own. This adds an opt-in check
to the shared deploy, plus an opt-in automatic rollback.

## Using it
```yaml
jobs:
  deploy:
    permissions:
      contents: read
      packages: write
      statuses: write     # only with rollback_on_failure: read for the lookup, write to record good deploys
    uses: thehfhotel/estate-ci/.github/workflows/deploy-evergreen.yml@<sha>
    with:
      app_name: myapp
      # ...
      smoke_url: https://myapp.thehfhotel.org/healthz
      smoke_expect: '"revision":"{tag}"'   # optional; {tag} = the deployed image tag
      smoke_timeout_seconds: 180           # optional
      rollback_on_failure: true            # optional
```
Leave `smoke_url` empty and nothing changes. The deploy step ships exactly what it shipped before.

## What happens
1. **Before deploying** (rollback on only), a read-only step finds the newest earlier commit on the
   default branch that has the commit status `deploy-evergreen/<app_name>` = success. Its description
   `tag=<image tag>` is the last good tag. The step uses curl, not gh. If the calling job did not grant
   `statuses: read`, it finds nothing and rollback is skipped. It never guesses a tag.
2. **Deploy** as before (`ship TAG`: .env + compose to the host's forced command).
3. **Smoke:** GET `smoke_url` every 5 s until a 2xx whose body contains `smoke_expect`, or the
   timeout. Only the first 120 bytes of a failing body are logged.
4. **Pass:** the `record-good` job marks this commit `deploy-evergreen/<app_name>` = success with
   `tag=<tag>`. It is a separate job because the deploy job hands its token to the host and must
   never hold a write scope. `record-good` never talks to the host.
5. **Fail:** with rollback on and a last good tag known, ship that tag through the same forced
   command and smoke it again. Either way the **run is red**: "rolled back (healthy), fix forward",
   or "the rollback failed too, production needs a person". The estate's CI-failure alert does the rest.

## Limits
- Rollback redeploys the *image*. Database migrations the bad release already ran are not undone;
  a release whose migration is not backward-compatible must not rely on this.
- The last good tag must still be in the registry (retention keeps 20 tags per repo, CI-7).
- The check runs from the deploy runner, so `smoke_url` must be reachable from there (public, or
  tailnet for hfville runners).
