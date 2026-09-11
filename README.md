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
│   ├── media-storage/
│   ├── navidrome/
│   └── *arr/
├── manifests/
│   ├── lidarr/
│   ├── media-storage/
│   ├── musicgrabber/
│   └── navidrome/
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
    nfsServer: media-nfs.home.arpa
    nfsPath: /media
    readOnly: true
```

Do not expect this application to be functional until the NAS/NFS storage is
available and the media path is confirmed.

### Media Storage

`apps/media-storage/` deploys the shared NFS-backed storage primitives used by
the music stack. The manifests create the `navidrome` and `arr` namespaces, then
bind static `PersistentVolume` and `PersistentVolumeClaim` resources to the
media NFS server.

The media NFS server is expected to be provisioned by
`k3s-proxmox-terraform` and resolvable by every Kubernetes node as
`media-nfs.home.arpa`.

- music export: `media-nfs.home.arpa:/srv/media/music`, advertised as `150Gi`
- downloads export: `media-nfs.home.arpa:/srv/media/downloads`, advertised as
  `20Gi`
- `navidrome-music`: `navidrome` namespace claim for the music export
- `arr-music`: `arr` namespace claim for the same music export
- `arr-downloads`: `arr` namespace claim for the downloads export

The NFS exports are intended to be writable by applications running as
UID/GID `1000:1000`.

### Navidrome

`apps/navidrome/` deploys Navidrome from a raw Kubernetes manifest:

- image: `deluan/navidrome:latest`
- namespace: `navidrome`
- HTTP NodePort: `30453`
- data PVC: `navidrome-data`, mounted at `/data`
- music PVC: `navidrome-music`, mounted read-only at `/music`

Navidrome is configured with:

```yaml
ND_MUSICFOLDER: /music
ND_DATAFOLDER: /data
ND_SCANNER_SCHEDULE: '@every 5m'
ND_ENABLESHARING: 'true'
```

Navidrome scans the shared music export directly. It should see music once files
exist under `/srv/media/music` on the NFS server and are visible inside the pod
at `/music`.

### Arr Stack

`apps/*arr/` deploys the music automation applications that go along with
Jellyfin and Navidrome. The stack currently contains Lidarr and MusicGrabber.

#### Lidarr

`manifests/lidarr/` deploys Lidarr:

- image: `lscr.io/linuxserver/lidarr:latest`
- namespace: `arr`
- HTTP NodePort: `30686`
- config PVC: `lidarr-config`, mounted at `/config`
- music PVC: `arr-music`, mounted at `/music`
- downloads PVC: `arr-downloads`, mounted at `/downloads`
- runtime UID/GID: `1000:1000`

Lidarr has storage access, but it still needs application-level setup in the UI:

1. Add `/music` as a root folder.
2. Use Library Import to import existing artists/albums from `/music`.
3. Configure a download client before expecting Lidarr to fetch new releases.

Lidarr does not scan `/music` the same way Navidrome does. Navidrome indexes
whatever it can read in the music folder, while Lidarr manages monitored
artists/albums and imports matched media into the root folder.

Useful checks:

```bash
kubectl -n arr exec deploy/lidarr -- \
  sh -lc 'id; ls -la /music; find /music -maxdepth 3 -type f | head -20'

kubectl -n arr exec deploy/lidarr -- \
  sh -lc 'touch /music/.lidarr-write-test && rm /music/.lidarr-write-test'
```

#### MusicGrabber

`manifests/musicgrabber/` deploys MusicGrabber:

- image: `g33kphr33k/musicgrabber:latest`
- namespace: `arr`
- HTTP NodePort: `30274`
- data PVC: `musicgrabber-data`, mounted at `/data`
- music PVC: `arr-music`, mounted at `/music`
- shared memory: `/dev/shm`, backed by a `2Gi` in-memory `emptyDir`

MusicGrabber is configured to write music into `/music`, store its database at
`/data/music_grabber.db`, enable MusicBrainz and lyrics support, convert to FLAC
by default, and point at Navidrome through the in-cluster service URL:

```yaml
NAVIDROME_URL: http://navidrome.navidrome.svc.cluster.local:4533
```

#### Pending External Acquisition

The current repository does not deploy Prowlarr or a download client yet. Lidarr
can import existing music from `/music`, but for automated external acquisition
the stack still needs:

- Prowlarr for indexer/search integration.
- qBittorrent or another download client mounted to the same `arr-downloads`
  claim at `/downloads`.
- Lidarr configured with the download client, a `lidarr` category, and any
  required remote path mapping so completed downloads resolve to `/downloads`.

The intended completed flow is:

```text
Prowlarr -> Lidarr -> qBittorrent -> /downloads -> Lidarr import -> /music -> Navidrome
```

Because PVCs are namespace-scoped, `navidrome-music` and `arr-music` are
separate Kubernetes claims pointing at the same NFS directory. Their `150Gi`
sizes describe the same backing music export and should not be added together.

## Sync Order

The intended sync order is:

1. `homelab-project`
2. `homelab-apps`
3. individual applications under `apps/`

The project application has sync wave `-1`, the app-of-apps has sync wave `0`,
`gitea-actions` and `media-storage` have sync wave `1`, and the music
applications have sync wave `2`. Media storage should exist before Navidrome,
Lidarr, and MusicGrabber try to mount the shared NFS claims.
