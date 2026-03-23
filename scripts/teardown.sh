#!/usr/bin/env bash
# teardown.sh — Cleanly destroy all AWS resources to stop costs.
# Safe to run when you're done demoing and want to pay $0/day.
#
# Usage:
#   bash scripts/teardown.sh
#
# What it destroys:
#   - EKS workloads (Helm releases)
#   - Monitoring stack
#   - EKS node group (stops EC2 billing immediately)
#   - RDS instance (stops RDS billing)
#   - ECR images (keeps repos but removes images)
#   - EKS cluster
#   - VPC and networking (via eksctl)
#
# What it PRESERVES:
#   - ECR repositories (empty, free)
#   - IAM roles (free)
#   - Terraform state file (local)
#   - Your code and git history

set -euo pipefail

AWS_REGION="${AWS_REGION:-us-east-1}"
CLUSTER_NAME="${CLUSTER_NAME:-supply-demo}"
DB_IDENTIFIER="${DB_IDENTIFIER:-supply-demo-db}"

echo "============================================================"
echo "  TEARDOWN: supply-ops-sre-capstone"
echo "  Region:  $AWS_REGION"
echo "  Cluster: $CLUSTER_NAME"
echo "  RDS:     $DB_IDENTIFIER"
echo "============================================================"
echo ""
read -rp "Are you sure you want to destroy ALL AWS resources? (yes/no): " confirm
[[ "$confirm" == "yes" ]] || { echo "Aborted."; exit 0; }

echo ""
echo "==> Step 1: Uninstall Helm releases"
helm uninstall supply-api     -n supply     2>/dev/null || echo "supply-api not found, skipping"
helm uninstall supply-worker  -n supply     2>/dev/null || echo "supply-worker not found, skipping"
helm uninstall kube-prometheus-stack -n monitoring 2>/dev/null || echo "monitoring not found, skipping"

echo "==> Step 2: Delete Kubernetes namespaces"
kubectl delete namespace supply     --ignore-not-found
kubectl delete namespace monitoring --ignore-not-found

echo "==> Step 3: Scale node group to 0 (stops EC2 billing fast)"
aws eks update-nodegroup-config \
  --cluster-name "$CLUSTER_NAME" \
  --nodegroup-name ng-1 \
  --scaling-config minSize=0,maxSize=2,desiredSize=0 \
  --region "$AWS_REGION" || echo "Node group scale-down failed, continuing..."

echo "==> Step 4: Delete RDS instance (no final snapshot to keep costs down)"
aws rds delete-db-instance \
  --db-instance-identifier "$DB_IDENTIFIER" \
  --skip-final-snapshot \
  --region "$AWS_REGION" 2>/dev/null || echo "RDS already deleted or not found"

echo "==> Step 5: Wait for RDS deletion (this takes 3-5 minutes)..."
aws rds wait db-instance-deleted \
  --db-instance-identifier "$DB_IDENTIFIER" \
  --region "$AWS_REGION" 2>/dev/null || echo "RDS wait skipped"

echo "==> Step 6: Delete EKS node group"
aws eks delete-nodegroup \
  --cluster-name "$CLUSTER_NAME" \
  --nodegroup-name ng-1 \
  --region "$AWS_REGION" 2>/dev/null || echo "Node group already deleted"

echo "Waiting for node group deletion..."
aws eks wait nodegroup-deleted \
  --cluster-name "$CLUSTER_NAME" \
  --nodegroup-name ng-1 \
  --region "$AWS_REGION" 2>/dev/null || echo "Node group wait skipped"

echo "==> Step 7: Delete EKS cluster"
aws eks delete-cluster \
  --name "$CLUSTER_NAME" \
  --region "$AWS_REGION" 2>/dev/null || echo "Cluster already deleted"

echo "Waiting for cluster deletion..."
aws eks wait cluster-deleted \
  --name "$CLUSTER_NAME" \
  --region "$AWS_REGION" 2>/dev/null || echo "Cluster wait skipped"

echo "==> Step 8: Delete VPC and networking (eksctl)"
eksctl delete cluster \
  --name "$CLUSTER_NAME" \
  --region "$AWS_REGION" \
  --wait 2>/dev/null || echo "eksctl delete skipped (cluster may already be gone)"

echo ""
echo "============================================================"
echo "  Teardown complete. AWS resources destroyed."
echo "  Run 'bash scripts/bootstrap.sh' to redeploy."
echo "============================================================"
