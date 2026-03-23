#!/usr/bin/env bash
# import.sh — Run this once to import existing AWS resources into Terraform state.
# After import, Terraform manages these resources and you never click in the console again.
#
# Prerequisites:
#   terraform init   (run this first)
#
# Usage:
#   chmod +x import.sh
#   ./import.sh

set -euo pipefail

echo "==> Importing VPC..."
terraform import aws_vpc.main vpc-02f6105bc654c3b1f

echo "==> Importing subnets..."
terraform import aws_subnet.public_1b  subnet-0c38319e2b7ca99c8
terraform import aws_subnet.public_1c  subnet-06bd62c586c229b2a
terraform import aws_subnet.private_1b subnet-0e0c8cba55ec3d623
terraform import aws_subnet.private_1c subnet-012789db20735bdda

echo "==> Importing security groups..."
terraform import aws_security_group.eks_cluster sg-0e595e7b5fb692083
terraform import aws_security_group.rds         sg-0ca7386e53bdc2596

echo "==> Importing IAM roles..."
terraform import aws_iam_role.eks_cluster eksctl-supply-demo-cluster-ServiceRole-A9V9o5Zm0OzB
terraform import aws_iam_role.eks_node    eksctl-supply-demo-nodegroup-ng-1-NodeInstanceRole-pasS6N50TIGe

echo "==> Importing IAM role policy attachments..."
terraform import aws_iam_role_policy_attachment.eks_cluster_policy \
  eksctl-supply-demo-cluster-ServiceRole-A9V9o5Zm0OzB/arn:aws:iam::aws:policy/AmazonEKSClusterPolicy

terraform import aws_iam_role_policy_attachment.eks_worker_node_policy \
  eksctl-supply-demo-nodegroup-ng-1-NodeInstanceRole-pasS6N50TIGe/arn:aws:iam::aws:policy/AmazonEKSWorkerNodePolicy

terraform import aws_iam_role_policy_attachment.eks_cni_policy \
  eksctl-supply-demo-nodegroup-ng-1-NodeInstanceRole-pasS6N50TIGe/arn:aws:iam::aws:policy/AmazonEKS_CNI_Policy

terraform import aws_iam_role_policy_attachment.eks_ecr_readonly \
  eksctl-supply-demo-nodegroup-ng-1-NodeInstanceRole-pasS6N50TIGe/arn:aws:iam::aws:policy/AmazonEC2ContainerRegistryReadOnly

echo "==> Importing EKS cluster..."
terraform import aws_eks_cluster.main supply-demo

echo "==> Importing EKS node group..."
terraform import aws_eks_node_group.ng1 supply-demo:ng-1

echo "==> Importing RDS subnet group..."
terraform import aws_db_subnet_group.main default-vpc-02f6105bc654c3b1f

echo "==> Importing RDS instance..."
terraform import aws_db_instance.main supply-demo-db

echo "==> Importing ECR repositories..."
terraform import aws_ecr_repository.supply_api    supply-api
terraform import aws_ecr_repository.supply_worker supply-worker

echo ""
echo "==> All imports complete. Running plan to check for drift..."
terraform plan
