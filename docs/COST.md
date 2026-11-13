# Cost Analysis

What running this sample actually costs, where the money goes, and the levers that control it.

> This is a sample/reference deliverable. The software in this repo — Kueue, the labeling scripts, and the manifests — is open source and carries **no license cost**. Essentially all spend comes from the AWS infrastructure you run it on, dominated by GPU compute.

> This is the **EC2-API path** (no NVIDIA Topograph controller). Topology labels come from the EC2 `DescribeInstanceTopology` API via the cloud-provider or the labeling script, so there is no extra in-cluster controller to run, and the `DescribeInstanceTopology` calls themselves are not a meaningful cost.

## Rate assumptions

The totals below use these **illustrative US East (N. Virginia) On-Demand rates**. Prices vary by Region and change over time — **verify current pricing** in the [AWS Pricing Calculator](https://calculator.aws/) and the [EC2 pricing page](https://aws.amazon.com/ec2/pricing/) before quoting any number.

| Item | Illustrative rate |
|---|---|
| `g5.2xlarge` (1× A10G) | ~$1.21 / hr |
| `p4d.24xlarge` (8× A100) | ~$21.96 / hr |
| `p5.48xlarge` (8× H100) | ~$55.04 / hr |
| `m5.large` (management/system node, no GPU) | ~$0.096 / hr |
| EKS control plane | $0.10 / hr per cluster (~$73 / mo) |
| EBS gp3 storage | $0.08 / GB-month |

"hr/mo" below: **160** = 8 h/day × 20 working days (part-time); **730** = 24×7.

## Where the cost goes (per service)

| Service | Cost driver | Share of bill |
|---|---|---|
| **EC2 GPU instances** | rate × node count × hours | Dominant (usually >90% at pilot/production scale) |
| **EKS control plane** | $0.10/hr × number of clusters | Small, fixed |
| **EBS** | gp3 GB-month per node | Small |
| **Data transfer** | cross-AZ / egress | Workload-dependent |
| **EFA** | included with supported instances | None |
| **`DescribeInstanceTopology` calls + Kueue** | standard EC2 describe calls; OSS controller on an existing node | Negligible |

## Estimated monthly cost by scale

### Demo — single cluster, TAS only, part-time (functional validation)

| Line item | Calc | Monthly |
|---|---|---|
| 2× g5.2xlarge GPU | 2 × $1.21 × 160 | ~$387 |
| 1 EKS control plane | $73 | ~$73 |
| 1× m5.large system node | $0.096 × 160 | ~$15 |
| EBS (~200 GB gp3) | 200 × $0.08 | ~$16 |
| **Aggregated total** | | **≈ $490 / month** |

At this scale the fixed overhead (control plane + system node) is a meaningful fraction because the GPUs are small and part-time. Delete the cluster when the demo is done to stop the control-plane charge.

### Pilot — MultiKueue, 3 clusters, business hours (4 GPU nodes)

| Line item | Calc | Monthly |
|---|---|---|
| 4× p4d.24xlarge GPU | 4 × $21.96 × 160 | ~$14,054 |
| 3 EKS control planes (1 mgmt + 2 workers) | 3 × $73 | ~$219 |
| 1× m5.large management node | $0.096 × 730 | ~$70 |
| EBS (~500 GB gp3) | 500 × $0.08 | ~$40 |
| **Aggregated total** | | **≈ $14,400 / month** |

GPU compute is ~98% of the bill — everything else is rounding error at this point.

### Production — MultiKueue, 3 clusters, 24×7 (8× p5.48xlarge)

| Line item | Calc | Monthly |
|---|---|---|
| 8× p5.48xlarge GPU | 8 × $55.04 × 730 | ~$321,434 |
| 3 EKS control planes | 3 × $73 | ~$219 |
| 1× m5.large management node | $0.096 × 730 | ~$70 |
| EBS (~1,800 GB gp3) | 1,800 × $0.08 | ~$144 |
| **Aggregated total (On-Demand)** | | **≈ $322,000 / month** |

This is the On-Demand figure. Discounting the GPU term is by far the biggest lever: at a representative p5 **Spot** rate (~$21.5/hr) the GPU line drops to ~$126,000/month, and 1-year Savings Plans / Reserved or Capacity Blocks give similar committed-use discounts.

## Purchase options (biggest lever on the GPU term)

- **On-Demand** — most flexible, highest per-hour rate (used for the totals above).
- **Spot** — large discount for interruption-tolerant work; pairs well with Kueue requeuing.
- **Savings Plans / Reserved** — discount for steady-state, long-running fleets.
- **Capacity Blocks / On-Demand Capacity Reservations** — reserve scarce GPU capacity for a window; billed whether or not fully used.

## Cost controls built into this stack

- **Kueue quotas cap spend.** `nominalQuota` on each ClusterQueue is a hard ceiling on admitted work — jobs queue instead of launching GPU nodes beyond the quota, so a misconfigured job cannot run away with capacity.
- **Right-size per-worker quotas** in `multikueue/worker-cluster.yaml` (applied per worker with that worker's own capacity) and the logical fleet total in `multikueue/management-cluster.yaml`.
- **Tear down when idle.** GPU nodes bill while running regardless of utilization. Scale worker node groups to zero (or delete them) between runs; delete idle EKS clusters to stop their control-plane charge.
- **Topology-aware packing** keeps collective traffic intra-rack/intra-AZ, which both shortens jobs (fewer node-hours) and avoids cross-AZ data-transfer charges.

## References

- [AWS Pricing Calculator](https://calculator.aws/)
- [Amazon EC2 pricing](https://aws.amazon.com/ec2/pricing/)
- [Amazon EKS pricing](https://aws.amazon.com/eks/pricing/)
- [Amazon EBS pricing](https://aws.amazon.com/ebs/pricing/)
