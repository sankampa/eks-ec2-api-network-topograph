# EKS Topology-Aware Scheduling via EC2 API + Kueue TAS + MultiKueue

Topology-aware GPU scheduling on Amazon EKS using the native **EC2 `DescribeInstanceTopology` API** (no NVIDIA Topograph), **Kueue Topology-Aware Scheduling (TAS)** for rack-local placement, and **MultiKueue** for multi-cluster job dispatch.

---

## How It Works

1. **EC2 API provides the topology** — `DescribeInstanceTopology` returns a hierarchical network-node tree for each instance (AZ fabric → spine → rack)
2. **EKS writes labels natively** — the cloud-provider writes `topology.k8s.aws/network-node-layer-{1,2,3}` at node registration (or use the labeling script as backfill)
3. **Kueue TAS reads the labels** — packs job pods onto the tightest network domain
4. **MultiKueue dispatches whole jobs** — never splits a job across clusters

No NVIDIA Topograph controller needed. Same data, same labels, zero deploy footprint.

---

## Repo Structure

```
├── README.md
├── docs/
│   ├── GUIDANCE.md                            ← Full guidance doc (how topology works, IAM, gotchas)
│   └── COST.md                                ← Cost drivers, per-service breakdown, cost controls
├── scripts/
│   ├── label-nodes-from-ec2-topology.sh       ← Labeling script (Bash 4+, the Topograph replacement)
│   ├── label-nodes-from-ec2-topology-macos.sh ← macOS-compatible version (Bash 3.2)
│   ├── create-multikueue-kubeconfig.sh        ← Generates static-token kubeconfig for workers
│   └── iam-policy.json                        ← IAM policy for ec2:DescribeInstanceTopology
├── kueue-tas/
│   ├── topology-and-queue.yaml                ← Topology + ResourceFlavor + ClusterQueue + LocalQueue
│   └── sample-tas-job.yaml                    ← Sample job with TAS annotation
└── multikueue/
    ├── INSTRUCTIONS.md                        ← Step-by-step MultiKueue setup
    ├── management-cluster.yaml                ← Management cluster MultiKueue objects
    ├── worker-cluster.yaml                    ← Worker cluster template (apply per worker w/ its quota)
    ├── sample-multicluster-job.yaml           ← Sample dispatch job with TAS annotation
    ├── smoke-test-no-tas.yaml                 ← Basic smoke test (no TAS, proves dispatch)
    └── crd-stubs/                             ← CRD stubs Kueue v0.19 requires on workers
        ├── all-missing-crds.yaml              ← LeaderWorkerSet, PyTorchJob, TFJob, etc.
        ├── mpijob-crd.yaml                    ← MPIJob stub
        └── trainjob-crd.yaml                  ← TrainJob stub
```

---

## Prerequisites

Have these in place before step 1:

- **Tooling:** AWS CLI v2, `kubectl`, and `python3` (the labeling scripts use all three). The default labeling script needs **Bash 4+**; on macOS (Bash 3.2) use `label-nodes-from-ec2-topology-macos.sh`.
- **Cluster:** an existing EKS cluster (one management + one or more workers for the MultiKueue steps) with **GPU nodes**, on a supported instance type (see *Supported Instance Types* below).
- **Access:** `kubectl` cluster-admin on each cluster, and AWS credentials with **`ec2:DescribeInstanceTopology`** (see `scripts/iam-policy.json`).
- **Kueue v0.19.0** installed on every cluster (the Quick Start installs it).

---

## Quick Start

### 1. Check if topology labels exist

```bash
kubectl get nodes -L \
  topology.k8s.aws/network-node-layer-1,\
  topology.k8s.aws/network-node-layer-2,\
  topology.k8s.aws/network-node-layer-3
```

- **Columns populated** → skip to step 3
- **Columns empty** → continue to step 2

### 2. Label nodes via the EC2 API

```bash
# Attach the IAM policy to the EKS cluster role (or your CLI identity)
# AmazonEKSClusterPolicy already includes it — check first.

# Run the labeling script
export AWS_REGION=<your-region>
./scripts/label-nodes-from-ec2-topology.sh            # dry run
APPLY=1 ./scripts/label-nodes-from-ec2-topology.sh    # apply
```

On macOS (Bash 3.2):
```bash
./scripts/label-nodes-from-ec2-topology-macos.sh
```

### 3. Set up Kueue TAS (single-cluster)

```bash
# Install Kueue
kubectl apply --server-side -f \
  https://github.com/kubernetes-sigs/kueue/releases/download/v0.19.0/manifests.yaml

# Create namespace + apply TAS objects (edit placeholders first)
kubectl create ns <YOUR_NAMESPACE>
kubectl apply -f kueue-tas/topology-and-queue.yaml
kubectl apply -f kueue-tas/sample-tas-job.yaml
```

### 4. Set up MultiKueue (multi-cluster)

Follow [`multikueue/INSTRUCTIONS.md`](multikueue/INSTRUCTIONS.md) for the full walkthrough.

---

## Supported Instance Types

The EC2 `DescribeInstanceTopology` API returns data for:

| Returns 3 layers | Returns 4 layers |
|---|---|
| p3dn.24xlarge, p4d.24xlarge, p4de.24xlarge, p5.48xlarge, p5e.48xlarge, p5en.48xlarge, p6e-gb200.36xlarge, g6e.*, g7e.*, hpc6a/6id/7g/7a/8a.*, trn1/1n/2/2u.* | p6-b200.48xlarge, p6-b300.48xlarge |

**Not supported:** g4dn, p3.16xlarge, m5, and most non-HPC types (EFA support ≠ topology API support).

---

## Key Gotchas

| Issue | Fix |
|---|---|
| Labels empty after IAM policy attach | Cloud-provider caches failures for 24h. Run the script, or replace nodes. |
| `AuthFailure` on API call | Wrong account credentials. `aws sts get-caller-identity` to verify. |
| `[]` with exit 0 | Instance type not supported, or instances not `running`. |
| Script fails on macOS | Use `label-nodes-from-ec2-topology-macos.sh` (no `mapfile` dependency). |
| MultiKueue `ClientConnectionFailed` | Install CRD stubs on workers + expand RBAC. See `multikueue/INSTRUCTIONS.md`. |
| `Flavor does not support TopologyAwareScheduling` | Management cluster flavor must NOT have `topologyName`. TAS is worker-side only. |

---

## Cost

See [`docs/COST.md`](docs/COST.md) for what drives cost on this stack (GPU EC2 instances dominate; the EC2-API labeling path adds no extra controller), a per-service breakdown, and the levers that cap spend.

---

## References

- [EC2 Instance Topology — How It Works](https://docs.aws.amazon.com/AWSEC2/latest/UserGuide/how-ec2-instance-topology-works.html)
- [Prerequisites (Supported Types, Regions, IAM)](https://docs.aws.amazon.com/AWSEC2/latest/UserGuide/ec2-instance-topology-prerequisites.html)
- [DescribeInstanceTopology API](https://docs.aws.amazon.com/AWSEC2/latest/APIReference/API_DescribeInstanceTopology.html)
- [Kueue Topology-Aware Scheduling](https://kueue.sigs.k8s.io/docs/concepts/topology_aware_scheduling/)
- [Kueue MultiKueue](https://kueue.sigs.k8s.io/docs/concepts/multikueue/)
- [MultiKueue Setup](https://kueue.sigs.k8s.io/docs/tasks/manage/setup_multikueue/)
- [cloud-provider-aws topology code](https://github.com/kubernetes/cloud-provider-aws/blob/master/pkg/providers/v1/topology.go)
