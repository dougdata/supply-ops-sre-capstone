#!/usr/bin/env bash
# bootstrap.sh — Rebuild the entire supply-ops-sre-capstone stack from scratch.
# Run this after teardown.sh or on a fresh AWS account.
#
# Usage:
#   export AWS_REGION=us-east-1
#   export DB_PASSWORD=your_secure_password
#   bash scripts/bootstrap.sh
#
# Prerequisites:
#   - AWS CLI configured (aws sts get-caller-identity works)
#   - eksctl, kubectl, helm installed
#   - Docker running
#   - This repo cloned locally

set -euo pipefail

AWS_REGION="${AWS_REGION:-us-east-1}"
CLUSTER_NAME="${CLUSTER_NAME:-supply-demo}"
DB_PASSWORD="${DB_PASSWORD:?ERROR: set DB_PASSWORD env var before running}"
ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
ECR_REGISTRY="${ACCOUNT_ID}.dkr.ecr.${AWS_REGION}.amazonaws.com"
REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"

echo "============================================================"
echo "  BOOTSTRAP: supply-ops-sre-capstone"
echo "  Account: $ACCOUNT_ID"
echo "  Region:  $AWS_REGION"
echo "  Cluster: $CLUSTER_NAME"
echo "============================================================"
echo ""

# -------------------------------------------------------
echo "==> Step 1: Create EKS cluster (takes ~15 minutes)"
# -------------------------------------------------------
eksctl create cluster \
  --name "$CLUSTER_NAME" \
  --region "$AWS_REGION" \
  --version 1.35 \
  --nodegroup-name ng-1 \
  --node-type t3.small \
  --nodes 2 \
  --nodes-min 1 \
  --nodes-max 2 \
  --managed

aws eks update-kubeconfig --name "$CLUSTER_NAME" --region "$AWS_REGION"
echo "Cluster ready."

# -------------------------------------------------------
echo "==> Step 2: Create RDS Postgres instance (takes ~5 minutes)"
# -------------------------------------------------------
VPC_ID=$(aws eks describe-cluster \
  --name "$CLUSTER_NAME" \
  --query 'cluster.resourcesVpcConfig.vpcId' \
  --output text --region "$AWS_REGION")

SUBNET_IDS=$(aws ec2 describe-subnets \
  --filters "Name=vpc-id,Values=${VPC_ID}" "Name=map-public-ip-on-launch,Values=false" \
  --query 'Subnets[*].SubnetId' \
  --output text --region "$AWS_REGION" | tr '\t' ',')

aws rds create-db-subnet-group \
  --db-subnet-group-name "supply-demo-subnet-group" \
  --db-subnet-group-description "Supply demo subnet group" \
  --subnet-ids $(echo $SUBNET_IDS | tr ',' ' ') \
  --region "$AWS_REGION" 2>/dev/null || echo "Subnet group already exists"

# Use the cluster security group from EKS — this is always the SG
# attached to node EC2 instances, regardless of eksctl tag naming.
NODE_SG=$(aws eks describe-cluster \
  --name "$CLUSTER_NAME" \
  --query 'cluster.resourcesVpcConfig.clusterSecurityGroupId' \
  --output text --region "$AWS_REGION")
echo "  Node SG: $NODE_SG"

# Create RDS security group (idempotent)
RDS_SG=$(aws ec2 create-security-group \
  --group-name "supply-demo-rds-sg" \
  --description "RDS access from EKS nodes" \
  --vpc-id "$VPC_ID" \
  --region "$AWS_REGION" \
  --query 'GroupId' --output text 2>/dev/null || \
  aws ec2 describe-security-groups \
    --filters "Name=group-name,Values=supply-demo-rds-sg" "Name=vpc-id,Values=${VPC_ID}" \
    --query 'SecurityGroups[0].GroupId' --output text --region "$AWS_REGION")

aws ec2 authorize-security-group-ingress \
  --group-id "$RDS_SG" \
  --protocol tcp --port 5432 \
  --source-group "$NODE_SG" \
  --region "$AWS_REGION" 2>/dev/null || echo "RDS SG rule already exists"

aws rds create-db-instance \
  --db-instance-identifier supply-demo-db \
  --db-instance-class db.t3.micro \
  --engine postgres \
  --engine-version 17 \
  --master-username supplyadmin \
  --master-user-password "$DB_PASSWORD" \
  --db-name supply \
  --allocated-storage 20 \
  --db-subnet-group-name supply-demo-subnet-group \
  --vpc-security-group-ids "$RDS_SG" \
  --no-publicly-accessible \
  --no-multi-az \
  --region "$AWS_REGION" 2>/dev/null || echo "RDS already exists"

echo "Waiting for RDS to be available (5-10 minutes)..."
aws rds wait db-instance-available \
  --db-instance-identifier supply-demo-db \
  --region "$AWS_REGION"

RDS_ENDPOINT=$(aws rds describe-db-instances \
  --db-instance-identifier supply-demo-db \
  --query 'DBInstances[0].Endpoint.Address' \
  --output text --region "$AWS_REGION")
echo "RDS ready at: $RDS_ENDPOINT"

# -------------------------------------------------------
echo "==> Step 3: Create ECR repositories"
# -------------------------------------------------------
aws ecr create-repository --repository-name supply-api \
  --region "$AWS_REGION" 2>/dev/null || echo "ECR supply-api already exists"
