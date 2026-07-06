# Helm Chart for Odoo

[![License](https://img.shields.io/badge/License-Apache%202.0-blue.svg)](https://opensource.org/licenses/Apache-2.0) ![version](https://img.shields.io/github/tag/IMIO/helm-odoo.svg?label=release) ![test](https://github.com/IMIO/helm-odoo/actions/workflows/test.yaml/badge.svg) ![release](https://github.com/IMIO/helm-odoo/actions/workflows/release.yaml/badge.svg)

## Introduction

This [Helm](https://helm.sh/) chart installs `Odoo` in a [Kubernetes](https://kubernetes.io/) cluster. 

> [!IMPORTANT]
> This helm chart is designed for @IMIO specific needs and is not intended to resolve all use cases. But we are open to contributions and suggestions to improve this helm chart.
> This Helm chart targets Odoo 16.0+ using the official Odoo Docker image. The default image tag is `18.0`; override with `image.tag` as needed.

## Prerequisites

> [!NOTE]
> For production environments, it is recommended to use [CloudNativePG](https://github.com/cloudnative-pg/cloudnative-pg) for PostgreSQL. The bundled chart is primarily intended for testing and development purposes, do not use it in production. Be also aware of the upcoming changes to the bitnami catalog described in this [issue](https://github.com/bitnami/containers/issues/83267). 

- Kubernetes cluster 1.25+
- Helm 3.8.0+
- PV provisioner support in the underlying infrastructure.
- Postgres DB (This chart can install a postgresql database based on the bitnami/postgresql chart). We use it for testing purposes.

## Why do we not use the bitnami/odoo chart?

- we want to use the official Odoo Docker Image or our custom Odoo Docker Image.
- we need some specific configuration for our Odoo instance.

## Installation

### Pull Helm release

```bash
helm repo add imio https://imio.github.io/helm-charts
helm repo update
```

### Configure the chart

The following items can be set via `--set` flag during installation or configured by editing the `values.yaml` directly (need to download the chart first).

See the [values.yaml](values.yaml) file for more information.

### Install the chart

```bash
helm install [RELEASE_NAME] imio/odoo
```

or by cloning this repository:

```bash
git clone https://github.com/imio/helm-odoo.git
cd helm-odoo
helm dep up
helm upgrade odoo . -f values.yaml --namespace odoo --create-namespace --install
```

## Configuration

The following table lists the configurable parameters of the helm-odoo chart and the default values.

See the [values.yaml](values.yaml) file for more information.

### Database configuration

Database configuration is split into two clearly-scoped sections:

- **`postgresql.*`** — configures the **bundled** bitnami PostgreSQL subchart, used
  only when `postgresql.enabled: true` (intended for dev/test). Odoo's connection is
  taken from `postgresql.auth.*`, the host is auto-derived as `<release-name>-postgresql`
  and the port is `5432`. Bundled credentials can be set inline via
  `postgresql.auth.password` / `postgresql.auth.postgresPassword`, or supplied through
  `postgresql.auth.existingSecret` (bitnami-native).
- **`externalDatabase.*`** — connection settings for an **external** PostgreSQL
  (e.g. CloudNativePG), used only when `postgresql.enabled: false`. `externalDatabase.host`
  is required in this mode (templating fails fast if it is empty).

Only one section is ever read at a time, depending on `postgresql.enabled` — no key is
shared between the bundled and external scenarios.

### Use an existing Secret for Odoo configuration

You can use an existing secret for the Odoo configuration.

In the `values.yaml` file, set the `existingSecret.enabled` parameter to `true`.
Then, create a Secret in your namespace named `<release-name>-odoo-conf`
(or `<fullnameOverride>-odoo-conf` if `fullnameOverride` is set), containing
the `odoo.conf` key.

### Use external-secrets.io for Odoo configuration

In the `values.yaml` file, set the `externalsecrets.enabled` parameter to `true`.

You need to have the external-secrets.io operator installed in your cluster. See the [external-secrets.io documentation](https://external-secrets.io/latest/) for more information.

> [!WARNING]
> `existingSecret.enabled` and `externalsecrets.enabled` are mutually exclusive.
> Enabling both will cause `helm install`/`helm upgrade` to fail with an explicit error.
> Choose exactly one secret backend, or leave both disabled to have the chart generate secrets from `values.yaml`.

### Database initialization and updates

Database lifecycle is handled by **Helm hook Jobs** that run at `pre-install` and
`pre-upgrade` — before the Odoo/cron deployments are created or re-applied. Each Job
scales any running Odoo/cron to 0, waits for the database to be reachable, then runs
the migration; Helm brings the deployments back up afterwards.

#### Initialization (`odoo.init`)

```yaml
odoo:
  init:
    enabled: true
    modules: base,web
```

Runs `odoo -i <modules> -d <db> --stop-after-init`. Treat `enabled` as a **one-shot
intent**: set it `true` to initialise on install or to re-initialise after wiping the
DB, then set it back to `false` — left on, every upgrade re-runs `odoo -i` (which
scales Odoo to 0 for the duration, even though the command itself is a no-op on an
already-installed database).

#### Updates (`odoo.update`)

```yaml
odoo:
  update:
    enabled: true       # set true only for a version bump (causes downtime + migration)
    modules: all
    maintenancePage: true
```

Runs `odoo -u <modules> -d <db> --stop-after-init` (requires an already-initialised
DB). With `maintenancePage: true` (requires `ingress.enabled`), a temporary maintenance
pod is created that the `<release>-nginx` Service routes to while Odoo is scaled to 0,
without touching the ingress.

> [!IMPORTANT]
> Set `odoo.update.enabled` back to `false` after the upgrade — left on, a
> scale-to-0 migration runs on every `helm upgrade`.

> [!NOTE]
> **Maintenance mode does not disable these hooks.** `maintenance.enabled: true` only
> scales Odoo/cron to 0 and serves the maintenance page — the `init`/`update` Jobs still
> run on the next `helm install`/`helm upgrade`. This is intentional: you can migrate
> behind the maintenance page (set `maintenance.enabled: true`, then upgrade with
> `odoo.update.enabled: true`, then reopen). If you enter maintenance for something that
> must **not** touch the DB (e.g. a restore), make sure `odoo.init.enabled` and
> `odoo.update.enabled` are `false`. When both maintenance and a hook are enabled,
> `helm install`/`helm upgrade` prints a warning in its notes.

> [!NOTE]
> **Bundled PostgreSQL + hooks:** Helm cannot deploy a subchart before the parent's
> `pre-install` hooks, so `postgresql.enabled: true` is not up when the Jobs run. For
> dev/test, run PostgreSQL as a pre-install hook via `postgresql.commonAnnotations`
> (`helm.sh/hook: pre-install`, weight below `0`) — see `test/local.yaml`. Production
> should use an external database (`postgresql.enabled: false` + `externalDatabase.*`).

### Scheduled rollout restart (`rolloutRestart`)

Optionally schedule a periodic `kubectl rollout restart` to recycle the Odoo pods
(e.g. to clear leaked memory or pick up a freshly pulled image tag). When enabled, the
chart renders a `CronJob` plus a dedicated `ServiceAccount`/`Role`/`RoleBinding`
(`<release>-rollout-restart`) scoped to `get`/`list`/`watch`/`patch` on deployments in
the release namespace.

```yaml
rolloutRestart:
  enabled: true
  schedule: "0 3 * * 0"   # weekly, Sunday 03:00 (cluster timezone / UTC)
  # targets: []           # default: <release> + <release>-cron (when cron.enabled)
```

On each run it executes `kubectl rollout restart` followed by `kubectl rollout status`
for every target deployment. When `targets` is empty (the default) it restarts the main
Odoo deployment and, if `cron.enabled`, the cron deployment too; set `targets` to an
explicit list of deployment names to override. `concurrencyPolicy: Forbid` prevents
overlapping runs. The kubectl image defaults to `odoo.hooks.kubectlImage` and can be
overridden via `rolloutRestart.image`.

## Production readiness checklist

The chart ships safe-by-default security settings (non-root containers, dropped
capabilities, a dedicated ServiceAccount with the API token disabled), but a few
things still need explicit configuration for production:

- [ ] **Persistence** — set `persistence.enabled: true` with an appropriate
  `storageClass`/`size`. Without it the filestore lives on an `emptyDir` and Odoo
  attachments/sessions are lost on pod restart. For more than one replica the
  filestore must be `ReadWriteMany`.
- [ ] **External database** — set `postgresql.enabled: false` and configure
  `externalDatabase.*` (e.g. [CloudNativePG](https://github.com/cloudnative-pg/cloudnative-pg)).
  The bundled bitnami PostgreSQL pulls from the deprecated `bitnamilegacy` registry
  and is dev/test only.
- [ ] **Secrets** — use `existingSecret.enabled: true` or `externalsecrets.enabled: true`
  instead of inline `odoo.admin_passwd` / `externalDatabase.password` so credentials
  never live in plaintext values.
- [ ] **Resources** — set `resources` (Odoo), `nginx.resources` and `cron.resources`.
- [ ] **securityContext** — defaults assume the official Odoo image (`odoo` user,
  uid 100 / gid 101). If you use a custom image with a different user, override
  `securityContext` /
  `containerSecurityContext` / `nginx.containerSecurityContext` accordingly.

## Local Setup for development

Create a kind cluster:

```bash
cat <<EOF | kind create cluster --config=-
kind: Cluster
apiVersion: kind.x-k8s.io/v1alpha4
nodes:
- role: control-plane
  kubeadmConfigPatches:
  - |
    kind: InitConfiguration
    nodeRegistration:
      kubeletExtraArgs:
        node-labels: "ingress-ready=true"
  extraPortMappings:
  - containerPort: 80
    hostPort: 80
    protocol: TCP
  - containerPort: 443
    hostPort: 443
    protocol: TCP
EOF
```

Install the Nginx Ingress Controller:

```bash
kubectl apply -f https://raw.githubusercontent.com/kubernetes/ingress-nginx/main/deploy/static/provider/kind/deploy.yaml
```

Create the odoo namespace:

```bash
kubectl create namespace odoo
```

Get the IP address of the kind-control-plane:

```bash
 docker container inspect kind-control-plane --format '{{ .NetworkSettings.Networks.kind.IPAddress }}'
```
Modify the /etc/hosts file with the IP address of the kind-control-plane and add the hostnames:

```bash
nano /etc/hosts
172.18.0.2 odoo.local
```

Modify the test/local.yaml file and run the helm chart:

```bash
helm dep up
helm upgrade odoo . -f test/local.yaml --namespace odoo --create-namespace --install
```

Cleanup:

```bash
helm uninstall odoo -n odoo
kind delete cluster
```

## Contributing

Feel free to contribute by making a [pull request](https://github.com/imio/helm-odoo/pull/new/master).

Please read the official [Helm Contribution Guide](https://github.com/helm/charts/blob/master/CONTRIBUTING.md) from Helm for more information on how you can contribute to this Chart.

## Upgrading

### To 1.0.0

> [!IMPORTANT]
> **TL;DR**
> - **Before upgrading, delete the old Deployment(s)** — the selector is now immutable:
>   `kubectl delete deployment <release>-odoo <release>-odoo-cron -n <ns> --ignore-not-found`
> - **DB connection values moved:** `postgresql.host/port/auth` → `externalDatabase.*` (external DB),
>   while `postgresql.*` now configures only the bundled bitnami subchart.
> - **`odoo.update.enabled` now defaults to `false`** — init/update run as Helm hook Jobs, not in the main pod.
> - **Containers are non-root by default** (official Odoo image: uid 100 / gid 101) and get a dedicated
>   ServiceAccount with its token disabled. Custom images with a different user must override
>   `securityContext` / `containerSecurityContext`.

This is a breaking release. There are three independent migrations to apply to your values.

**1. PostgreSQL configuration split**

The single `postgresql:` section that previously held both the bundled-chart config and
the database connection settings has been split into two clearly-scoped sections
(`postgresql.*` for the bundled bitnami subchart, `externalDatabase.*` for an external
database). Update your values as follows:

- `postgresql.host` / `postgresql.port` → `externalDatabase.host` / `externalDatabase.port`
  (the host is now auto-derived as `<release-name>-postgresql` for the bundled chart).
- `postgresql.auth.admin_password` → `postgresql.auth.postgresPassword` (bitnami-native key).
- External-database connection now lives under `externalDatabase.*` (read only when
  `postgresql.enabled: false`).

**2. Init and update moved to Helm hook Jobs**

Database initialization and updates are no longer run inside the main deployment — the old
`init-db-odoo` init container and the `odoo --update …` command override have been removed
in favor of [Helm hook Jobs](#database-initialization-and-updates). Notable changes:

- **`odoo.update.enabled` now defaults to `false`** (was `true`). Previously the running
  Odoo container ran `odoo --update` on every start; now an enabled update is a
  `pre-install,pre-upgrade` hook Job that scales Odoo to 0 and migrates. Enable it only to
  upgrade Odoo modules, then set it back to `false`.
- `odoo.init.enabled` now drives a `pre-install,pre-upgrade` hook Job (a single Job, not
  per-replica / per-restart) that runs before Odoo starts; it can be re-run to
  re-initialise a wiped database via `helm upgrade`.
- New value groups: `odoo.update.maintenancePage` and `odoo.hooks.*`
  (`backoffLimit`, `ttlSecondsAfterFinished`, `waitForDb`, `kubectlImage`).

> [!NOTE]
> The update hook needs permission to scale the deployments to 0. The chart creates a
> namespaced ServiceAccount/Role/RoleBinding for this automatically, rendered only while
> `odoo.update.enabled: true`.

**3. Service/Deployment selector scoping + security hardening**

The main Odoo Deployment and the `<release>-odoo` / `<release>-odoo-longpolling`
Services are now scoped with `app.kubernetes.io/component: server` so they do not
select the **cron** pods (which share the base selector labels
and also expose port 8069). This release also adds non-root securityContext
defaults and a dedicated ServiceAccount with the API token disabled.

> [!WARNING]
> A Deployment's `spec.selector` is immutable, so `helm upgrade` from an earlier
> release fails with `field is immutable`. Delete the old Deployment(s) first:
>
> ```bash
> kubectl delete deployment <release>-odoo <release>-odoo-cron \
>   --namespace <namespace> --ignore-not-found
> helm upgrade <release> . -f <values> --namespace <namespace>
> ```
>
> If you run a custom Odoo image whose user is not uid 100 / gid 101, override
> `securityContext` / `containerSecurityContext` to match.

## License

[Apache License 2.0](/LICENSE)
