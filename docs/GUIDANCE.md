# Topology-aware GPU scheduling on EKS using only the EC2 API (no NVIDIA Topograph)

**Question:** is there any config we need to deploy to replace NVIDIA Topograph?

**Short answer:** No controller, no operator, no Helm chart. Topology-aware scheduling on EKS
needs *node labels*, and Topograph is only one of three ways to get them. Pick in this order:

1. **Check whether your nodes already have the labels.** EKS's own AWS cloud-provider integration
   writes `topology.k8s.aws/network-node-layer-{1,2,3}` at node registration, from the same EC2 API
   Topograph calls. If they're populated, you need **zero** config — Topograph is redundant.
2. **If the labels are missing**, run the ~40-line script in this gist
   (`label-nodes-from-ec2-topology.sh`). It queries `ec2:DescribeInstanceTopology` and writes the
   *same label keys*, so every downstream consumer works unchanged. This is the full Topograph
   replacement.
3. **If you only need same-node or same-AZ placement**, you don't need network-node labels at all —
   `kubernetes.io/hostname` and `topology.kubernetes.io/zone` are on every node already.

Everything below was verified on 2026-08-03 against a live P5en EKS cluster (`ap-southeast-3`,
Kubernetes 1.34), the upstream `cloud-provider-aws` source, and the AWS prerequisites page.

---

## Step 0 — Check first. This is the whole decision.

```bash
kubectl get nodes -L \
  topology.k8s.aws/network-node-layer-1,\
topology.k8s.aws/network-node-layer-2,\
topology.k8s.aws/network-node-layer-3
```

- **Columns populated with `nn-…` values** → done. The labels are already there, natively. Skip to
  Step 4 and consume them. Do not install Topograph.
- **Columns empty** → go to Step 1. This is a fixable gap, not a missing product.

> **A useful diagnostic.** On our own P5en cluster these columns came back **empty**, while
> `topology.k8s.aws/zone-id` was populated. Both labels are written by the *same function* into the
> *same map* in `cloud-provider-aws` (`pkg/providers/v1/instances_v2.go`). So a populated `zone-id`
> alongside an empty `network-node-layer-1` is a precise signal: the cloud provider is healthy, and
> the `DescribeInstanceTopology` call **specifically** is being refused or returning nothing. Check
> `zone-id` first — it separates "cloud provider broken" from "topology call blocked".

## Step 1 — IAM: the permission that makes it work

One permission does the work:

```json
{
  "Version": "2012-10-17",
  "Statement": [{
    "Effect": "Allow",
    "Action": [
      "ec2:DescribeInstanceTopology",
      "ec2:DescribeInstances"
    ],
    "Resource": "*"
  }]
}
```

`ec2:DescribeInstanceTopology` does not support resource-level permissions, so `"Resource": "*"` is
required. The script resolves nodes from the Kubernetes API, so `ec2:DescribeInstances` is there for
the interactive exploration commands.

Where to attach it depends on who calls the API:

| Caller | Attach to | Notes |
|---|---|---|
| **EKS control plane** (writes the labels natively) | the **cluster IAM role** | The AWS-managed `AmazonEKSClusterPolicy` **already includes `ec2:DescribeInstanceTopology`** — verified against the live policy document. `AmazonEKSComputePolicy` does **not**. |
| **The script**, run by an admin | your own CLI principal | Simplest path. Run once per node-group rollout. |
| **The script**, run as an in-cluster CronJob | an **IRSA / Pod Identity role** | Also needs Kubernetes RBAC: `get`/`list`/`patch` on `nodes`. |

Two behaviours in `cloud-provider-aws` that explain silent failures
(`pkg/providers/v1/topology.go`):

- On `UnauthorizedOperation` it logs a warning and **returns no error** — nodes come up healthy with
  no topology labels, and nothing surfaces in `kubectl`. A missing permission looks exactly like an
  unsupported instance type.
- It then **caches the region as unsupported for 24 hours** and stops calling. After granting the
  permission, expect up to a 24h backoff before the control plane retries.

