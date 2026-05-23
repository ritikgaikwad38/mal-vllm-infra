variable "aws_region" {
  description = "AWS region - UAE only for data residency compliance"
  type        = string
  default     = "me-south-1"

  validation {
    condition     = var.aws_region == "me-south-1"
    error_message = "Region must be me-south-1 (UAE) for CBUAE data residency compliance."
  }
}

variable "environment" {
  description = "Environment name"
  type        = string
  default     = "production"
}

variable "cluster_name" {
  description = "EKS cluster name"
  type        = string
  default     = "mal-vllm-cluster"
}

variable "cluster_version" {
  description = "Kubernetes version"
  type        = string
  default     = "1.29"
}

variable "vpc_cidr" {
  description = "VPC CIDR block"
  type        = string
  default     = "10.0.0.0/16"
}

variable "private_subnet_cidrs" {
  description = "Private subnet CIDRs across 3 AZs"
  type        = list(string)
  default     = ["10.0.1.0/24", "10.0.2.0/24", "10.0.3.0/24"]
}

variable "public_subnet_cidrs" {
  description = "Public subnet CIDRs across 3 AZs"
  type        = list(string)
  default     = ["10.0.101.0/24", "10.0.102.0/24", "10.0.103.0/24"]
}

variable "cpu_node_instance_type" {
  description = "CPU node instance type for vLLM in CPU mode"
  type        = string
  default     = "t3.xlarge"
}

variable "gpu_node_instance_type" {
  description = "GPU node instance type for production"
  type        = string
  default     = "g4dn.xlarge"
}

variable "cpu_node_desired" {
  description = "Desired CPU nodes"
  type        = number
  default     = 2
}

variable "cpu_node_min" {
  description = "Min CPU nodes"
  type        = number
  default     = 1
}

variable "cpu_node_max" {
  description = "Max CPU nodes"
  type        = number
  default     = 5
}