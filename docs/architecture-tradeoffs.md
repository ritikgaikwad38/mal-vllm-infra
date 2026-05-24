# Architecture & Trade-offs Document
## Lead DevOps / SRE — Mal AI Infrastructure
**Author:** Ritik Gaikwad
**Date:** May 2026

---

## 1. Design Decisions

### EKS Node Group Configuration

I chose EKS Managed Node Groups over self-managed nodes or
Fargate for the following reasons:

**For assessment (CPU mode):**
- `t3.xlarge` instances (4 vCPU, 16GB RAM)
- 2 nodes desired, scales to 5
- Runs `facebook/opt-125m` in CPU/float32 mode
- Cost: ~$0.15/hour total

**For production (GPU mode):**
- `g4dn.xlarge` instances (NVIDIA T4 GPU, 16GB VRAM)
- Managed Node Groups preferred because AWS GPU AMIs
  ship with validated CUDA 12.x + drivers
- Reduces patching overhead vs self-managed
- For larger models (70B+): `p4d.24xlarge` with 8x A100s

**Why not Fargate:**
Fargate does not support GPU instance types at all.
Not viable for any LLM inference workload.

### vLLM Serving Settings

| Parameter | Assessment Value | Production Value | Reason |
|---|---|---|---|
| Model | facebook/opt-125m | Llama-3-8B or custom | Cost/availability |
| dtype | float32 | float16 | CPU vs GPU |
| max_model_len | 512 | 4096 | Memory constraint |
| tensor_parallel_size | 1 | 2-4 | Multi-GPU splitting |
| gpu_memory_utilization | N/A | 0.85 | Leave 15% headroom |
| max_num_seqs | 4 | 256 | Concurrent requests |

### Autoscaling Strategy

**Assessment:** Standard HPA on CPU utilization (70% threshold)

**Production:** KEDA with Prometheus scaler on
`vllm_num_requests_waiting` metric because:
- CPU is a poor proxy for LLM inference load
- A pod can be CPU-idle while GPU is saturated
- Queue depth directly reflects user-felt latency
- KEDA scales to zero during off-peak hours saving cost

### Trade-offs Made

**Chose simplicity over perfection:**
- Single NAT gateway per AZ (not per subnet) — saves ~$100/month
- No service mesh (Istio) — adds complexity without clear benefit
  at this scale
- CPU mode for assessment — honest about GPU gap, documented
  all differences clearly

---

## 2. GPU Cluster Management at Scale (10-50 Nodes)

### Node Lifecycle Management

**Provisioning:**
- Terraform manages node group configuration as code
- `lifecycle { prevent_destroy = true }` on all GPU node groups
- IAM SCP denies `eks:DeleteNodegroup` except break-glass role
- New nodes automatically get NVIDIA device plugin via DaemonSet

**Day-2 Operations:**
- AWS managed AMI updates handle CUDA/driver patching
- Node drain automation via Lambda + EventBridge on maintenance
  windows (2-4 AM UAE time)
- `PodDisruptionBudgets` ensure minimum 1 replica always running
  during node replacements

**GPU Health Monitoring:**
- Node Problem Detector DaemonSet surfaces XID errors as
  Kubernetes node conditions
- Self Node Remediation operator auto-cordons + drains + replaces
  unhealthy GPU nodes
- CloudWatch alarms on `nvidia_smi_memory_used` metric

### Spot Instance Strategy

For non-critical batch inference workloads:
- Use `g4dn` Spot instances (up to 70% cheaper)
- Spot interruption handler DaemonSet gracefully drains pods
- Always maintain minimum 2 On-Demand GPU nodes for
  real-time banking chat (SLO-critical)
- Never use Spot for the primary chat inference path

### Multi-AZ Distribution
me-south-1a → GPU node group (On-Demand, primary)
me-south-1b → GPU node group (On-Demand, failover)
me-south-1c → CPU node group (Spot, batch only)

- `topologySpreadConstraints` enforces pod distribution across AZs
- Cluster Autoscaler configured with
  `balance-similar-node-groups: true`
- Target 70% GPU memory utilization before scaling out

---

## 3. What I Cut & What Comes Next

### Cut Due to Time Constraints

| What | Why Cut | Production Priority |
|---|---|---|
| Real GPU nodes | Cost — g4dn.xlarge = $0.50/hr | Day 1 |
| Istio service mesh | Complexity vs benefit tradeoff | Month 2 |
| Multi-region DR | me-south-1 single region for now | Month 3 |
| Custom model fine-tuning | Out of scope for infra assessment | Quarter 2 |
| OPA/Kyverno policies | Time constraint | Week 2 |
| Redis session store | Not needed for stateless inference | Week 1 |

### What I Would Add First in Production

**Week 1 (Critical):**
1. Switch to real GPU nodes (`g4dn.xlarge`)
2. Deploy KEDA replacing HPA
3. Add Redis for WebSocket session state
4. OPA/Kyverno policies blocking non-compliant images
5. AWS Secrets Manager integration for all secrets

**Week 2 (Important):**
1. Implement blue/green deployment for zero-downtime
   model updates
