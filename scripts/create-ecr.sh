#!/usr/bin/env bash
# Creates the two ECR repositories (one per tier)
set -euo pipefail
REGION="${AWS_REGION:-ap-south-1}"
for repo in two-tier-app two-tier-db; do
  aws ecr describe-repositories --repository-names "$repo" --region "$REGION" >/dev/null 2>&1 \
  || aws ecr create-repository --repository-name "$repo" --region "$REGION" \
       --image-scanning-configuration scanOnPush=true
  echo "ECR repo ready: $repo"
done
