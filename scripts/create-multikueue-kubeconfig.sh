#!/usr/bin/env bash
# Generate a restricted kubeconfig for MultiKueue to reach ONE worker cluster.
#
# Run this with kubectl pointed at the WORKER cluster (PDX1 or PDX2). It creates a
# service account + minimal ClusterRole (create/delete/watch workloads and their
# parent Jobs) and writes a kubeconfig the management cluster uses to dispatch jobs.
# Then load that kubeconfig as a Secret on the MANAGEMENT cluster (command printed at
# the end) and reference it from a MultiKueueCluster (management-cluster.yaml).
#
# Parameterized: server URL + CA are read from the current kubectl context; no
# hardcoded account/region/endpoint. Adapted from the upstream Kueue helper
# (create-multikueue-kubeconfig.sh, Apache-2.0, The Kubernetes Authors).
set -euo pipefail

OUT="${1:?usage: $0 <output-kubeconfig-file>   # run with kubectl pointed at the WORKER cluster}"
SA_NS="${SA_NS:-kueue-system}"
SA_NAME="${SA_NAME:-multikueue-sa}"

echo ">> worker context: $(kubectl config current-context)"
echo ">> service account: ${SA_NS}/${SA_NAME}  ->  kubeconfig: ${OUT}"

# --- SA + minimal RBAC on the worker (idempotent) ---
kubectl create namespace "$SA_NS" --dry-run=client -o yaml | kubectl apply -f -
kubectl -n "$SA_NS" create serviceaccount "$SA_NAME" --dry-run=client -o yaml | kubectl apply -f -

cat <<EOF | kubectl apply -f -
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRole
metadata:
  name: multikueue-sa-role
rules:
  - apiGroups: ["batch"]
    resources: ["jobs", "jobs/status"]
    verbs: ["create", "delete", "get", "list", "watch"]
  - apiGroups: ["kueue.x-k8s.io"]
    resources: ["workloads", "workloads/status"]
    verbs: ["create", "delete", "get", "list", "watch", "patch", "update"]
  - apiGroups: ["kueue.x-k8s.io"]
    resources: ["clusterqueues", "localqueues"]
    verbs: ["get", "list", "watch"]
  # Uncomment the frameworks you dispatch through MultiKueue:
  # - apiGroups: ["jobset.x-k8s.io"]
  #   resources: ["jobsets", "jobsets/status"]
  #   verbs: ["create", "delete", "get", "list", "watch"]
  # - apiGroups: ["kubeflow.org"]
  #   resources: ["mpijobs", "mpijobs/status"]
  #   verbs: ["create", "delete", "get", "list", "watch"]
---
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRoleBinding
metadata:
  name: multikueue-sa-crb
roleRef:
  apiGroup: rbac.authorization.k8s.io
  kind: ClusterRole
  name: multikueue-sa-role
subjects:
  - kind: ServiceAccount
    name: ${SA_NAME}
    namespace: ${SA_NS}
EOF

# --- long-lived token for the SA (k8s 1.24+ does not auto-mint Secrets) ---
kubectl -n "$SA_NS" apply -f - <<EOF
apiVersion: v1
kind: Secret
metadata:
  name: ${SA_NAME}-token
  namespace: ${SA_NS}
  annotations:
    kubernetes.io/service-account.name: ${SA_NAME}
type: kubernetes.io/service-account-token
EOF

echo ">> waiting for token to populate..."
for _ in $(seq 1 30); do
  TOKEN="$(kubectl -n "$SA_NS" get secret "${SA_NAME}-token" -o jsonpath='{.data.token}' 2>/dev/null | base64 -d || true)"
  [ -n "$TOKEN" ] && break
  sleep 1
done
[ -n "${TOKEN:-}" ] || { echo "!! token never populated"; exit 1; }

# --- server URL + CA from the current context (no hardcoding) ---
CTX="$(kubectl config current-context)"
CLUSTER="$(kubectl config view -o jsonpath="{.contexts[?(@.name=='${CTX}')].context.cluster}")"
SERVER="$(kubectl config view -o jsonpath="{.clusters[?(@.name=='${CLUSTER}')].cluster.server}")"
CA="$(kubectl config view --raw -o jsonpath="{.clusters[?(@.name=='${CLUSTER}')].cluster.certificate-authority-data}")"

cat > "$OUT" <<EOF
apiVersion: v1
kind: Config
clusters:
  - name: worker
    cluster:
      server: ${SERVER}
      certificate-authority-data: ${CA}
contexts:
  - name: worker
    context:
      cluster: worker
      user: ${SA_NAME}
current-context: worker
users:
  - name: ${SA_NAME}
    user:
      token: ${TOKEN}
EOF

echo ">> wrote ${OUT}"
cat <<NOTE

>> Next: on the MANAGEMENT cluster, load this as a Secret in kueue-system and point a
   MultiKueueCluster at it (see management-cluster.yaml). For a worker named 'pdx2':

     kubectl create secret generic worker-pdx2-kubeconfig \\
       -n kueue-system --from-file=kubeconfig=${OUT}
NOTE
