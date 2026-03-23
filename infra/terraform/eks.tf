# -------------------------------------------------------
# EKS Cluster
# -------------------------------------------------------
resource "aws_eks_cluster" "main" {
  name     = var.cluster_name
  version  = "1.35"
  role_arn = aws_iam_role.eks_cluster.arn

  # bootstrap_self_managed_addons is false in the live cluster (eksctl default).
  # Setting it here prevents a forces-replacement diff.
  bootstrap_self_managed_addons = false

  vpc_config {
    subnet_ids = [
      aws_subnet.public_1b.id,
      aws_subnet.public_1c.id,
      aws_subnet.private_1b.id,
      aws_subnet.private_1c.id,
    ]
    endpoint_public_access  = true
    endpoint_private_access = false
  }

  depends_on = [
    aws_iam_role_policy_attachment.eks_cluster_policy,
  ]

  lifecycle {
    ignore_changes = [
      tags,
      tags_all,
      access_config,
      kubernetes_network_config,
      upgrade_policy,
      vpc_config[0].security_group_ids,
    ]
  }
}

# -------------------------------------------------------
# EKS Node Group
# NOTE: eksctl placed nodes in public subnets, not private.
# Also uses a launch template we don't manage — ignored.
# -------------------------------------------------------
resource "aws_eks_node_group" "ng1" {
  cluster_name    = aws_eks_cluster.main.name
  node_group_name = "ng-1"
  node_role_arn   = aws_iam_role.eks_node.arn
  ami_type        = "AL2023_x86_64_STANDARD"
  instance_types  = ["t3.small"]

  # Real node group runs in public subnets (eksctl default for unmanaged placement)
  subnet_ids = [
    aws_subnet.public_1b.id,
    aws_subnet.public_1c.id,
  ]

  scaling_config {
    desired_size = 2
    min_size     = 1
    max_size     = 2
  }

  depends_on = [
    aws_iam_role_policy_attachment.eks_worker_node_policy,
    aws_iam_role_policy_attachment.eks_cni_policy,
    aws_iam_role_policy_attachment.eks_ecr_readonly,
  ]

  lifecycle {
    ignore_changes = [
      tags,
      tags_all,
      labels,
      launch_template,
      node_repair_config,
      update_config,
      release_version,
    ]
  }
}
