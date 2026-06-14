# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Overview

An opinionated Helm chart for deploying Odoo ERP at IMIO. Intentionally scoped to IMIO's needs — not a general-purpose chart. Targets Odoo 16.0+ using the official Odoo Docker images rather than bitnami/odoo.

## Commands

```bash
# Lint the chart
helm lint .
helm lint -f test/local.yaml .

# Render templates (dry-run)
helm template odoo . -f test/local.yaml --namespace odoo

# Update dependencies (PostgreSQL from bitnami)
helm dep up

# Deploy to a local cluster
helm upgrade odoo . -f test/local.yaml --namespace odoo --create-namespace --install
```

The `helmlint.sh` script is used as a pre-commit hook and runs `helm lint` on changed files.

## Architecture

### Deployment Design

The main deployment (`templates/deployment.yaml`) runs **two containers** in a single pod:

1. **Nginx** — reverse proxy that handles HTTP (port 80→8069) and long-polling WebSocket (port 80→8072), gzip compression, and X-Forwarded headers for SSL termination
2. **Odoo** — the ERP application (port 8069 HTTP, port 8072 long-polling)

Strategy is always `Recreate` by default (no rolling updates, since Odoo requires a single writer).

### Services

Three separate services expose different ports:
- `odoo-nginx` (ClusterIP :80) — external entry point, routes to Nginx
- `odoo-odoo` (ClusterIP :8069) — internal Odoo HTTP
- `odoo-odoo-longpolling` (ClusterIP :8072) — WebSocket/chat

### Configuration and Secrets

Odoo is configured via `odoo.conf` injected as a Kubernetes Secret. Three mutually exclusive approaches:

1. **Default**: Secrets generated from `values.yaml` values (`existingSecret.enabled: false`, `externalsecrets.enabled: false`)
2. **Existing Secret**: Reference a pre-created Kubernetes Secret (`existingSecret.enabled: true`)
3. **External Secrets**: Vault integration via external-secrets.io operator (`externalsecrets.enabled: true`)

The `odoo.conf` secret is **split by lifecycle** (generated + externalsecrets backends):
- `<fullname>-odoo-conf` — a **normal** (Helm-tracked) Secret mounted by the Odoo + cron deployments. Tracked in `helm get manifest`, rollback-aware, stable across upgrades.
- `<fullname>-odoo-conf-hook` — a **hook** copy mounted only by the init/update Jobs (which run at `pre-install`, before normal resources exist). Rendered only when `init.enabled || update.enabled`.

Both copies share the same `odoo.conf` content via the `..odooConf` helper (single source of truth). With `existingSecret`, the user's single pre-existing `<fullname>-odoo-conf` serves both — no hook copy. See the pre-install dependency model below for why the split exists.

Nginx configuration is in a ConfigMap (`templates/configmap.yaml`).

### Database init & update (Helm hook Jobs)

DB lifecycle is handled by Helm hook Jobs in `templates/hooks/`. Both Jobs run on **`pre-install,pre-upgrade`**, so they execute *before* the Odoo/cron deployments are (re)applied. Each Job's `prepare` initContainer scales any running Odoo/cron to 0 (a no-op on a fresh install, since the deployments don't exist yet), and a `wait-for-db` initContainer (`odoo.hooks.waitForDb`) blocks on the DB host:port. **No install-time replica gating or scale-up hook is needed** — at `pre-install` the deployments don't exist; afterwards Helm creates them at their normal replicas, and on upgrade Helm re-applies them, bringing Odoo back up.

- **Init** (`odoo.init.enabled`) — `hooks/job-init.yaml`, hook-weight `0`. Runs `odoo -i <modules> -d <db> --stop-after-init`. `enabled` is a **one-shot intent**: set it true to initialise on install, or to **re-initialise after trashing the DB** (`helm upgrade` with `odoo.init.enabled=true`), then set it back to false (left on, every upgrade re-runs `odoo -i`).
- **Update** (`odoo.update.enabled`, default **false**) — `hooks/job-update.yaml`, hook-weight `10` (so init at `0` completes first when both are enabled). Runs `odoo -u <modules> --stop-after-init`. Set true only for a version bump (downtime + migration); `odoo -u` needs an already-initialised DB.

