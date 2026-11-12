#!/usr/bin/env bash
# One-time (idempotent) provisioning of everything sub2api needs on GCP.
# Re-running is safe: each step checks for the resource before creating it.
#
#   ./bootstrap.sh            # run every stage
#   ./bootstrap.sh network    # run a single stage:
#                             # network | cluster | sql | redis | registry | ip | cert | secrets | ci | k8s
#
# Requires: gcloud (authenticated, with owner/editor on the project), kubectl, openssl.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=env.sh
source "${HERE}/env.sh"

g() { gcloud --project "${PROJECT_ID}" --quiet "$@"; }
exists() { "$@" >/dev/null 2>&1; }
log() { printf '\n==> %s\n' "$*"; }

PROJECT_NUMBER="$(g projects describe "${PROJECT_ID}" --format='value(projectNumber)')"
NETWORK_URI="projects/${PROJECT_ID}/global/networks/${NETWORK}"

stage_network() {
  log "VPC ${NETWORK}"
  exists g compute networks describe "${NETWORK}" ||
    g compute networks create "${NETWORK}" --subnet-mode custom

  exists g compute networks subnets describe "${SUBNET}" --region "${REGION}" ||
    g compute networks subnets create "${SUBNET}" --region "${REGION}" --network "${NETWORK}" \
      --range "${SUBNET_RANGE}" --enable-private-ip-google-access \
      --secondary-range "${PODS_RANGE_NAME}=${PODS_RANGE},${SERVICES_RANGE_NAME}=${SERVICES_RANGE}"

  log "Cloud NAT with a fixed egress IP (private nodes reach upstream APIs through it)"
  exists g compute addresses describe "${NAT_IP_NAME}" --region "${REGION}" ||
    g compute addresses create "${NAT_IP_NAME}" --region "${REGION}"
  exists g compute routers describe "${ROUTER}" --region "${REGION}" ||
    g compute routers create "${ROUTER}" --region "${REGION}" --network "${NETWORK}"
  exists g compute routers nats describe "${NAT}" --router "${ROUTER}" --region "${REGION}" ||
    g compute routers nats create "${NAT}" --router "${ROUTER}" --region "${REGION}" \
      --nat-all-subnet-ip-ranges --nat-external-ip-pool "${NAT_IP_NAME}" \
      --enable-dynamic-port-allocation --min-ports-per-vm 1024 --max-ports-per-vm 65536

  log "Private services access (Cloud SQL / Memorystore private IPs)"
  exists g compute addresses describe "${PSA_RANGE_NAME}" --global ||
    g compute addresses create "${PSA_RANGE_NAME}" --global --purpose VPC_PEERING \
      --addresses "${PSA_RANGE_ADDR}" --prefix-length "${PSA_RANGE_PREFIX}" --network "${NETWORK}"
  if ! g services vpc-peerings list --network "${NETWORK}" --format='value(peering)' | grep -q servicenetworking; then
    g services vpc-peerings connect --service servicenetworking.googleapis.com \
      --network "${NETWORK}" --ranges "${PSA_RANGE_NAME}"
  fi
}

stage_cluster() {
  log "GKE Autopilot cluster ${CLUSTER}"
  # create-auto also writes a kubeconfig entry and switches the current context;
  # point it at a throwaway file so the caller's kubectl setup is untouched.
  exists g container clusters describe "${CLUSTER}" --region "${REGION}" ||
    KUBECONFIG="$(mktemp -d)/kubeconfig" g container clusters create-auto "${CLUSTER}" --region "${REGION}" \
      --network "${NETWORK}" --subnetwork "${SUBNET}" \
      --cluster-secondary-range-name "${PODS_RANGE_NAME}" \
      --services-secondary-range-name "${SERVICES_RANGE_NAME}" \
      --enable-private-nodes --enable-dns-access --release-channel regular
}

