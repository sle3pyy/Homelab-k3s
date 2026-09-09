# Homelab k3s GitOps

This repository contains the ArgoCD GitOps configuration for the homelab k3s
cluster.

The base infrastructure for this homelab is managed in
[sle3pyy/k3s-proxmox-terraform](https://github.com/sle3pyy/k3s-proxmox-terraform).
That repository provisions the k3s cluster on Proxmox with Terraform and
Ansible. This repository starts after the cluster exists and manages the
applications deployed into it with ArgoCD.

The repository uses an app-of-apps layout:

```text
Homelab-k3s/
├── bootstrap/
│   ├── homelab-project.yaml
│   └── homelab-apps.yaml
├── apps/
│   ├── homelab-project/
│   ├── gitea/
│   ├── gitea-actions/
│   ├── jellyfin/
│   └── *arr/
└── .github/
    └── validate.yaml
```

## Bootstrap

`bootstrap/homelab-project.yaml` defines the ArgoCD `AppProject` named
`homelab`. It controls which Git and Helm repositories can be used and which
cluster namespaces the project may deploy into.

`bootstrap/homelab-apps.yaml` defines the `homelab-apps` ArgoCD Application.
It points ArgoCD at the `apps/` directory and recursively discovers application
manifests. It excludes `values.yaml` files so Helm values are not applied as raw
Kubernetes manifests.

Apply the bootstrap resources with:

```bash
kubectl apply -f bootstrap/homelab-project.yaml
kubectl apply -f bootstrap/homelab-apps.yaml
```

## Applications

### Gitea

`apps/gitea/` deploys Gitea from the official Gitea Helm chart:

- chart: `gitea`
- chart repo: `https://dl.gitea.com/charts/`
- version: `12.7.0`
- namespace: `gitea`
- HTTP NodePort: `30090`
- SSH NodePort: `30222`
- root URL: `http://git.bingus.pt/`

The Helm values enable Gitea Actions at the instance level:

```yaml
gitea:
  config:
    actions:
      ENABLED: true
```

Repository Actions still need to be enabled per repository in the Gitea UI if
the Actions tab does not appear.

### Gitea Actions Runner

`apps/gitea-actions/` deploys the Gitea Actions runner chart:

- chart: `actions`
- chart repo: `https://dl.gitea.com/charts/`
- version: `0.1.2`
- namespace: `gitea`
- replicas: `1`
- runner labels:
  - `ubuntu-latest`
  - `ubuntu-24.04`
  - `ubuntu-22.04`

The ArgoCD Application also references `manifests/gitea-actions`, but that
directory is not currently implemented in this repository. For now, the runner
token is managed as a manual Kubernetes secret in the cluster.

The runner requires an existing Kubernetes secret:

```yaml
existingSecret: gitea-actions-runner-token
existingSecretKey: runner-token
```

If this secret is missing, the runner pod can stay in
`CreateContainerConfigError`.

Generate the runner registration token from inside the k3s control-plane shell:

```bash
kubectl -n gitea exec deploy/gitea -- \
  gitea --config /data/gitea/conf/app.ini actions generate-runner-token
```

Create or update the Kubernetes secret with the generated token:

```bash
kubectl -n gitea create secret generic gitea-actions-runner-token \
  --from-literal=runner-token='<token>' \
  --dry-run=client -o yaml | kubectl apply -f -
```

Restart the runner pod after the secret exists:

```bash
kubectl -n gitea delete pod gitea-actions-runner-0
kubectl -n gitea get pods -w
```

The expected runner state is:

```text
gitea-actions-runner-0   2/2   Running
```

### Jellyfin

`apps/jellyfin/` contains a placeholder Jellyfin deployment using the Jellyfin
Helm chart:

- chart: `jellyfin`
- chart repo: `https://jellyfin.github.io/jellyfin-helm`
- version: `3.2.0`
- namespace: `jellyfin`
- HTTP NodePort: `30096`

Jellyfin is currently unimplemented in practice because there is no NAS
available yet. The current values expect NFS media storage:

```yaml
persistence:
  media:
    enabled: true
    type: nfs
    nfsServer: 192.168.1.10
    nfsPath: /media
    readOnly: true
```

Do not expect this application to be functional until the NAS/NFS storage is
available and the media path is confirmed.

### Arr Stack

`apps/*arr/` is currently only a placeholder directory. In the future it will contain the arr stack to go along with jellyfin.

## Sync Order

The intended sync order is:

1. `homelab-project`
2. `homelab-apps`
3. individual applications under `apps/`

The project application has sync wave `-1`, the app-of-apps has sync wave `0`,
and `gitea-actions` has sync wave `1` so it starts after the base apps.

