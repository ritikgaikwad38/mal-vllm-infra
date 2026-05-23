# mal-vllm-infra

Production-grade vLLM inference service on AWS EKS for Mal —
AI-native Islamic digital bank.

## Architecture Overview

- **EKS** — Kubernetes cluster in AWS me-south-1 (UAE)
- **vLLM** — OpenAI-compatible inference server
- **Model** — facebook/opt-125m (CPU mode for assessment)
- **IaC** — Terraform with S3 backend + DynamoDB locking
- **CI/CD** — GitHub Actions with Trivy security scanning
- **Observability** — Prometheus + Grafana
- **Compliance** — CBUAE data residency enforced (me-south-1 only)

## Repository Structure
mal-vllm-infra/
├── terraform/       # EKS cluster, VPC, ECR, KMS
├── k8s/             # Kubernetes manifests
├── docker/          # vLLM Dockerfile
├── .github/         # CI/CD pipeline
└── monitoring/      # Prometheus + Grafana configs

## CPU vs GPU Mode

This assessment runs in **CPU mode** using `facebook/opt-125m`.

For production GPU deployment:
- Use `g4dn.xlarge` instance type
- Change `DTYPE` to `float16`
- Uncomment GPU node group in `terraform/eks.tf`
- Add `nvidia.com/gpu: "1"` resource limit
- Deploy NVIDIA device plugin DaemonSet
- Switch HPA to KEDA with queue depth metric

## Security Controls

- All data stays in `me-south-1` (UAE) — CBUAE compliant
- KMS encryption for EKS secrets + ECR + S3
- Trivy image scanning in CI/CD pipeline
- No plaintext secrets — AWS Secrets Manager only
- VPC Flow Logs enabled for audit trail
- Internal ALB only — no public inference endpoint
- IAM least privilege with IRSA

## Quick Start

```bash
# 1. Configure AWS CLI
aws configure

# 2. Deploy infrastructure
cd terraform
terraform init
terraform plan
terraform apply

# 3. Configure kubectl
aws eks update-kubeconfig --region me-south-1 --name mal-vllm-cluster

# 4. Deploy vLLM
kubectl apply -f k8s/

# 5. Test endpoint
curl http://LOAD_BALANCER_URL/v1/completions \
  -H "Content-Type: application/json" \
  -d '{"model": "facebook/opt-125m", "prompt": "Hello", "max_tokens": 10}'
```

## Monitoring

- Prometheus scrapes vLLM `/metrics` endpoint
- Grafana dashboard tracks TTFT + GPU/CPU memory
- Alerts configured for queue depth and latency SLOs