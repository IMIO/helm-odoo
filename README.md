# Helm Chart for Odoo

[![License](https://img.shields.io/badge/License-Apache%202.0-blue.svg)](https://opensource.org/licenses/Apache-2.0) ![version](https://img.shields.io/github/tag/IMIO/helm-odoo.svg?label=release) ![test](https://github.com/IMIO/helm-odoo/actions/workflows/test.yaml/badge.svg) ![release](https://github.com/IMIO/helm-odoo/actions/workflows/release.yaml/badge.svg)

## Introduction

This [Helm](https://helm.sh/) chart installs `Odoo` in a [Kubernetes](https://kubernetes.io/) cluster. 

> [!IMPORTANT]
> This helm chart is designed for @IMIO specific needs and is not intended to resolve all use cases. But we are open to contributions and suggestions to improve this helm chart.
> This Helm chart runs Odoo version 16.0 and has also been tested with later versions. It may not work with earlier versions.

## Prerequisites

> [!NOTE]
> For production environments, it is recommended to use [CloudNativePG](https://github.com/cloudnative-pg/cloudnative-pg) for PostgreSQL. The bundled chart is primarily intended for testing and development purposes. Be also aware of the upcoming changes to the bitnami catalog described in this [issue](https://github.com/bitnami/containers/issues/83267). 

- Kubernetes cluster 1.18+
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
helm repo add bitnami https://charts.bitnami.com/bitnami
helm repo update
helm dep up
helm upgrade odoo . -f values.yaml --namespace odoo --create-namespace --install
```

## Configuration

The following table lists the configurable parameters of the helm-odoo chart and the default values.

See the [values.yaml](values.yaml) file for more information.

### Use an existing Secret for Odoo configuration

You can use an existing secret for the Odoo configuration.

In the `values.yaml` file, set the `existingSecret.enabled` parameter to `true`.
Then, you need to have a Secret in your namespace with the following name: `your-release-name`-odoo-odoo-conf
Or if you set the `fullnameOverride` parameter, the Secret name will be `fullnameOverride`-odoo-conf.

### Use external-secret.io for Odoo configuration

In the `values.yaml` file, set the `externalsecrets.enabled` parameter to `true`.

You need to have the external-secret.io operator installed in your cluster. See the [external-secrets.io](documentation] for more information.

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

## Contributing

Feel free to contribute by making a [pull request](https://github.com/imio/helm-odoo/pull/new/master).

Please read the official [Helm Contribution Guide](https://github.com/helm/charts/blob/master/CONTRIBUTING.md) from Helm for more information on how you can contribute to this Chart.

## License

[Apache License 2.0](/LICENSE)
