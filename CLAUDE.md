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

Nginx configuration is in a ConfigMap (`templates/configmap.yaml`).

### Database init & update (Helm hook Jobs)

DB lifecycle is handled by Helm hook Jobs in `templates/hooks/`, **not** inside the main deployment (the old `init-db-odoo` initContainer and `odoo --update` command override were removed):

- **Init** (`odoo.init.enabled`) — a `post-install` hook Job (`hooks/job-init.yaml`) that runs `odoo -i <modules> -d <db> --stop-after-init` **once, on first install only**. A single Job regardless of replica count. An optional `wait-for-db` initContainer (`odoo.hooks.waitForDb`) blocks on the DB host:port first.
- **Update** (`odoo.update.enabled`, default **false**) — a `pre-upgrade` hook Job (`hooks/job-update.yaml`) that runs on `helm upgrade`. Its `prepare` initContainer (image `odoo.hooks.kubectlImage`, default `alpine/kubectl:1.36.1`) scales Odoo (and cron) to 0 and waits for their pods to terminate, then the Job runs `odoo -u <modules> --stop-after-init`. Helm then re-applies the deployment, bringing Odoo back up with the new image. Set `update.enabled: true` only for a version bump (it causes downtime + migration). RBAC for the scale/wait lives in `hooks/rbac.yaml` (rendered only when update is enabled).
Hook Jobs mount only the `odoo.conf` secret (no PVC). (Multi-tenant / Indexed-Job support is planned for a later release.)

Shared Job spec lives in `_helpers.tpl` helpers: `..hookOdooContainer` and `..hookVolumes`.

### Maintenance Mode

When `maintenance.enabled: true`, the chart:
- Scales the main Odoo deployment to 0 replicas
- Scales the cron deployment to 0 replicas (so scheduled actions don't write to the DB during migrations/restores)
- Deploys a maintenance page (custom HTML or default)
- Redirects Ingress traffic to the maintenance service

The update hook reuses this same maintenance nginx (config/HTML ConfigMaps) but brings up its own `pre-upgrade` hook copy of the maintenance Deployment (`hooks/maintenance-hook.yaml`). Crucially, that pod carries the chart's `selectorLabels` and a `nginx-http` port, so the existing `<fullname>-nginx` Service routes to it while Odoo is scaled to 0 — **the ingress is never modified** (an earlier `kubectl patch` approach was abandoned because Helm's 3-way merge does not revert out-of-band ingress edits when the rendered ingress manifest is unchanged). The hook is torn down once the update Job succeeds, and the Service routes back to Odoo.

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
| `templates/secrets.yaml` | PostgreSQL credentials and `odoo.conf` secret |
| `templates/configmap.yaml` | Nginx config and maintenance page HTML |
| `templates/externalsecrets.yaml` | Vault/external-secrets integration |
| `templates/hooks/` | Init (`post-install`) / update (`pre-upgrade`) hook Jobs, RBAC, maintenance-page hook |
| `test/local.yaml` | Development overrides (ingress enabled, `odoo.local` hostname) |

## CI/CD

- **Push / PR**: Runs `helm lint` + test via `IMIO/gha/helm-test-notify@v6`
- **Release**: Triggered on successful test on tag; publishes to `https://imio.github.io/helm-charts` via `IMIO/gha/helm-release-notify@v6`

Before creating and pushing a git tag, ensure `version` in `Chart.yaml` matches the tag. The release workflow is triggered by tag pushes and builds dependencies (bitnami) and packages the chart automatically.