aws ecr create-repository --repository-name supply-worker \
  --region "$AWS_REGION" 2>/dev/null || echo "ECR supply-worker already exists"

# -------------------------------------------------------
echo "==> Step 4: Build and push Docker images"
# -------------------------------------------------------
aws ecr get-login-password --region "$AWS_REGION" | \
  docker login --username AWS --password-stdin "$ECR_REGISTRY"

docker build -t supply-api:latest "$REPO_ROOT/services/supply_api"
docker tag supply-api:latest "$ECR_REGISTRY/supply-api:latest"
docker push "$ECR_REGISTRY/supply-api:latest"

docker build -t supply-worker:latest "$REPO_ROOT/services/supply_worker"
docker tag supply-worker:latest "$ECR_REGISTRY/supply-worker:latest"
docker push "$ECR_REGISTRY/supply-worker:latest"

# -------------------------------------------------------
echo "==> Step 5: Create Kubernetes namespace and secret"
# -------------------------------------------------------
# Must happen BEFORE schema apply so the pod runs in the supply namespace,
# which has connectivity to RDS via the node security group.
kubectl create namespace supply --dry-run=client -o yaml | kubectl apply -f -

kubectl -n supply create secret generic supply-secrets \
  --from-literal=DATABASE_URL="postgresql+psycopg://supplyadmin:${DB_PASSWORD}@${RDS_ENDPOINT}:5432/supply" \
  --dry-run=client -o yaml | kubectl apply -f -

# -------------------------------------------------------
echo "==> Step 6: Apply database schema"
# -------------------------------------------------------
# Runs in the supply namespace (created in Step 5) so it reaches RDS
# through the cluster security group that's already allowed in the RDS SG.
echo "Applying schema via in-cluster pod..."
kubectl -n supply run schema-apply \
  --image=postgres:17 \
  --restart=Never \
  --rm -i \
  --env="PGPASSWORD=${DB_PASSWORD}" \
  -- psql \
    -h "$RDS_ENDPOINT" \
    -U supplyadmin \
    -d supply \
    < "$REPO_ROOT/platform/sql/schema.sql" && echo "Schema applied."

# -------------------------------------------------------
echo "==> Step 7: Deploy services via Helm"
# -------------------------------------------------------
helm upgrade --install supply-api "$REPO_ROOT/infra/helm/supply-api" \
  --namespace supply \
  --set image.repository="$ECR_REGISTRY/supply-api" \
  --set image.tag="latest" \
  --wait --timeout 5m

helm upgrade --install supply-worker "$REPO_ROOT/infra/helm/supply-worker" \
  --namespace supply \
  --set image.repository="$ECR_REGISTRY/supply-worker" \
  --set image.tag="latest" \
  --wait --timeout 5m

# -------------------------------------------------------
echo "==> Step 8: Install monitoring stack"
# -------------------------------------------------------
bash "$REPO_ROOT/observability/install-monitoring.sh"

# Ensure ServiceMonitors and SLO rules are applied even if
# install-monitoring.sh timed out before reaching those steps
echo "==> Step 8b: Apply ServiceMonitors and SLO rules"
kubectl apply -f "$REPO_ROOT/observability/service-monitors.yaml"
kubectl apply -f "$REPO_ROOT/observability/slo-rules.yaml"

# -------------------------------------------------------
echo "==> Step 9: Add GitHub Actions role to EKS aws-auth"
# -------------------------------------------------------
GHA_ROLE_ARN="arn:aws:iam::${ACCOUNT_ID}:role/github-actions-supply-demo"

if aws iam get-role --role-name github-actions-supply-demo \
     --region "$AWS_REGION" &>/dev/null; then
  kubectl -n kube-system patch configmap aws-auth --patch "
data:
  mapRoles: |
    - rolearn: $(aws eks describe-nodegroup \
        --cluster-name $CLUSTER_NAME \
        --nodegroup-name ng-1 \
        --query 'nodegroup.nodeRole' \
        --output text --region $AWS_REGION)
      groups:
      - system:bootstrappers
      - system:nodes
      username: system:node:{{EC2PrivateDNSName}}
    - rolearn: ${GHA_ROLE_ARN}
      groups:
      - system:masters
      username: github-actions
"
  echo "GitHub Actions role added to aws-auth."
else
  echo "WARNING: github-actions-supply-demo IAM role not found."
  echo "         Run the OIDC setup commands from the README before using CI/CD."
fi

# -------------------------------------------------------
echo "==> Step 10: Verify everything is running"
# -------------------------------------------------------
echo ""
echo "--- Supply namespace ---"
kubectl -n supply get pods

echo ""
echo "--- Monitoring namespace ---"
kubectl -n monitoring get pods | grep -E "NAME|Running"

echo ""
echo "============================================================"
echo "  Bootstrap complete!"
echo ""
echo "  Grafana:  kubectl -n monitoring port-forward svc/kube-prometheus-stack-grafana 3000:80"
echo "            http://localhost:3000  (admin / supply-demo-admin)"
echo ""
echo "  Generate events:"
echo "    bash scripts/generate-events.sh steady"
echo ""
echo "  Teardown when done:  bash scripts/teardown.sh"
echo "============================================================"
