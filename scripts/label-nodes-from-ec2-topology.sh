#!/usr/bin/env bash
#
# label-nodes-from-ec2-topology.sh
#
# Replaces NVIDIA Topograph with ~40 lines of AWS CLI + kubectl.
#
# Reads the EC2 instance-topology tree for every node in the current cluster and writes it
# onto the nodes as labels:
#
#     topology.k8s.aws/network-node-layer-1   (coarsest)
#     topology.k8s.aws/network-node-layer-2
#     topology.k8s.aws/network-node-layer-3   (finest -- same value = same rack)
#     topology.k8s.aws/network-node-layer-4   (only p6-b200 / p6-b300, which return 4 layers)
#
# These are the SAME label keys the AWS cloud provider writes natively, so anything that already
# consumes them (Kueue TAS, KAI, podAffinity, topologySpreadConstraints) works unchanged.
#
# Usage:
#     export AWS_REGION=us-east-2                 # required
#     ./label-nodes-from-ec2-topology.sh           # dry run: prints, changes nothing
#     APPLY=1 ./label-nodes-from-ec2-topology.sh   # actually writes the labels
#
# Optional:
#     NODE_SELECTOR='node.kubernetes.io/instance-type=p5en.48xlarge'   # restrict to some nodes
#
# Requires: awscli v2, kubectl, python3. IAM: ec2:DescribeInstanceTopology (+ ec2:DescribeInstances).
# Safe to re-run: labels are overwritten, never duplicated. Read-only unless APPLY=1.

set -euo pipefail

AWS_REGION="${AWS_REGION:-$(aws configure get region || true)}"
[ -n "$AWS_REGION" ] || { echo "ERROR: set AWS_REGION" >&2; exit 1; }
NODE_SELECTOR="${NODE_SELECTOR:-}"
APPLY="${APPLY:-0}"
PREFIX="topology.k8s.aws/network-node-layer-"

sel=()
[ -n "$NODE_SELECTOR" ] && sel=(-l "$NODE_SELECTOR")

# 1. Map instance-id -> node-name from .spec.providerID (aws:///<az>/<instance-id>).
#    providerID is authoritative; node names are not always derivable from the instance id.
echo ">> collecting nodes (region=$AWS_REGION, selector=${NODE_SELECTOR:-<all>})"
mapfile -t pairs < <(kubectl get nodes "${sel[@]}" \
  -o jsonpath='{range .items[*]}{.spec.providerID}{" "}{.metadata.name}{"\n"}{end}' \
  | sed 's|^aws:///[^/]*/||' | awk 'NF==2')

[ "${#pairs[@]}" -gt 0 ] || { echo "ERROR: no nodes with an aws:// providerID matched" >&2; exit 1; }

ids=()
for p in "${pairs[@]}"; do ids+=("${p%% *}"); done
echo ">> ${#ids[@]} node(s): ${ids[*]}"

# 2. One API call for all of them. Errors are surfaced, not swallowed -- an empty result and a
#    permission error look identical on stdout otherwise, which is the classic wasted afternoon.
echo ">> aws ec2 describe-instance-topology"
topo_json="$(aws ec2 describe-instance-topology \
  --region "$AWS_REGION" \
  --instance-ids "${ids[@]}" \
  --query 'Instances[].{id:InstanceId,type:InstanceType,az:AvailabilityZone,nodes:NetworkNodes}' \
  --output json)" || {
  cat >&2 <<'ERRHINT'
ERROR: describe-instance-topology failed. The three gates, in the order they actually bite:
  AccessDenied / UnauthorizedOperation -> the caller lacks ec2:DescribeInstanceTopology.
  UnsupportedOperation                 -> region not supported (check the prerequisites page),
                                          OR you are calling in the wrong account for these nodes.
  empty [] with exit 0                 -> instance type not supported, or not in 'running' state.
ERRHINT
  exit 1
}

# 3. Emit "node-name label=value ..." lines, then group by layer-3 so a human can sanity-check.
echo "$topo_json" | python3 -c '
import json, sys, collections
prefix = sys.argv[1]
id2node = dict(p.split(" ", 1) for p in sys.argv[2:])
data = json.load(sys.stdin)

if not data:
    sys.exit("ERROR: API returned [] for every instance -- unsupported type, or not running.")

lines, groups, seen = [], collections.defaultdict(list), set()
for inst in data:
    node = id2node.get(inst["id"])
    if not node:
        continue
    seen.add(inst["id"])
    labels = " ".join(f"{prefix}{i+1}={nn}" for i, nn in enumerate(inst["nodes"]))
    lines.append(f"{node} {labels}")
    groups[inst["nodes"][-1]].append(node)          # last layer = finest = same rack

missing = set(id2node) - seen
if missing:
    print(f"WARN: no topology returned for {len(missing)} instance(s): {sorted(missing)}",
          file=sys.stderr)

print("\n>> proximity groups (same finest-layer value = same rack):", file=sys.stderr)
for leaf, nodes in sorted(groups.items(), key=lambda kv: -len(kv[1])):
    print(f"   {leaf}  n={len(nodes)}", file=sys.stderr)
    for n in sorted(nodes):
        print(f"       {n}", file=sys.stderr)

print("\n".join(lines))
' "$PREFIX" "${pairs[@]}" > /tmp/topo-labels.$$ || { rm -f /tmp/topo-labels.$$; exit 1; }

# 4. Apply (or just show).
echo
if [ "$APPLY" != "1" ]; then
  echo ">> DRY RUN -- would run:"
  while read -r node labels; do echo "   kubectl label node $node --overwrite $labels"; done < /tmp/topo-labels.$$
  echo
  echo ">> re-run with APPLY=1 to write these labels"
else
  while read -r node labels; do
    # shellcheck disable=SC2086
    kubectl label node "$node" --overwrite $labels
  done < /tmp/topo-labels.$$
  echo
  echo ">> verify:"
  kubectl get nodes "${sel[@]}" -L "${PREFIX}1,${PREFIX}2,${PREFIX}3"
fi
rm -f /tmp/topo-labels.$$
