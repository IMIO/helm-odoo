# Helm Chart for Odoo

[![License](https://img.shields.io/badge/License-Apache%202.0-blue.svg)](https://opensource.org/licenses/Apache-2.0) ![version](https://img.shields.io/github/tag/IMIO/helm-odoo.svg?label=release) ![test](https://github.com/IMIO/helm-odoo/actions/workflows/test.yaml/badge.svg) ![release](https://github.com/IMIO/helm-odoo/actions/workflows/release.yaml/badge.svg)

## Introduction

This [Helm](https://helm.sh/) chart installs `Odoo` in a [Kubernetes](https://kubernetes.io/) cluster. 

> [!IMPORTANT]
> This helm chart is designed for @IMIO specific needs and is not intended to resolve all use cases. But we are open to contributions and suggestions to improve this helm chart.
> This Helm chart targets Odoo 16.0+ using the official Odoo Docker image. The default image tag is `18.0`; override with `image.tag` as needed.

## Prerequisites

> [!NOTE]
> For production environments, it is recommended to use [CloudNativePG](https://github.com/cloudnative-pg/cloudnative-pg) for PostgreSQL. The bundled chart is primarily intended for testing and development purposes. Be also aware of the upcoming changes to the bitnami catalog described in this [issue](https://github.com/bitnami/containers/issues/83267). 

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

Database lifecycle is handled by **Helm hook Jobs** rather than inside the main
deployment. Both Jobs run on **`pre-install` and `pre-upgrade`**, so they execute
*before* the Odoo (and cron) deployments are created or re-applied — nothing writes to
the database while they run, and Odoo never starts against an uninitialised DB. Each Job
first scales any **running** Odoo/cron to 0 (a no-op on a fresh install, where they don't
exist yet) and waits for the database to be reachable; afterwards Helm brings the
deployments up at their normal replica counts.

#### Initialization (`odoo.init`)

When `odoo.init.enabled: true`, the init hook Job runs `odoo -i <modules> -d <db>
--stop-after-init` at hook-weight `0` (before the update Job).

```yaml
odoo:
  init:
    enabled: true
    modules: base,web   # modules to install on the fresh database
```

> [!NOTE]
> `odoo.init.enabled` is a **one-shot** intent. Set it `true` to initialise the database on
> install, **or to re-initialise after wiping the DB**: run
> `helm upgrade ... --set odoo.init.enabled=true` and the init Job scales Odoo/cron to 0,
> re-runs `odoo -i`, then Helm brings them back up. Set it back to `false` afterwards —
> left on, every `helm upgrade` re-runs `odoo -i` (a no-op on already-installed modules,
> but it scales Odoo to 0 for the duration).

An optional `wait-for-db` init container (`odoo.hooks.waitForDb`, default `true`) blocks
on the database `host:port` before running.

#### Updates (`odoo.update`)

When `odoo.update.enabled: true`, the update hook Job runs at hook-weight `10` (after
init). It:

1. scales the Odoo deployment (and the cron deployment, if enabled) to **0 replicas**,
2. optionally serves a maintenance page while the migration runs
   (`odoo.update.maintenancePage: true`, requires `ingress.enabled`),
3. runs `odoo -u <modules> -d <db> --stop-after-init`,

after which Helm re-applies the deployment, bringing Odoo back up with the new image.
`odoo -u` requires an already-initialised database (use `odoo.init` for a brand-new DB).

The maintenance page is served **without modifying the ingress**: a temporary maintenance
pod is created with the same labels the `<release>-nginx` Service selects on, so while Odoo
is scaled to 0 that Service routes to the maintenance pod, and routes back to Odoo once the
pod is torn down and Odoo returns.

```yaml
odoo:
  update:
    enabled: true       # set true only for a version bump (causes downtime + migration)
    modules: all
    maintenancePage: true
```

> [!IMPORTANT]
> `odoo.update.enabled` defaults to `false`. Enable it **only** for the upgrade that bumps
> the Odoo image/version, then set it back to `false` — leaving it on means a scale-to-0
> migration runs on **every** `helm upgrade`. The init/update hooks share a small RBAC
> (ServiceAccount/Role/RoleBinding) so they can scale the deployments to 0 and wait for
> their pods to terminate; it is rendered while `odoo.init.enabled` **or**
> `odoo.update.enabled` is true.

The kubectl image used by the init/update hooks is configurable via `odoo.hooks.kubectlImage`
(default `alpine/kubectl:1.36.1`).

> [!NOTE]
> **Bundled PostgreSQL + hooks:** the hooks run at `pre-install`, and Helm cannot deploy a
> dependency before the parent's pre-install hooks, so the bundled bitnami PostgreSQL
> (`postgresql.enabled: true`) is not up when they run. To use it together with the hooks
> (dev/test), run PostgreSQL itself as a pre-install hook via `postgresql.commonAnnotations`
> (`helm.sh/hook: pre-install` with a weight below `0`) — see `test/local.yaml`. For
> production, use an external database (`postgresql.enabled: false` + `externalDatabase.*`).

> [!NOTE]
> **odoo.conf secret + hooks:** because the hooks run at `pre-install`, the secret they mount
> is provisioned *before* them. The Jobs (and the deployment) always mount `<release>-odoo-conf`:
> in **generated** mode the chart renders it as a `pre-install,pre-upgrade` hook (so it's a Helm
> hook even without init/update — recreated each upgrade, not shown in `helm get manifest`/rollback;
> harmless because kubelet re-mounts); in **existingSecret** mode it pre-exists; in **externalsecrets**
> mode the `ExternalSecret` is also a pre-install hook, so the operator syncs the secret during
> pre-install and the Job's mount retries until it appears (the operator must sync within `--timeout`).

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

This is a breaking release. There are two independent migrations to apply to your values.

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
  `pre-install,pre-upgrade` hook Job that scales Odoo to 0 and migrates. Enable it only for
  the upgrade that bumps the Odoo version, then set it back to `false`.
- `odoo.init.enabled` now drives a `pre-install,pre-upgrade` hook Job (a single Job, not
  per-replica / per-restart) that runs before Odoo starts; it can be re-run to
  re-initialise a wiped database via `helm upgrade`.
- New value groups: `odoo.update.maintenancePage` and `odoo.hooks.*`
  (`backoffLimit`, `ttlSecondsAfterFinished`, `waitForDb`, `kubectlImage`).

> [!NOTE]
> The update hook needs permission to scale the deployments to 0. The chart creates a
> namespaced ServiceAccount/Role/RoleBinding for this automatically, rendered only while
> `odoo.update.enabled: true`.

## License

[Apache License 2.0](/LICENSE)
