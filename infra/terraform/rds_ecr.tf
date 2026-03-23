# -------------------------------------------------------
# RDS Subnet Group
# -------------------------------------------------------
resource "aws_db_subnet_group" "main" {
  name        = "default-vpc-02f6105bc654c3b1f"
  description = "Created from the RDS Management Console"
  subnet_ids  = [
    aws_subnet.private_1b.id,
    aws_subnet.private_1c.id,
  ]

  lifecycle {
    ignore_changes = [description, subnet_ids, tags, tags_all]
  }
}

# -------------------------------------------------------
# RDS Instance
# NOTE: Many attributes are managed outside Terraform (monitoring, KMS,
# performance insights, autoscaling). We ignore them to prevent replacement.
# -------------------------------------------------------
resource "aws_db_instance" "main" {
  identifier        = var.db_identifier
  engine            = "postgres"
  engine_version    = "17.6"
  instance_class    = "db.t3.micro"
  allocated_storage = 20
  storage_type      = "gp2"
  storage_encrypted = true

  username             = "supplyadmin"
  password             = "CHANGE_ME_BEFORE_APPLY"
  db_subnet_group_name = aws_db_subnet_group.main.name
  skip_final_snapshot  = true
  publicly_accessible  = false

  lifecycle {
    ignore_changes = [
      password,
      db_name,
      vpc_security_group_ids,
      tags,
      tags_all,
      monitoring_interval,
      monitoring_role_arn,
      performance_insights_enabled,
      performance_insights_kms_key_id,
      performance_insights_retention_period,
      backup_retention_period,
      backup_window,
      maintenance_window,
      copy_tags_to_snapshot,
      max_allocated_storage,
      kms_key_id,
    ]
  }
}

# -------------------------------------------------------
# ECR Repositories
# -------------------------------------------------------
resource "aws_ecr_repository" "supply_api" {
  name                 = "supply-api"
  image_tag_mutability = "MUTABLE"

  image_scanning_configuration {
    scan_on_push = true
  }

  lifecycle {
    ignore_changes = [tags, tags_all]
  }
}

resource "aws_ecr_repository" "supply_worker" {
  name                 = "supply-worker"
  image_tag_mutability = "MUTABLE"

  image_scanning_configuration {
    scan_on_push = true
  }

  lifecycle {
    ignore_changes = [tags, tags_all]
  }
}
