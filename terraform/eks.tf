# ── VPC ──────────────────────────────────────────────────────────────
module "vpc" {
  source  = "terraform-aws-modules/vpc/aws"
  version = "~> 5.0"

  name = "${var.cluster_name}-vpc"
  cidr = var.vpc_cidr

  azs             = ["${var.aws_region}a", "${var.aws_region}b", "${var.aws_region}c"]
  private_subnets = var.private_subnet_cidrs
  public_subnets  = var.public_subnet_cidrs

  enable_nat_gateway     = true
  single_nat_gateway     = false
  one_nat_gateway_per_az = true

  enable_dns_hostnames = true
  enable_dns_support   = true

  # VPC Flow Logs for CBUAE audit compliance
  enable_flow_log                      = true
  create_flow_log_cloudwatch_log_group = true
  create_flow_log_cloudwatch_iam_role  = true
  flow_log_max_aggregation_interval    = 60

  public_subnet_tags = {
    "kubernetes.io/role/elb" = 1
  }

  private_subnet_tags = {
    "kubernetes.io/role/internal-elb" = 1
  }
}

# ── EKS CLUSTER ──────────────────────────────────────────────────────
module "eks" {
  source  = "terraform-aws-modules/eks/aws"
  version = "~> 20.0"

  cluster_name    = var.cluster_name
  cluster_version = var.cluster_version

  vpc_id                         = module.vpc.vpc_id
  subnet_ids                     = module.vpc.private_subnets
  cluster_endpoint_public_access = true

  # Encryption at rest for all secrets
  cluster_encryption_config = {
    provider_key_arn = aws_kms_key.eks.arn
    resources        = ["secrets"]
  }

  # Enable IRSA for pod-level IAM
  enable_irsa = true

  cluster_addons = {
    coredns = {
      most_recent = true
    }
    kube-proxy = {
      most_recent = true
    }
    vpc-cni = {
      most_recent = true
    }
    aws-ebs-csi-driver = {
      most_recent = true
    }
  }

  eks_managed_node_groups = {

    # CPU node group - used for assessment (cost-free tier)
    cpu_nodes = {
      name           = "cpu-node-group"
      instance_types = [var.cpu_node_instance_type]

      min_size     = var.cpu_node_min
      max_size     = var.cpu_node_max
      desired_size = var.cpu_node_desired

      disk_size = 50

      labels = {
        role    = "vllm-cpu"
        node-type = "cpu"
      }

      taints = []
    }

    # GPU node group - for production use
    # NOTE: Commented out for assessment to save cost
    # Uncomment for real GPU inference
    # gpu_nodes = {
    #   name           = "gpu-node-group"
    #   instance_types = [var.gpu_node_instance_type]
    #   ami_type       = "AL2_x86_64_GPU"
    #
    #   min_size     = 1
    #   max_size     = 10
    #   desired_size = 1
    #
    #   disk_size = 100
    #
    #   labels = {
    #     role              = "vllm-gpu"
    #     node-type         = "gpu"
    #     "nvidia.com/gpu"  = "true"
    #   }
    #
    #   taints = [{
    #     key    = "nvidia.com/gpu"
    #     value  = "true"
    #     effect = "NO_SCHEDULE"
    #   }]
    # }
  }
}

# ── KMS KEY for encryption ────────────────────────────────────────────
resource "aws_kms_key" "eks" {
  description             = "EKS cluster encryption key - CBUAE compliance"
  deletion_window_in_days = 7
  enable_key_rotation     = true

  tags = {
    Name = "${var.cluster_name}-kms"
  }
}

resource "aws_kms_alias" "eks" {
  name          = "alias/${var.cluster_name}"
  target_key_id = aws_kms_key.eks.key_id
}

# ── ECR REPOSITORY ────────────────────────────────────────────────────
resource "aws_ecr_repository" "vllm" {
  name                 = "mal-vllm"
  image_tag_mutability = "IMMUTABLE"

  image_scanning_configuration {
    scan_on_push = true
  }

  encryption_configuration {
    encryption_type = "KMS"
    kms_key         = aws_kms_key.eks.arn
  }
}

# ECR lifecycle policy - keep last 10 images only
resource "aws_ecr_lifecycle_policy" "vllm" {
  repository = aws_ecr_repository.vllm.name

  policy = jsonencode({
    rules = [{
      rulePriority = 1
      description  = "Keep last 10 images"
      selection = {
        tagStatus   = "any"
        countType   = "imageCountMoreThan"
        countNumber = 10
      }
      action = {
        type = "expire"
      }
    }]
  })
}

# ── S3 BUCKET for Terraform state ─────────────────────────────────────
resource "aws_s3_bucket" "terraform_state" {
  bucket = "mal-vllm-terraform-state"

  lifecycle {
    prevent_destroy = true
  }
}

resource "aws_s3_bucket_versioning" "terraform_state" {
  bucket = aws_s3_bucket.terraform_state.id
  versioning_configuration {
    status = "Enabled"
  }
}

resource "aws_s3_bucket_server_side_encryption_configuration" "terraform_state" {
  bucket = aws_s3_bucket.terraform_state.id
  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm     = "aws:kms"
      kms_master_key_id = aws_kms_key.eks.arn
    }
  }
}

resource "aws_s3_bucket_public_access_block" "terraform_state" {
  bucket                  = aws_s3_bucket.terraform_state.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

# ── DYNAMODB for state locking ─────────────────────────────────────────
resource "aws_dynamodb_table" "terraform_lock" {
  name         = "mal-vllm-tf-lock"
  billing_mode = "PAY_PER_REQUEST"
  hash_key     = "LockID"

  attribute {
    name = "LockID"
    type = "S"
  }
}