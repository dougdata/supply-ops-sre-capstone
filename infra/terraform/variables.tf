variable "aws_region" {
  description = "AWS region"
  type        = string
  default     = "us-east-1"
}

variable "account_id" {
  description = "AWS account ID"
  type        = string
  default     = "376218549913"
}

variable "cluster_name" {
  description = "EKS cluster name"
  type        = string
  default     = "supply-demo"
}

variable "db_identifier" {
  description = "RDS instance identifier"
  type        = string
  default     = "supply-demo-db"
}