2. Add distributed tracing with OpenTelemetry
3. Configure SNS alerts to Slack for on-call
4. Implement `preStop` lifecycle hook for graceful
   WebSocket draining

**Month 2 (Scale):**
1. Istio service mesh for mTLS between services
2. Multi-model serving with vLLM model routing
3. Custom Grafana SLO dashboard with error budget tracking
4. Automated chaos engineering with LitmusChaos

---

## 4. Data Residency & Compliance (UAE CBUAE)

### Data Residency Enforcement

Mal operates under UAE Central Bank (CBUAE) regulations
requiring all customer financial data to remain within UAE.

**Technical controls implemented:**

**Layer 1 — Terraform validation:**
```hcl
variable "aws_region" {
  validation {
    condition     = var.aws_region == "me-south-1"
    error_message = "Must use me-south-1 for CBUAE compliance."
  }
}
```
Terraform will refuse to deploy to any other region.

**Layer 2 — S3 bucket policy:**
```json
{
  "Condition": {
    "StringNotEquals": {
      "aws:RequestedRegion": "me-south-1"
    }
  },
  "Effect": "Deny"
}
```
All S3 API calls rejected if not targeting UAE region.

**Layer 3 — IAM SCP at org level:**
Denies `s3:PutObject`, `eks:CreateCluster`,
`ecr:CreateRepository` outside `me-south-1` for all
accounts except break-glass role.

### Network Isolation

- All inference traffic on private subnets only
- Internal ALB — no public IP on inference endpoint
- VPC endpoints for S3, ECR, CloudWatch (traffic never
  leaves AWS backbone)
- WAF on ALB for OWASP Top 10 protection
- NACLs as second layer of subnet protection

### Audit Logging (5-year retention)

Per CBUAE requirements all audit logs retained 5 years:
- CloudTrail → S3 with Object Lock (Compliance mode)
- ALB access logs → S3 with Object Lock (Compliance mode)
- VPC Flow Logs → CloudWatch Logs (365 days) then
  archived to S3 Glacier
- Glacier tiering keeps cost low for long-term storage
- S3 Object Lock Compliance mode — cannot be deleted
  even by root account

### Secrets Management

- Zero plaintext secrets in code or environment variables
- All secrets in AWS Secrets Manager with automatic rotation
- Kubernetes Secrets encrypted at rest via KMS
- ECR images encrypted with customer-managed KMS key
- EKS etcd encrypted with KMS

---

## 5. 100x Scale — What Breaks & How to Fix It

### Current Design Limits

At current design, bottlenecks at 100x traffic:

**Bottleneck 1 — Single vLLM pod (breaks first)**
Current: 1 replica, 4 CPU cores
At 100x: Request queue grows unbounded, TTFT degrades
to 10s+, pods OOM killed

Fix:
- KEDA autoscaler already configured — scales to 10 pods
- But need GPU nodes — CPU inference too slow at scale
- Switch to `g4dn.xlarge` — 10x throughput per pod
- Increase `max_num_seqs` from 4 to 256

**Bottleneck 2 — NAT Gateway bandwidth**
Current: Single NAT per AZ
At 100x: Model download traffic saturates NAT (5 Gbps limit)

Fix:
- VPC endpoints for ECR and S3 (bypass NAT entirely)
- Pre-pull images on nodes via DaemonSet
- Already have ECR in same region — use VPC endpoint

**Bottleneck 3 — ALB connection limits**
Current: Single ALB
At 100x: WebSocket connections exhaust ALB limits

Fix:
- ALB scales automatically but needs pre-warming for
  sudden spikes
- Request AWS ALB pre-warming via support ticket
- Add connection draining timeout of 300s for WebSockets

**Bottleneck 4 — Cluster Autoscaler speed**
Current: Default CA settings, ~3 min to provision new node
At 100x sudden spike: 3 minutes of degraded service

Fix:
- Karpenter replaces Cluster Autoscaler (2x faster)
- Pre-provision warm pool of 2 stopped GPU instances
- AWS warm pools launch in 30s vs 3 min cold start

**Bottleneck 5 — Single region**
At 100x + region failure: Complete outage

Fix:
- Active-passive setup in nearest region
- Route53 health checks with automatic failover
- Model weights replicated to secondary region S3
- RTO target: 15 minutes

### 100x Architecture Changes Summary
Current:  1 CPU pod → HPA → t3.xlarge nodes
100x:     KEDA → 10-50 GPU pods → g4dn.xlarge nodes
+ Karpenter for fast scaling
+ Warm pool for instant capacity
+ Multi-AZ with topology spread
+ VPC endpoints to remove NAT bottleneck
---

## Appendix — Security Checklist

- [x] All data in me-south-1 only
- [x] KMS encryption for secrets, ECR, S3, EKS etcd
- [x] No plaintext secrets in code
- [x] Trivy scanning in CI/CD pipeline
- [x] IAM least privilege + IRSA
- [x] Internal ALB only (no public inference endpoint)
- [x] VPC Flow Logs enabled
- [x] Audit logs with 5-year retention + Object Lock
- [x] prevent_destroy on critical infrastructure
- [x] MFA required for AWS console access
- [x] WAF on ALB
- [x] Non-root container user