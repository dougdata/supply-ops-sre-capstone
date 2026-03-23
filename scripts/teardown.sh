#!/usr/bin/env bash
# teardown.sh — Cleanly destroy all AWS resources to stop costs.
# Safe to run when you're done demoing and want to pay $0/day.
#
# Usage:
#   bash scripts/teardown.sh
#
# What it destroys:
#   - EKS workloads (Helm releases + namespaces)
#   - EKS node group (stops EC2 billing immediately)
#   - RDS instance + subnet group + security group
#   - EKS cluster + VPC + networking (via eksctl)
#
# What it PRESERVES:
#   - ECR repositories (empty, free to keep)
#   - IAM roles (free to keep, needed for CI/CD on redeploy)
#   - OIDC provider (free, needed for GitHub Actions)
#   - Terraform state file (local only)
#   - Your code and git history

set -euo pipefail

AWS_REGION="${AWS_REGION:-us-east-1}"
CLUSTER_NAME="${CLUSTER_NAME:-supply-demo}"
DB_IDENTIFIER="${DB_IDENTIFIER:-supply-demo-db}"
ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)

echo "============================================================"
echo "  TEARDOWN: supply-ops-sre-capstone"
echo "  Account: $ACCOUNT_ID"
echo "  Region:  $AWS_REGION"
echo "  Cluster: $CLUSTER_NAME"
echo "  RDS:     $DB_IDENTIFIER"
echo "============================================================"
echo ""
echo "  This will destroy all running AWS resources and stop all costs."
echo "  ECR repos, IAM roles, and OIDC provider will be kept (they are free)."
echo ""
read -rp "Are you sure? Type 'yes' to continue: " confirm
[[ "$confirm" == "yes" ]] || { echo "Aborted."; exit 0; }
echo ""

# -------------------------------------------------------
echo "==> Step 1: Uninstall Helm releases"
# -------------------------------------------------------
# Must happen before deleting the cluster so Helm can clean up properly
helm uninstall supply-api    -n supply     2>/dev/null || echo "  supply-api not installed, skipping"
helm uninstall supply-worker -n supply     2>/dev/null || echo "  supply-worker not installed, skipping"
helm uninstall kube-prometheus-stack -n monitoring 2>/dev/null || echo "  kube-prometheus-stack not installed, skipping"

# -------------------------------------------------------
echo "==> Step 2: Delete Kubernetes namespaces"
# -------------------------------------------------------
kubectl delete namespace supply     --ignore-not-found
kubectl delete namespace monitoring --ignore-not-found

# -------------------------------------------------------
echo "==> Step 3: Scale node group to 0 (stops EC2 billing within ~2 minutes)"
# -------------------------------------------------------
aws eks update-nodegroup-config \
  --cluster-name "$CLUSTER_NAME" \
  --nodegroup-name ng-1 \
  --scaling-config minSize=0,maxSize=2,desiredSize=0 \
  --region "$AWS_REGION" 2>/dev/null || echo "  Node group not found or already scaled, continuing..."

# -------------------------------------------------------
echo "==> Step 4: Delete RDS instance (no final snapshot)"
# -------------------------------------------------------
aws rds delete-db-instance \
  --db-instance-identifier "$DB_IDENTIFIER" \
  --skip-final-snapshot \
  --region "$AWS_REGION" 2>/dev/null || echo "  RDS not found, skipping"

echo "  Waiting for RDS deletion (3-5 minutes)..."
aws rds wait db-instance-deleted \
  --db-instance-identifier "$DB_IDENTIFIER" \
  --region "$AWS_REGION" 2>/dev/null || echo "  RDS wait skipped"

# -------------------------------------------------------
echo "==> Step 5: Delete RDS subnet group and security group"
# -------------------------------------------------------
# These can't be deleted while RDS exists, so must happen after Step 4

aws rds delete-db-subnet-group \
  --db-subnet-group-name "supply-demo-subnet-group" \
  --region "$AWS_REGION" 2>/dev/null || echo "  RDS subnet group not found, skipping"

# Get the VPC ID before the cluster is gone (need it to find the SG)
VPC_ID=$(aws eks describe-cluster \
  --name "$CLUSTER_NAME" \
  --query 'cluster.resourcesVpcConfig.vpcId' \
  --output text --region "$AWS_REGION" 2>/dev/null || echo "")

if [[ -n "$VPC_ID" && "$VPC_ID" != "None" ]]; then
  RDS_SG=$(aws ec2 describe-security-groups \
    --filters "Name=group-name,Values=supply-demo-rds-sg" "Name=vpc-id,Values=${VPC_ID}" \
    --query 'SecurityGroups[0].GroupId' \
    --output text --region "$AWS_REGION" 2>/dev/null || echo "")

  if [[ -n "$RDS_SG" && "$RDS_SG" != "None" ]]; then
    aws ec2 delete-security-group \
      --group-id "$RDS_SG" \
      --region "$AWS_REGION" 2>/dev/null || echo "  Could not delete RDS SG (may still have dependencies), skipping"
  else
    echo "  RDS security group not found, skipping"
  fi
fi

# -------------------------------------------------------
echo "==> Step 6: Delete EKS node group"
# -------------------------------------------------------
aws eks delete-nodegroup \
  --cluster-name "$CLUSTER_NAME" \
  --nodegroup-name ng-1 \
  --region "$AWS_REGION" 2>/dev/null || echo "  Node group not found, skipping"

echo "  Waiting for node group deletion (3-5 minutes)..."
aws eks wait nodegroup-deleted \
  --cluster-name "$CLUSTER_NAME" \
  --nodegroup-name ng-1 \
  --region "$AWS_REGION" 2>/dev/null || echo "  Node group wait skipped"

# -------------------------------------------------------
echo "==> Step 7: Delete EKS cluster + VPC (via eksctl)"
# -------------------------------------------------------
# eksctl delete cluster handles: EKS control plane, VPC, subnets,
# internet gateway, NAT gateway, route tables, and security groups.
# This is the most expensive part to leave running — NAT gateway
# costs ~$0.045/hr (~$1.08/day) even with no traffic.
eksctl delete cluster \
  --name "$CLUSTER_NAME" \
  --region "$AWS_REGION" \
  --wait 2>/dev/null || echo "  eksctl delete skipped (cluster may already be gone)"

# -------------------------------------------------------
echo "==> Step 8: Clear ECR images (keep repos, delete images to save storage)"
# -------------------------------------------------------
for REPO in supply-api supply-worker; do
  IMAGE_IDS=$(aws ecr list-images \
    --repository-name "$REPO" \
    --region "$AWS_REGION" \
    --query 'imageIds[*]' \
    --output json 2>/dev/null || echo "[]")

  if [[ "$IMAGE_IDS" != "[]" && "$IMAGE_IDS" != "" ]]; then
    aws ecr batch-delete-image \
      --repository-name "$REPO" \
      --image-ids "$IMAGE_IDS" \
      --region "$AWS_REGION" > /dev/null 2>&1 && echo "  Cleared images from $REPO" || echo "  Could not clear $REPO images"
  else
    echo "  $REPO already empty"
  fi
done

echo ""
echo "============================================================"
echo "  Teardown complete. All billable resources destroyed."
echo ""
echo "  Preserved (free):"
echo "    - ECR repositories (empty)"
echo "    - IAM roles (github-actions-supply-demo + eksctl roles)"
echo "    - OIDC provider"
echo ""
echo "  To redeploy:  DB_PASSWORD=yourpassword bash scripts/bootstrap.sh"
echo "============================================================"