RBAC for the scale-down lives in `hooks/rbac.yaml` (rendered when `init.enabled` **or** `update.enabled`, weight `-10`). The `prepare` initContainer image is `odoo.hooks.kubectlImage` (default `alpine/kubectl:1.36.1`). Hook Jobs mount only an `odoo.conf` secret (no PVC). (Multi-tenant / Indexed-Job support is planned for a later release.)

**Pre-install dependency model** (the hooks run *before* the chart's normal resources, so everything they
need is itself provisioned as a pre-install hook; a pod that mounts a not-yet-created secret stays in
`ContainerCreating` and kubelet retries the mount until it appears, so "synced during pre-install" is enough):
- **odoo.conf secret** — the Jobs run at `pre-install`, so they need a secret that exists *before* the chart's
  normal resources. Rather than force one secret to be both a pre-install hook and the deployment's persistent
  resource (the old approach made it a hook **unconditionally**, accepting: recreated each upgrade, absent from
  `helm get manifest`, not rollback-restored — all to dodge the hook↔normal flip that trips Helm's ownership
  check, `invalid ownership metadata`), the secret is **split by lifecycle**. The Jobs mount the hook copy via
  `..hookVolumes`; the deployment/cron mount the normal copy directly. Neither copy ever changes type, so neither
  trips the ownership check, and the hook copy is gated on `init.enabled || update.enabled`.
  - *generated/classic* — `templates/secrets.yaml` renders **two** Secrets: the normal `<fullname>-odoo-conf`
    (always) and, when `init/update` is enabled, the hook `<fullname>-odoo-conf-hook` (`pre-install,pre-upgrade`,
    weight `-15`, `before-hook-creation`).
  - *existingSecret* — the user's single `<fullname>-odoo-conf` pre-exists; mounted directly by both the Jobs
    (`..hookVolumes` drops the `-hook` suffix here) and the deployment. No hook copy.
  - *externalsecrets* — `templates/externalsecrets.yaml` renders a **normal** `ExternalSecret` (target
    `<fullname>-odoo-conf`, always) plus, when `init/update` is enabled, a **hook** `ExternalSecret` (target
    `<fullname>-odoo-conf-hook`, `pre-install,pre-upgrade`). The operator syncs each target during its phase;
    the Job's mount retries until it lands. (Helm's hook wait only blocks on Pods/Jobs, not CR status, so this
    relies on the operator syncing within `--timeout`.)
- **Bundled PostgreSQL** — Helm cannot deploy a subchart before the parent's pre-install hooks, so the bundled
  bitnami Postgres (`postgresql.enabled: true`) is not up when the hooks run. To use it with the hooks (dev/test),
  run Postgres itself as a pre-install hook via `postgresql.commonAnnotations` (`helm.sh/hook: pre-install`,
  weight below `0`) — see `test/local.yaml`. Production should use an external DB. The Jobs' DB connection
  resolves through the `..dbHost`/`..dbPort`/… helpers.

`before-hook-creation` is required on the hook copy (`<fullname>-odoo-conf-hook`): Helm Creates hook resources,
so a re-run on the next upgrade would otherwise fail with `already exists`.

> **Migration note** — In released versions `<fullname>-odoo-conf` is already a *normal* secret, so upgrading to
> the split layout is seamless (normal→normal). Only an intermediate dev build where `<fullname>-odoo-conf` was a
> *hook* would flip it hook→normal and hit `invalid ownership metadata`; if you ran such a build, delete the stale
> secret (`kubectl delete secret <release>-odoo-conf`) before upgrading, or reinstall.

Shared Job spec lives in `_helpers.tpl` helpers: `..hookOdooContainer`, `..hookVolumes`, `..hookScaleDownInitContainer` (the `prepare` scale-down) and `..hookWaitForDbInitContainer` (reused by both Jobs).

### Maintenance Mode

When `maintenance.enabled: true`, the chart:
- Scales the main Odoo deployment to 0 replicas
- Scales the cron deployment to 0 replicas (so scheduled actions don't write to the DB during migrations/restores)
- Deploys a maintenance page (custom HTML or default)
- Redirects Ingress traffic to the maintenance service

The update/re-init hooks reuse this same maintenance nginx (config/HTML ConfigMaps) but bring up their own `pre-upgrade` hook copy of the maintenance Deployment (`hooks/maintenance-hook.yaml`, rendered when `update.enabled` **or** `init.enabled`, with `maintenancePage` + `ingress.enabled`). Crucially, that pod carries the chart's `selectorLabels` and a `nginx-http` port, so the existing `<fullname>-nginx` Service routes to it while Odoo is scaled to 0 — **the ingress is never modified** (an earlier `kubectl patch` approach was abandoned because Helm's 3-way merge does not revert out-of-band ingress edits when the rendered ingress manifest is unchanged). The hook is torn down once the upgrade hooks succeed, and the Service routes back to Odoo.