stage_sql() {
  log "Cloud SQL ${SQL_INSTANCE}"
  exists g sql instances describe "${SQL_INSTANCE}" ||
    g sql instances create "${SQL_INSTANCE}" --region "${REGION}" \
      --database-version "${SQL_VERSION}" --edition enterprise --tier "${SQL_TIER}" \
      --availability-type zonal --storage-type SSD --storage-size "${SQL_DISK_GB}GB" --storage-auto-increase \
      --network "${NETWORK_URI}" --no-assign-ip \
      --backup-start-time 18:00 --deletion-protection

  exists g sql databases describe "${SQL_DATABASE}" --instance "${SQL_INSTANCE}" ||
    g sql databases create "${SQL_DATABASE}" --instance "${SQL_INSTANCE}"

  ensure_secret sub2api-db-password
  if ! g sql users list --instance "${SQL_INSTANCE}" --format='value(name)' | grep -qx "${SQL_USER}"; then
    g sql users create "${SQL_USER}" --instance "${SQL_INSTANCE}" \
      --password "$(read_secret sub2api-db-password)"
  fi
}

stage_redis() {
  log "Memorystore ${REDIS_INSTANCE}"
  exists g redis instances describe "${REDIS_INSTANCE}" --region "${REGION}" ||
    g redis instances create "${REDIS_INSTANCE}" --region "${REGION}" \
      --tier basic --size "${REDIS_SIZE_GB}" --redis-version "${REDIS_VERSION}" \
      --network "${NETWORK_URI}" --connect-mode private-service-access \
      --reserved-ip-range "${PSA_RANGE_NAME}" --enable-auth
}

stage_registry() {
  log "Artifact Registry ${AR_REPO}"
  exists g artifacts repositories describe "${AR_REPO}" --location "${REGION}" ||
    g artifacts repositories create "${AR_REPO}" --location "${REGION}" \
      --repository-format docker --description "sub2api images (lkv-cluster)"
}

stage_ip() {
  log "Public static IP ${GATEWAY_IP_NAME}"
  exists g compute addresses describe "${GATEWAY_IP_NAME}" --global ||
    g compute addresses create "${GATEWAY_IP_NAME}" --global
  g compute addresses describe "${GATEWAY_IP_NAME}" --global --format='value(address)'
}

stage_cert() {
  log "Google-managed certificate for ${DOMAIN} and *.${DOMAIN} (DNS-authorised)"
  local cm=(certificate-manager)
  exists g "${cm[@]}" dns-authorizations describe "${CERT_NAME}" ||
    g "${cm[@]}" dns-authorizations create "${CERT_NAME}" --domain "${DOMAIN}"
  exists g "${cm[@]}" certificates describe "${CERT_NAME}" ||
    g "${cm[@]}" certificates create "${CERT_NAME}" \
      --domains "${DOMAIN},*.${DOMAIN}" --dns-authorizations "${CERT_NAME}"
  exists g "${cm[@]}" maps describe "${CERT_NAME}" ||
    g "${cm[@]}" maps create "${CERT_NAME}"
  exists g "${cm[@]}" maps entries describe apex --map "${CERT_NAME}" ||
    g "${cm[@]}" maps entries create apex --map "${CERT_NAME}" \
      --hostname "${DOMAIN}" --certificates "${CERT_NAME}"
  exists g "${cm[@]}" maps entries describe wildcard --map "${CERT_NAME}" ||
    g "${cm[@]}" maps entries create wildcard --map "${CERT_NAME}" \
      --hostname "*.${DOMAIN}" --certificates "${CERT_NAME}"

  echo "Add this record at your DNS provider (Cloudflare: DNS only, not proxied):"
  g "${cm[@]}" dns-authorizations describe "${CERT_NAME}" \
    --format='table(dnsResourceRecord.type,dnsResourceRecord.name,dnsResourceRecord.data)'
  echo "Certificate state: $(g "${cm[@]}" certificates describe "${CERT_NAME}" --format='value(managed.state)')"
}

# --- Secret Manager helpers: generated once, never rotated by this script ---
ensure_secret() {
  local name="$1"
  if ! exists g secrets describe "${name}"; then
    g secrets create "${name}" --replication-policy automatic --labels app=sub2api
    openssl rand -hex 32 | tr -d '\n' | g secrets versions add "${name}" --data-file=-
  fi
}
read_secret() { g secrets versions access latest --secret "$1"; }

stage_secrets() {
  log "Secret Manager"
  for s in sub2api-db-password sub2api-jwt-secret sub2api-totp-key sub2api-admin-password; do
    ensure_secret "${s}"
  done
}