## Step 2 — The raw API, and how to read the answer

```bash
aws ec2 describe-instance-topology \
  --region us-east-2 \
  --filters Name=instance-type,Values=p5en.48xlarge \
  --query 'Instances[].{id:InstanceId,az:AvailabilityZone,nodes:NetworkNodes}' \
  --output json
```

A real response from our cluster (`p5en.48xlarge`, `ap-southeast-3`):

```json
[
  { "id": "i-00861fbfabfd17336", "az": "ap-southeast-3c",
    "nodes": ["nn-8e2f2fa91cde1f81a", "nn-4cea4854394742425", "nn-94c58606db16fb1e1"] },
  { "id": "i-06fbe69311867dc56", "az": "ap-southeast-3c",
    "nodes": ["nn-8e2f2fa91cde1f81a", "nn-4cea4854394742425", "nn-94c58606db16fb1e1"] },
  { "id": "i-00a898216489440c9", "az": "ap-southeast-3c",
    "nodes": ["nn-8e2f2fa91cde1f81a", "nn-4cea4854394742425", "nn-3d14202e975745b32"] }
]
```

`NetworkNodes` is an ordered path from the top of the AZ fabric down toward the host. **The rule is
just prefix matching: the more leading entries two instances share, the closer they are.**

```
NetworkNodes: [ nn-8e2f2fa9…,  nn-4cea4854…,  nn-94c58606… ]
                     │               │               │
                     │               │               └─ layer 3: leaf / rack   ← finest
                     │               └───────────────── layer 2: spine / block
                     └───────────────────────────────── layer 1: AZ fabric     ← coarsest
```

Reading the example: the first two instances share **all three** entries, so they are in the same
rack — the tightest domain, and the pair you want for a latency-sensitive job. The third shares only
the first two, so it is the same block but a **different rack**.

Grouping all 14 p5en instances in that account by layer 3 gave one group of 4, three groups of 2,
and four singletons — all inside a single layer-1/layer-2 block. That distribution is the point of
the exercise: a 2-node job placed by chance had a good chance of straddling racks.

Three gotchas, in the order they actually bite:

- **`--output table` hides errors.** On failure the error goes to stderr and stdout is blank, so a
  hard `AccessDenied` looks identical to "no results". Add `; echo "EXIT=$?"` when debugging.
