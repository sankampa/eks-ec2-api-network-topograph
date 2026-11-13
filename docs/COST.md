# Cost Analysis

What running this sample actually costs, where the money goes, and the levers that control it.

> This is a sample/reference deliverable. The software in this repo — Kueue, the labeling scripts, and the manifests — is open source and carries **no license cost**. Essentially all spend comes from the AWS infrastructure you run it on, and that is dominated by GPU compute. Prices vary by Region, instance type, and purchase option and change over time, so treat the figures below as directional and confirm current pricing with the [AWS Pricing Calculator](https://calculator.aws/) and the [EC2 pricing page](https://aws.amazon.com/ec2/pricing/).

> Note: this is the **EC2-API path** (no NVIDIA Topograph controller). Topology labels come from the EC2 `DescribeInstanceTopology` API via the cloud-provider or a labeling script, so there is no extra in-cluster controller to run — the footprint is even smaller than the Topograph variant, and the `DescribeInstanceTopology` calls themselves are not a meaningful cost.

## Where the cost goes (per service)

| Service | Cost driver | Relative magnitude |
|---|---|---|
| **Amazon EC2 — GPU instances** (p5, p5en, p4d, p3dn, etc.) | Per-instance-hour × number of GPU nodes × hours running. This is the overwhelming majority of the bill. | Dominant |
| **Amazon EKS control plane** | Flat per-cluster-hour, per cluster. A 1-management + 2-worker setup is 3 clusters. | Small, fixed |
| **Amazon EBS** | gp3 volumes attached to each node (root + any data volumes). | Small |
| **Data transfer** | Cross-AZ and internet egress; intra-AZ traffic between co-located pods is the cheapest, which is part of why topology-aware packing helps. | Workload-dependent |
| **Elastic Fabric Adapter (EFA)** | No separate per-hour charge; it is a network interface feature of supported instances. | None (included) |
| **`ec2:DescribeInstanceTopology` API calls** | Standard EC2 describe calls from the labeling script / cloud-provider. | Negligible |
| **Kueue** | Open-source controller; consumes only the small CPU/memory of its pod on an existing node. | Negligible |

The practical takeaway: **GPU node-hours set the bill.** The scheduling stack here does not add meaningful cost — its value is helping you use the GPU capacity you are already paying for more efficiently.

## Illustrative estimate

The dominant term is simply:

```
monthly GPU cost ≈ (GPU instance hourly rate) × (number of GPU nodes) × (hours running per month)
```

Worked example (**illustrative only — substitute the current rate for your instance type and Region**):

- Assume a GPU rate of `$R`/hour (look up `R` for, e.g., `p5.48xlarge` On-Demand in your Region).
- 2 worker nodes run 8 hours/day for 20 working days = 320 node-hours/month.
- GPU compute ≈ `R × 320`.
- Add 3 × EKS control-plane hours for the month and a few dollars of EBS; both are rounding error next to the GPU term.

Run the same shape in the [AWS Pricing Calculator](https://calculator.aws/) with your real instance type, Region, and hours for a committed number.

## Purchase options (biggest lever on the GPU term)

- **On-Demand** — most flexible, highest per-hour rate.
- **Spot** — large discount for interruption-tolerant work; pairs well with Kueue requeuing.
- **Savings Plans / Reserved** — discount for steady-state, long-running fleets.
- **Capacity Blocks / On-Demand Capacity Reservations** — reserve scarce GPU capacity for a window; you pay for the reservation whether or not it is fully used.

## Cost controls built into this stack

- **Kueue quotas cap spend.** `nominalQuota` on each ClusterQueue is a hard ceiling on admitted work — jobs queue instead of launching more GPU nodes beyond the quota, so a misconfigured job cannot run away with capacity.
- **Right-size per-worker quotas** in `multikueue/worker-cluster.yaml` (applied per worker with that worker's own capacity) and the logical fleet total in `multikueue/management-cluster.yaml`.
- **Tear down when idle.** GPU nodes bill while running regardless of utilization. Scale worker node groups to zero (or delete them) between runs; delete idle EKS clusters to stop their control-plane charge.
- **Topology-aware packing** keeps collective traffic intra-rack/intra-AZ, which both speeds jobs (shorter node-hours) and avoids cross-AZ data-transfer charges.

## References

- [AWS Pricing Calculator](https://calculator.aws/)
- [Amazon EC2 pricing](https://aws.amazon.com/ec2/pricing/)
- [Amazon EKS pricing](https://aws.amazon.com/eks/pricing/)
- [Amazon EBS pricing](https://aws.amazon.com/ebs/pricing/)
