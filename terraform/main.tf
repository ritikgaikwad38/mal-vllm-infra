terraform {
  required_version = ">= 1.3.0"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
  }

  backend "s3" {
    bucket         = "mal-vllm-terraform-state"
    key            = "eks/terraform.tfstate"
    region         = "me-south-1"
    dynamodb_table = "mal-vllm-tf-lock"
    encrypt        = true
  }
}

provider "aws" {
  region = var.aws_region

  default_tags {
    tags = {
      Project     = "mal-vllm-infra"
      Environment = var.environment
      ManagedBy   = "terraform"
      DataClass   = "confidential"
      Region      = "UAE"
    }
  }
}