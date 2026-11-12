# sub2api on GKE (lkv-cluster)

Fork-only deployment of sub2api to Google Cloud. Everything specific to this
deployment lives in two places, so merges from upstream never conflict:

- `infra/gke/` — this directory
- `.github/workflows/gke-deploy.yml` — the manual deploy workflow

No upstream file is modified.

## What runs where

| Piece | Resource |
|---|---|
| Project / region | `gtxy-rzn-infra` / `us-east1` |
| Network | VPC `lkv-vpc`, subnet `lkv-us-east1`, Cloud NAT `lkv-nat` with fixed egress IP `lkv-nat-ip` |
| Cluster | GKE Autopilot `lkv-cluster` (private nodes, DNS-based control-plane endpoint) |
| App | Deployment `sub2api` in namespace `ns-sub2api`, 1 replica |
| PostgreSQL | Cloud SQL `sub2api-pg` — PG 18, `db-custom-1-3840`, 10 GB SSD, private IP only |
| Redis | Memorystore `sub2api-redis` — Basic, 1 GB, Redis 7.2, AUTH on |
| Images | Artifact Registry `us-east1-docker.pkg.dev/gtxy-rzn-infra/sub2api/sub2api` |
| Public entry | Gateway `sub2api` (global external ALB) on static IP `lkv-sub2api-ip`, ports 80 and 443 |
| TLS | Certificate Manager cert + map `lkv-sub2api` for `bigaccount.cc` and `*.bigaccount.cc` |
| Secrets | Secret Manager `sub2api-*` → Kubernetes Secret `sub2api-env` |
| CI identity | Service account `sub2api-deploy`, WIF pool `lkv-github` (only `rezona-ai/sub2api-lkv`) |

All names and sizes are in [`env.sh`](env.sh).

## Files

```
env.sh            shared settings (names, ranges, sizes)
bootstrap.sh      idempotent provisioning of all GCP resources + cluster bootstrap
k8s/bootstrap/    namespace and CI RBAC          (applied by bootstrap.sh, needs cluster admin)
k8s/app/          ConfigMap, Deployment, Service, Gateway, policies   (applied by the workflow)
```

## Deploying

GitHub → Actions → **GKE Deploy** → *Run workflow* → enter the branch (or tag /
SHA). The workflow builds the root `Dockerfile` at that ref, pushes
`…/sub2api:<commit sha>`, applies `k8s/app` and waits for the rollout.

The manifests are always taken from the branch the workflow runs on (normally
`main`), so a branch that has no `infra/gke` — for example a plain upstream
branch — can still be deployed.

Roll back by running the workflow again with an older commit SHA, or:

```bash
kubectl -n ns-sub2api rollout undo deployment/sub2api
```

## Access

```bash
gcloud compute addresses describe lkv-sub2api-ip --global --format='value(address)'
```

- `https://bigaccount.cc/` is the entry point. Plain HTTP (by domain or by IP)
  answers with a 301 redirect to HTTPS.
- First admin login: e-mail is `ADMIN_EMAIL` in `env.sh`, password:
  `gcloud secrets versions access latest --secret sub2api-admin-password`.
  The admin is only created when the users table is empty; change the password
  in the UI afterwards.

### Domain (Cloudflare)

Records in Cloudflare DNS (already in place for `bigaccount.cc`):

1. The certificate validation record printed by `./bootstrap.sh cert`
   (`CNAME _acme-challenge.bigaccount.cc → ….authorize.certificatemanager.goog.`),
   **DNS only** (grey cloud).
2. `A  bigaccount.cc → <ip>` (and any sub-domain you want, e.g. `api`).

The certificate becomes `ACTIVE` some minutes after record 1 resolves; check with
`./bootstrap.sh cert`. HTTPS then works with no further change. If the records
are proxied through Cloudflare (orange cloud), set SSL/TLS mode to
**Full (strict)**.

Optionally set `SERVER_FRONTEND_URL` in `k8s/app/configmap.yaml` so links in
e-mails use the domain.

## Operations

```bash
# kubectl access
gcloud container clusters get-credentials lkv-cluster --region us-east1 \
  --project gtxy-rzn-infra --dns-endpoint

kubectl -n ns-sub2api get pods,gateway
kubectl -n ns-sub2api logs deploy/sub2api -f
```

- **Change settings**: non-secret env in `k8s/app/configmap.yaml` (any variable
  from `deploy/.env.example`), then redeploy and
  `kubectl -n ns-sub2api rollout restart deploy/sub2api`.
- **Change secrets**: add a new version in Secret Manager, run
  `./bootstrap.sh k8s`, then restart the deployment. `JWT_SECRET` is pinned in the
  database after first start; `TOTP_ENCRYPTION_KEY` must never change.
- **Resize the database / Redis**: edit `env.sh` for the record, then
  `gcloud sql instances patch sub2api-pg --tier <tier>` (short restart) or
  `gcloud redis instances update sub2api-redis --region us-east1 --size <GB>`.
- **Scale out**: raise `replicas` in `k8s/app/deployment.yaml`. Background jobs
  use a shared leader lock, but keep `replicas × DATABASE_MAX_OPEN_CONNS` below
  the Cloud SQL connection limit (100 on the current tier).
- **Upstream egress IP** (for allow-lists at providers):
  `gcloud compute addresses describe lkv-nat-ip --region us-east1 --format='value(address)'`.

## Rebuilding from scratch

```bash
./bootstrap.sh            # all stages, safe to re-run
./bootstrap.sh sql redis  # or selected stages
```

Cloud SQL has deletion protection on; disable it explicitly before deleting.
