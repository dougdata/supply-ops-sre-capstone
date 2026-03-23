output "cluster_name" {
  description = "EKS cluster name"
  value       = aws_eks_cluster.main.name
}

output "cluster_endpoint" {
  description = "EKS cluster API endpoint"
  value       = aws_eks_cluster.main.endpoint
}

output "cluster_version" {
  description = "EKS Kubernetes version"
  value       = aws_eks_cluster.main.version
}

output "vpc_id" {
  description = "VPC ID"
  value       = aws_vpc.main.id
}

output "private_subnet_ids" {
  description = "Private subnet IDs"
  value       = [aws_subnet.private_1b.id, aws_subnet.private_1c.id]
}

output "rds_endpoint" {
  description = "RDS instance endpoint"
  value       = aws_db_instance.main.endpoint
  sensitive   = true
}

output "ecr_supply_api_uri" {
  description = "ECR URI for supply-api"
  value       = aws_ecr_repository.supply_api.repository_url
}

output "ecr_supply_worker_uri" {
  description = "ECR URI for supply-worker"
  value       = aws_ecr_repository.supply_worker.repository_url
}
