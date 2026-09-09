# Gitea Actions runner token

This directory is included by the `gitea-actions` ArgoCD Application.

After the Sealed Secrets controller is synced, generate and seal the runner
token with:

```bash
./scripts/seal-gitea-actions-token.sh
```

The script:

- waits for the Sealed Secrets controller
- finds the running Gitea pod
- runs `gitea actions generate-runner-token`
- seals the token as `gitea-actions-runner-token`
- updates `kustomization.yaml`

It requires local `kubectl` access to the cluster and the `kubeseal` CLI.