stage_ci() {
  log "GitHub Actions deploy identity"
  local sa="${DEPLOY_SA}@${PROJECT_ID}.iam.gserviceaccount.com"
  exists g iam service-accounts describe "${sa}" ||
    g iam service-accounts create "${DEPLOY_SA}" \
      --display-name "sub2api deploy (GitHub Actions ${GITHUB_REPO} via WIF)"

  exists g iam workload-identity-pools describe "${WIF_POOL}" --location global ||
    g iam workload-identity-pools create "${WIF_POOL}" --location global \
      --display-name "lkv GitHub Actions"
  exists g iam workload-identity-pools providers describe "${WIF_PROVIDER}" \
    --workload-identity-pool "${WIF_POOL}" --location global ||
    g iam workload-identity-pools providers create-oidc "${WIF_PROVIDER}" \
      --workload-identity-pool "${WIF_POOL}" --location global \
      --issuer-uri https://token.actions.githubusercontent.com \
      --attribute-mapping "google.subject=assertion.sub,attribute.repository=assertion.repository,attribute.ref=assertion.ref" \
      --attribute-condition "assertion.repository == \"${GITHUB_REPO}\""

  g iam service-accounts add-iam-policy-binding "${sa}" \
    --role roles/iam.workloadIdentityUser \
    --member "principalSet://iam.googleapis.com/projects/${PROJECT_NUMBER}/locations/global/workloadIdentityPools/${WIF_POOL}/attribute.repository/${GITHUB_REPO}" >/dev/null

  # Push images to this one repository only.
  g artifacts repositories add-iam-policy-binding "${AR_REPO}" --location "${REGION}" \
    --member "serviceAccount:${sa}" --role roles/artifactregistry.writer >/dev/null
  # Enough to fetch cluster credentials; what it may do inside the cluster is
  # decided by the Kubernetes RoleBinding in k8s/bootstrap (namespace-scoped).
  g projects add-iam-policy-binding "${PROJECT_ID}" \
    --member "serviceAccount:${sa}" --role roles/container.clusterViewer --condition None >/dev/null
}

stage_k8s() {
  log "Cluster bootstrap: namespace, CI RBAC, runtime secret"
  # Private kubeconfig so the caller's current kubectl context is left alone.
  local kd kc
  kd="$(mktemp -d)"
  kc="${kd}/kubeconfig"
  trap 'rm -rf "${kd}"' RETURN
  KUBECONFIG="${kc}" g container clusters get-credentials "${CLUSTER}" --region "${REGION}" --dns-endpoint
  local k=(kubectl --kubeconfig "${kc}")

  "${k[@]}" apply -k "${HERE}/k8s/bootstrap"

  local sql_ip redis_ip
  sql_ip="$(g sql instances describe "${SQL_INSTANCE}" --format='value(ipAddresses[0].ipAddress)')"
  redis_ip="$(g redis instances describe "${REDIS_INSTANCE}" --region "${REGION}" --format='value(host)')"

  "${k[@]}" -n "${NAMESPACE}" create secret generic sub2api-env \
    --from-literal=DATABASE_HOST="${sql_ip}" \
    --from-literal=DATABASE_USER="${SQL_USER}" \
    --from-literal=DATABASE_DBNAME="${SQL_DATABASE}" \
    --from-literal=DATABASE_PASSWORD="$(read_secret sub2api-db-password)" \
    --from-literal=REDIS_HOST="${redis_ip}" \
    --from-literal=REDIS_PASSWORD="$(g redis instances get-auth-string "${REDIS_INSTANCE}" --region "${REGION}" --format='value(authString)')" \
    --from-literal=JWT_SECRET="$(read_secret sub2api-jwt-secret)" \
    --from-literal=TOTP_ENCRYPTION_KEY="$(read_secret sub2api-totp-key)" \
    --from-literal=ADMIN_EMAIL="${ADMIN_EMAIL}" \
    --from-literal=ADMIN_PASSWORD="$(read_secret sub2api-admin-password)" \
    --dry-run=client -o yaml | "${k[@]}" apply -f -
}

stages=("$@")
[ ${#stages[@]} -eq 0 ] && stages=(network cluster sql redis registry ip cert secrets ci k8s)
for s in "${stages[@]}"; do "stage_${s}"; done
log "done"