### Scheduled rollout restart

When `rolloutRestart.enabled: true`, `templates/cronjob-rollout-restart.yaml` renders a **CronJob** (`<fullname>-rollout-restart`) plus its own dedicated **ServiceAccount/Role/RoleBinding** (also `<fullname>-rollout-restart`). On its schedule the Job runs `kubectl rollout restart` + `kubectl rollout status` over a list of target deployments. These are **normal** (non-hook) resources — unlike the init/update hooks, the CronJob runs independently of install/upgrade.

The dedicated RBAC is deliberate: the chart's main ServiceAccount mounts no API token (`automountServiceAccountToken: false`), and the `<fullname>-hook` RBAC is hook-scoped and lacks the `watch` verb that `kubectl rollout status` needs. The Role grants `get`/`list`/`watch`/`patch` on `apps/deployments` in the release namespace; the pod sets `automountServiceAccountToken: true`. Image defaults to `odoo.hooks.kubectlImage`, securityContext reuses the chart's pod/container contexts (alpine/kubectl runs fine as uid 100). **Default targets** (empty `rolloutRestart.targets`): the main Odoo deployment `<fullname>`, plus `<fullname>-cron` when `cron.enabled`; an explicit `targets` list overrides this.

### Health Checks

Both liveness and readiness probes for Odoo hit `/web/health` on the Odoo HTTP port. Liveness has a 120s initial delay; readiness has 30s. The Nginx sidecar probes hit `/healthz` on port 80, which returns 200 directly without proxying to Odoo.

### PostgreSQL

Database config is split into two clearly-scoped sections, with `postgresql.enabled` selecting which one Odoo reads:

- `postgresql.*` — the **bundled** bitnami subchart (OCI registry), used when `postgresql.enabled: true` (dev/test). Odoo's connection comes from `postgresql.auth.*`, the host is auto-derived as `<release>-postgresql`, port `5432`. The `global.security.allowInsecureImages: true` setting is required due to the bitnami legacy repo. Bundled credentials are bitnami-native (inline `auth.password`/`auth.postgresPassword` or `auth.existingSecret`).
- `externalDatabase.*` — connection settings for an **external** PostgreSQL (e.g., CloudNativePG, recommended for production), used when `postgresql.enabled: false`. `externalDatabase.host` is required in this mode.

Connection resolution lives in the `..dbHost`/`..dbPort`/`..dbName`/`..dbUser`/`..dbPassword` helpers in `_helpers.tpl`, which switch source based on `postgresql.enabled`.

## Key Files

| File | Purpose |
|------|---------|
| `values.yaml` | All default configuration with inline comments |
| `templates/_helpers.tpl` | Shared template helpers (names, labels, selectors) |
| `templates/deployment.yaml` | Main Odoo + Nginx pod definition |
| `templates/secrets.yaml` | Generated `odoo.conf` secret — normal `<fullname>-odoo-conf` + gated hook `<fullname>-odoo-conf-hook` |
| `templates/configmap.yaml` | Nginx config and maintenance page HTML |
| `templates/externalsecrets.yaml` | Vault/external-secrets integration |
| `templates/hooks/` | Init / update hook Jobs (both `pre-install,pre-upgrade`; init weight `0` < update weight `10`), RBAC, maintenance-page hook |
| `templates/cronjob-rollout-restart.yaml` | Optional scheduled `kubectl rollout restart` CronJob + its dedicated `<fullname>-rollout-restart` RBAC (gated on `rolloutRestart.enabled`) |
| `test/local.yaml` | Development overrides (ingress enabled, `odoo.local` hostname) |

## CI/CD

- **Push / PR**: Runs `helm lint` + test via `IMIO/gha/helm-test-notify@v6`
- **Release**: Triggered on successful test on tag; publishes to `https://imio.github.io/helm-charts` via `IMIO/gha/helm-release-notify@v6`

Before creating and pushing a git tag, ensure `version` in `Chart.yaml` matches the tag. The release workflow is triggered by tag pushes and builds dependencies (bitnami) and packages the chart automatically.
