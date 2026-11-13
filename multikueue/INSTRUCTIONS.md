# MultiKueue Setup — Step-by-Step

## Cluster Roles

| Role | Description |
|---|---|
| **Management** | Dispatches jobs. No GPUs needed. Runs MultiKueue objects. |
| **Worker A** | GPU cluster. Runs actual workloads. Has Kueue + TAS. |
| **Worker B** | GPU cluster. Runs actual workloads. Has Kueue + TAS. |

**Naming contract:** Namespace + LocalQueue name (`fleet-lq`) must be identical on all clusters.

---

## Step 1 — Install Kueue v0.19.0 on ALL clusters

```bash
KUEUE_VER=v0.19.0
kubectl apply --server-side -f \
  https://github.com/kubernetes-sigs/kueue/releases/download/${KUEUE_VER}/manifests.yaml
kubectl -n kueue-system rollout status deploy/kueue-controller-manager --timeout=180s
```

If GitHub URL fails, download first:
```bash
curl -L -o kueue-manifests.yaml https://github.com/kubernetes-sigs/kueue/releases/download/v0.19.0/manifests.yaml
kubectl apply --server-side -f kueue-manifests.yaml
```

## Step 2 — Create namespace on ALL clusters

```bash
kubectl create ns <YOUR_NAMESPACE>
```

## Step 3 — Apply worker objects on EACH worker

Apply the single `worker-cluster.yaml` template on every worker, pointing `kubectl`
at that worker's context first and substituting that worker's own instance type and
quota (see the `Customize per worker` header in the file).

```bash
# Worker A
kubectl config use-context <worker-a-context>
kubectl apply -f worker-cluster.yaml   # with Worker A's instance type + quota

# Worker B
kubectl config use-context <worker-b-context>
kubectl apply -f worker-cluster.yaml   # with Worker B's instance type + quota
```

Verify ClusterQueue is Active:
```bash
kubectl get clusterqueue -o custom-columns='NAME:.metadata.name,ACTIVE:.status.conditions[?(@.type=="Active")].status'
```

## Step 4 — Generate static-token kubeconfigs from each worker

```bash
# On Worker A:
./scripts/create-multikueue-kubeconfig.sh worker-a.kubeconfig

# On Worker B:
./scripts/create-multikueue-kubeconfig.sh worker-b.kubeconfig
```

Test connectivity:
```bash
KUBECONFIG=worker-a.kubeconfig kubectl get clusterqueues
KUBECONFIG=worker-b.kubeconfig kubectl get clusterqueues
```

## Step 5 — Store kubeconfigs as Secrets on the management cluster

```bash
kubectl -n kueue-system create secret generic worker-a-kubeconfig --from-file=kubeconfig=worker-a.kubeconfig
kubectl -n kueue-system create secret generic worker-b-kubeconfig --from-file=kubeconfig=worker-b.kubeconfig
```

## Step 6 — Apply MultiKueue objects on the management cluster

```bash
kubectl apply -f management-cluster.yaml
```

## Step 7 — Verify workers connected

```bash
kubectl get multikueuecluster -o custom-columns='NAME:.metadata.name,ACTIVE:.status.conditions[0].status,REASON:.status.conditions[0].reason'
```

Expected:
```
NAME        ACTIVE   REASON
worker-a    True     Active
worker-b    True     Active
```

### If ACTIVE=False (ClientConnectionFailed):

Kueue v0.19 requires ALL framework CRDs on workers. Install the stubs:

```bash
# On each worker:
kubectl apply -f crd-stubs/all-missing-crds.yaml
kubectl apply -f crd-stubs/mpijob-crd.yaml
kubectl apply -f crd-stubs/trainjob-crd.yaml
```

Also ensure full RBAC for the MultiKueue SA:
```bash
kubectl delete clusterrole multikueue-sa-role 2>/dev/null
kubectl create clusterrole multikueue-sa-role --verb='*' --resource='*.*'
```

Then restart the management controller (clears backoff cache):
```bash
# On management cluster:
kubectl -n kueue-system rollout restart deploy/kueue-controller-manager
```

## Step 8 — Submit smoke test

```bash
# On management cluster:
kubectl apply -f smoke-test-no-tas.yaml
```

## Step 9 — Verify dispatch

```bash
# Check admission
kubectl -n <YOUR_NAMESPACE> get workloads

# Check job status (mirrored back to management)
kubectl -n <YOUR_NAMESPACE> get jobs

# Check which worker ran it
# On Worker A:
kubectl -n <YOUR_NAMESPACE> get jobs
# On Worker B:
kubectl -n <YOUR_NAMESPACE> get jobs
```

Expected: job appears on ONE worker only, status mirrored back to management as Complete.

---

## Cleanup

```bash
kubectl -n <YOUR_NAMESPACE> delete job multicluster-smoke
```
