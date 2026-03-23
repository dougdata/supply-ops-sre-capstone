# -------------------------------------------------------
# VPC
# NOTE: eksctl adds many tags we don't manage — ignore_changes prevents drift noise.
# -------------------------------------------------------
resource "aws_vpc" "main" {
  cidr_block           = "192.168.0.0/16"
  enable_dns_hostnames = true
  enable_dns_support   = true

  tags = {
    Name = "eksctl-supply-demo-cluster/VPC"
  }

  lifecycle {
    ignore_changes = [tags, tags_all]
  }
}

# -------------------------------------------------------
# Subnets
# -------------------------------------------------------
resource "aws_subnet" "public_1b" {
  vpc_id                  = aws_vpc.main.id
  cidr_block              = "192.168.0.0/19"
  availability_zone       = "us-east-1b"
  map_public_ip_on_launch = true

  tags = {
    Name = "eksctl-supply-demo-cluster/SubnetPublicUSEAST1B"
  }

  lifecycle {
    ignore_changes = [tags, tags_all]
  }
}

resource "aws_subnet" "public_1c" {
  vpc_id                  = aws_vpc.main.id
  cidr_block              = "192.168.32.0/19"
  availability_zone       = "us-east-1c"
  map_public_ip_on_launch = true

  tags = {
    Name = "eksctl-supply-demo-cluster/SubnetPublicUSEAST1C"
  }

  lifecycle {
    ignore_changes = [tags, tags_all]
  }
}

resource "aws_subnet" "private_1b" {
  vpc_id                  = aws_vpc.main.id
  cidr_block              = "192.168.64.0/19"
  availability_zone       = "us-east-1b"
  map_public_ip_on_launch = false

  tags = {
    Name                              = "eksctl-supply-demo-cluster/SubnetPrivateUSEAST1B"
    "kubernetes.io/role/internal-elb" = "1"
  }

  lifecycle {
    ignore_changes = [tags, tags_all]
  }
}

resource "aws_subnet" "private_1c" {
  vpc_id                  = aws_vpc.main.id
  cidr_block              = "192.168.96.0/19"
  availability_zone       = "us-east-1c"
  map_public_ip_on_launch = false

  tags = {
    Name                              = "eksctl-supply-demo-cluster/SubnetPrivateUSEAST1C"
    "kubernetes.io/role/internal-elb" = "1"
  }

  lifecycle {
    ignore_changes = [tags, tags_all]
  }
}

# -------------------------------------------------------
# Security Groups
# IMPORTANT: `description` is immutable in AWS — changing it forces destroy/recreate.
# We match the EXACT real values here and ignore ingress/egress/tags
# so Terraform never tries to recreate these live security groups.
# -------------------------------------------------------
resource "aws_security_group" "eks_cluster" {
  name        = "eks-cluster-sg-supply-demo-83512319"
  description = "EKS created security group applied to ENI that is attached to EKS Control Plane master nodes, as well as any managed workloads."
  vpc_id      = aws_vpc.main.id

  tags = {
    Name                                = "eks-cluster-sg-supply-demo-83512319"
    "kubernetes.io/cluster/supply-demo" = "owned"
  }

  lifecycle {
    ignore_changes = [ingress, egress, tags, tags_all]
  }
}

resource "aws_security_group" "rds" {
  name        = "default"
  description = "default VPC security group"
  vpc_id      = aws_vpc.main.id

  tags = {}

  lifecycle {
    ignore_changes = [ingress, egress, tags, tags_all]
  }
}
