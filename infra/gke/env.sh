# Shared settings for infra/gke scripts and the gke-deploy workflow.
# Sourced by bash; keep it to plain KEY=value assignments.

PROJECT_ID=gtxy-rzn-infra
REGION=us-east1

# Network (ranges chosen to not overlap any other VPC in the project)
NETWORK=lkv-vpc
SUBNET=lkv-us-east1
SUBNET_RANGE=10.84.0.0/24
PODS_RANGE_NAME=lkv-pods
PODS_RANGE=10.86.0.0/17
SERVICES_RANGE_NAME=lkv-services
SERVICES_RANGE=10.87.0.0/20
PSA_RANGE_NAME=lkv-psa
PSA_RANGE_ADDR=10.85.0.0
PSA_RANGE_PREFIX=20
ROUTER=lkv-router
NAT=lkv-nat
NAT_IP_NAME=lkv-nat-ip

# GKE
CLUSTER=lkv-cluster
NAMESPACE=ns-sub2api

# Data stores (entry-level sizes; resize later with gcloud sql/redis ... update)
SQL_INSTANCE=sub2api-pg
SQL_VERSION=POSTGRES_18
SQL_TIER=db-custom-1-3840
SQL_DISK_GB=10
SQL_DATABASE=sub2api
SQL_USER=sub2api
REDIS_INSTANCE=sub2api-redis
REDIS_VERSION=redis_7_2
REDIS_SIZE_GB=1

# Image registry
AR_REPO=sub2api
IMAGE=us-east1-docker.pkg.dev/gtxy-rzn-infra/sub2api/sub2api

# Public entry
GATEWAY_IP_NAME=lkv-sub2api-ip
DOMAIN=bigaccount.cc
# DNS authorization, certificate and certificate map all share this name
CERT_NAME=lkv-sub2api

# GitHub Actions identity
GITHUB_REPO=rezona-ai/sub2api-lkv
WIF_POOL=lkv-github
WIF_PROVIDER=github
DEPLOY_SA=sub2api-deploy

# App bootstrap admin (login name of the first admin account)
ADMIN_EMAIL=admin@bigaccount.cc
