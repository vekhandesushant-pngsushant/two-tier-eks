#!/usr/bin/env bash
# Creates mysql-secret in the cluster. Passwords Git madhe jaat nahit.
set -euo pipefail
NS=two-tier
kubectl get ns $NS >/dev/null 2>&1 || kubectl create ns $NS
ROOT_PW="${MYSQL_ROOT_PASSWORD:-$(openssl rand -base64 18)}"
APP_PW="${MYSQL_PASSWORD:-$(openssl rand -base64 18)}"
kubectl -n $NS create secret generic mysql-secret \
  --from-literal=MYSQL_ROOT_PASSWORD="$ROOT_PW" \
  --from-literal=MYSQL_DATABASE=appdb \
  --from-literal=MYSQL_USER=appuser \
  --from-literal=MYSQL_PASSWORD="$APP_PW" \
  --dry-run=client -o yaml | kubectl apply -f -
echo "Secret mysql-secret created/updated in namespace $NS"