- **Instance-type gated.** Supported, returning **3** network nodes: `p3dn.24xlarge`,
  `p4d`/`p4de.24xlarge`, `p5.48xlarge`, `p5e`/`p5en.48xlarge`, `p6e-gb200.36xlarge`, `g6e.*`,
  `g7e.*`, `hpc6a`/`hpc6id`/`hpc7g`/`hpc7a`/`hpc8a.*`, `trn1`/`trn1n`/`trn2`/`trn2u.*`. Returning
  **4** network nodes: `p6-b200.48xlarge`, `p6-b300.48xlarge`. Anything else (`g4dn`, `m5`, …)
  returns nothing, ever — no flag fixes it. Check the
  [prerequisites page](https://docs.aws.amazon.com/AWSEC2/latest/UserGuide/ec2-instance-topology-prerequisites.html),
  not memory; the list grows with each new family.
- **Instances must be `running`.** Stopped or pending instances are simply absent, which reads as an
  empty result. We hit exactly this: a `--filters` query for `p5.48xlarge` returned `[]` in a region
  where the type is fully supported, purely because none were running at the time.

**Attribute the failure correctly** — the three modes are distinguishable, and confusing them wastes
real time:

| Symptom | Cause |
|---|---|
| `AccessDenied` / `UnauthorizedOperation` | caller lacks `ec2:DescribeInstanceTopology` |
| `AuthFailure` | credentials aren't valid for that region/account — often calling from the wrong account |
| `UnsupportedOperation` | region genuinely not supported — check the region list before assuming this |
| `[]` with exit 0 | instance type unsupported, or instances not `running` |

Supported regions include US East (N. Virginia, Ohio), US West (N. California, Oregon), Asia Pacific
(Jakarta, Hong Kong, Hyderabad, Melbourne, Mumbai, Osaka, Seoul, Singapore, Sydney, Tokyo), Africa
(Cape Town), Canada (Central), Europe (Frankfurt, Ireland, London, Paris, Spain, Stockholm, Zurich),
Israel (Tel Aviv), Middle East (Bahrain, UAE), South America (São Paulo), GovCloud (US-West), and the
European Sovereign Cloud (Germany). The list is broad — so **verify against the docs before blaming
the region.** We had internally recorded `ap-southeast-3` as an unsupported region; re-testing with
correct credentials showed the API works there fine, and the original error was an authentication
artifact, not a region gap.

Node IDs are hashed per-account: they express relative proximity and are **not** comparable across
accounts. For nodes owned by another account (shared VPC), call from the node-owning account.

## Step 3 — Label the nodes (the actual Topograph replacement)

Run `label-nodes-from-ec2-topology.sh` (in this gist). It resolves each node's instance ID from
`.spec.providerID`, makes one API call, and writes `topology.k8s.aws/network-node-layer-N` for as
many layers as the API returns — so the 4-layer `p6-b200`/`p6-b300` case is handled automatically.

```bash
export AWS_REGION=us-east-2
./label-nodes-from-ec2-topology.sh            # dry run — prints, changes nothing
APPLY=1 ./label-nodes-from-ec2-topology.sh    # writes the labels
```

It defaults to a **dry run** and prints the proximity groups, so you can eyeball the rack layout
before touching anything. Scope it with
`NODE_SELECTOR='node.kubernetes.io/instance-type=p5en.48xlarge'` if you want a subset.

It deliberately reuses the **AWS-native label keys** rather than inventing new ones, so anything
already consuming them keeps working, and the script becomes a harmless no-op the day the native
labels start populating.

**When to re-run — the operational detail that catches people.** Topology labels are written at node
registration and are **never backfilled**: upstream `reconcileNodeLabels` only reconciles the zone,
region, and instance-type labels. Consequences:

- Granting the IAM permission does **not** label existing nodes. New nodes get them; existing nodes
  need this script (or a node replacement).
- Re-run after every scale-up. Safe and idempotent — it uses `--overwrite`.
- For a self-healing setup, run it as a CronJob (every 10–15 min is plenty) with an IRSA role plus
  RBAC for `get`/`list`/`patch` on `nodes`.

Verify:

```bash
kubectl get nodes -L topology.k8s.aws/network-node-layer-3
```

## Step 4 — Consume the labels

**Co-schedule a job's pods onto one rack** — `podAffinity` with the layer-3 label as the
`topologyKey`. The scheduler picks a rack, then keeps every matching pod inside it:

```yaml
apiVersion: v1
kind: Pod
metadata:
  name: trainer-0
  labels: { app: my-training-job }
spec:
  affinity:
    podAffinity:
      requiredDuringSchedulingIgnoredDuringExecution:
        - labelSelector:
            matchLabels: { app: my-training-job }
          topologyKey: topology.k8s.aws/network-node-layer-3    # same rack
  containers:
    - name: trainer
      image: <your-image>
      resources:
        limits: { nvidia.com/gpu: 8, vpc.amazonaws.com/efa: 32 }
```

Use `requiredDuringScheduling…` when a scattered job is worse than a delayed one — with `required`
the pods stay `Pending` until one rack has room for all of them. To prefer a rack but never block,
use `preferredDuringSchedulingIgnoredDuringExecution` with a `weight` and a nested `podAffinityTerm`.
Relax the `topologyKey` to `…-layer-2` for same-block placement, a much easier constraint to satisfy.

**Spread replicas across racks** for availability — the opposite goal, e.g. inference replicas that
shouldn't share a failure domain:

```yaml
  topologySpreadConstraints:
    - maxSkew: 1
      topologyKey: topology.k8s.aws/network-node-layer-3
      whenUnsatisfiable: ScheduleAnyway
      labelSelector:
        matchLabels: { app: my-inference-service }
```

**If you use Kueue Topology-Aware Scheduling**, it reads plain node labels too — there is no
Topograph integration point anywhere in Kueue (its `Topology` CRD accepts only a label-name string;
`nodeLabel` is the sole field). Declare the levels and it works:

```yaml
apiVersion: kueue.x-k8s.io/v1beta2      # v1beta2 on current Kueue — NOT v1alpha1
kind: Topology
metadata: { name: aws-network-topology }
spec:
  levels:
    - nodeLabel: topology.kubernetes.io/zone
    - nodeLabel: topology.k8s.aws/network-node-layer-2
    - nodeLabel: topology.k8s.aws/network-node-layer-3
    - nodeLabel: kubernetes.io/hostname          # must be the LOWEST level if used
```

Two traps worth knowing. A node missing **any** declared level label is silently excluded from the
flavor — declare a level whose label isn't populated and you get an empty flavor with pods that never
schedule, which looks like a Kueue bug but is a missing-label bug (verify with Step 0 first). And
`levels` is immutable after creation, so fix mistakes by recreating the object.

## Do the AZ first

EFA traffic only works **within a single Availability Zone** — cross-AZ EFA falls back to slower
paths or drops. Pin participating pods to one AZ with a `topology.kubernetes.io/zone` node affinity
before tuning anything at rack level. Getting the AZ wrong dwarfs any same-rack gain. In our cluster
all P5en capacity sat in one AZ (`ap-southeast-3c`), which is typical for a GPU capacity block — so
the AZ constraint was already satisfied and layer-3 was the only lever left.

## Slurm

The same API drives Slurm topology. AWS publishes
[ec2-topology-aware-for-slurm](https://github.com/aws-samples/ec2-topology-aware-for-slurm), which
calls `DescribeInstanceTopology` and emits a `topology.conf` describing switches and their nodes;
Slurm then honours it for `--switches` and for default best-fit placement. Same IAM permission, same
instance-type and region gates, same "instances must be running" caveat, and the same
group-by-`nodes[-1]` logic. No Kubernetes and no Topograph involved.

## What you give up without Topograph

Stated plainly so nobody is surprised later:

- **Nothing, for AWS network topology.** Topograph's AWS provider calls the same
  `DescribeInstanceTopology` API. Same data, same fidelity.
- **You do give up** Topograph's other backends — NVIDIA NVLink/NVL-domain discovery, InfiniBand
  fabric, and its Slurm/other-CSP providers — plus continuous reconciliation. The script is a
  point-in-time snapshot; re-run or CronJob it after scale-ups.
- **You gain** one less controller, one less Helm release, and one less component needing IRSA plus
  hostNetwork IMDS access on your GPU nodes.

For reference, Topograph writes `network.topology.nvidia.com/{accelerator,tier-0,tier-1,…}` labels
alongside the AWS-native ones. If something in your stack is hardcoded to those key names, either
repoint it at the `topology.k8s.aws/*` keys or have the script write both.

## References

- [Amazon EC2 instance topology — how it works](https://docs.aws.amazon.com/AWSEC2/latest/UserGuide/how-ec2-instance-topology-works.html)
- [Prerequisites: supported types, regions, IAM](https://docs.aws.amazon.com/AWSEC2/latest/UserGuide/ec2-instance-topology-prerequisites.html)
- [`describe-instance-topology` CLI reference](https://docs.aws.amazon.com/cli/latest/reference/ec2/describe-instance-topology.html)
- [`cloud-provider-aws` — the code that writes the native labels](https://github.com/kubernetes/cloud-provider-aws/blob/master/pkg/providers/v1/topology.go)
- [Kueue Topology-Aware Scheduling](https://kueue.sigs.k8s.io/docs/concepts/topology_aware_scheduling/)
- [aws-ofi-nccl — topology-aware scheduling notes](https://github.com/aws/aws-ofi-nccl/blob/master/doc/topology-aware.md)
- [ec2-topology-aware-for-slurm](https://github.com/aws-samples/ec2-topology-aware-for-slurm)
