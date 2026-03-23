terraform {
  required_version = ">= 1.6"
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
  }

  # Once you create an S3 bucket for state, uncomment and fill this in:
  # backend "s3" {
  #   bucket = "your-tfstate-bucket"
  #   key    = "supply-demo/terraform.tfstate"
  #   region = "us-east-1"
  # }
}

provider "aws" {
  region = var.aws_region
}
