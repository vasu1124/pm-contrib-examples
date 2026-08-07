# msp-boinc — BOINC as an orderable compute service for Platform Mesh

A [Platform Mesh](https://platform-mesh.io) managed service provider (MSP) that lets consumers submit Docker container workloads to a [BOINC](https://boinc.berkeley.edu/) volunteer computing network through declarative Kubernetes CRDs in their kcp workspaces.

A consumer creates a `BoincWorkload` in their kcp workspace; the `msp-boinc` controller submits it as a batch job to a BOINC server via XML-RPC. Status (completion percentage, workunit counts) flows back to the consumer. See [`docs/architecture.md`](docs/architecture.md) for flow diagrams.

> **Note:** This MSP is different from sync-based examples (MongoDB, Postgres):
> - The controller does **not** sync CRs to a downstream Kubernetes cluster
> - Instead, it calls the BOINC server's XML-RPC API directly (`submit_rpc_handler.php`)
> - Workloads run on BOINC **volunteer clients**, not on the K8s cluster

## Prerequisites

| Tool | Notes |
|------|-------|
| A running **Platform Mesh** cluster | With kcp, portal, and at least one compute cluster |
| `kubectl` | Plus the `kubectl-kcp` plugin (`kubectl ws`) |
| `docker` / `docker compose` | For the test BOINC server |
| `go` ≥ 1.25 | To build the controller |

## Quick Start

### 1. Set up kubeconfigs

```bash
# Platform Mesh admin kubeconfig (kcp)
export PM_KUBECONFIG="path/to/kcp-admin.kubeconfig"
# Compute cluster kubeconfig
export COMPUTE_KUBECONFIG="path/to/compute.kubeconfig"
```

### 2. Create provider workspace and apply kcp resources

```bash
KUBECONFIG=$PM_KUBECONFIG kubectl ws use :
KUBECONFIG=$PM_KUBECONFIG kubectl ws create providers --type=root:providers --enter --ignore-existing
KUBECONFIG=$PM_KUBECONFIG kubectl ws create boinc --type=root:provider --enter --ignore-existing
KUBECONFIG=$PM_KUBECONFIG kubectl apply -f config/kcp/apiresourceschema-boincprojects.yaml
KUBECONFIG=$PM_KUBECONFIG kubectl apply -f config/kcp/apiresourceschema-boincworkloads.yaml
KUBECONFIG=$PM_KUBECONFIG kubectl apply -f config/kcp/apiexport.yaml
KUBECONFIG=$PM_KUBECONFIG kubectl apply -f config/provider/providermetadata.yaml
KUBECONFIG=$PM_KUBECONFIG kubectl apply -f config/provider/contentconfiguration.yaml
```

### 3. Extract operator kubeconfig

```bash
KUBECONFIG=$PM_KUBECONFIG kubectl ws root:providers:boinc
VW_URL="$(KUBECONFIG=$PM_KUBECONFIG kubectl get apiexportendpointslices.apis.kcp.io boinc.platform-mesh.io -o jsonpath='{.status.endpoints[0].url}')"
KUBECONFIG=$PM_KUBECONFIG kubectl config view --minify --flatten > operator.kubeconfig
kubectl --kubeconfig=operator.kubeconfig config set-cluster workspace.kcp.io/current \
  --server="${VW_URL}" --insecure-skip-tls-verify=true
```

### 4. Set up the test BOINC server

Run a BOINC server using Docker Compose (on any reachable host):

```bash
git clone https://github.com/marius311/boinc-server-docker.git /tmp/boinc-server
cd /tmp/boinc-server
docker compose up -d
```

The server will be available at `http://localhost/test_project`. You'll need the admin authenticator token:

```bash
# Get the authenticator (from the BOINC server container)
docker compose exec apache cat /root/project/test_project/keys/authenticator
```

Store it as a Secret in the consumer workspace (see step 6).

### 5. Build, load, and deploy the controller

```bash
# Build
make build
make image-build IMAGE_TAG=dev

# Load into the Platform Mesh cluster (if using kind)
kind load docker-image ghcr.io/platform-mesh/msp-boinc-controller:dev --name platform-mesh

# Deploy
KUBECONFIG=$COMPUTE_KUBECONFIG kubectl apply -f config/deploy/namespace.yaml
KUBECONFIG=$COMPUTE_KUBECONFIG kubectl -n msp-boinc create secret generic msp-boinc-kcp-kubeconfig \
  --from-file=kubeconfig=operator.kubeconfig
KUBECONFIG=$COMPUTE_KUBECONFIG kubectl apply -f config/deploy/rbac.yaml
KUBECONFIG=$COMPUTE_KUBECONFIG kubectl apply -f config/deploy/deployment.yaml
```

### 6. Bind a consumer workspace and order a workload

```bash
# Create consumer workspace and bind
KUBECONFIG=$PM_KUBECONFIG kubectl ws :root
KUBECONFIG=$PM_KUBECONFIG kubectl ws create my-consumer --enter --ignore-existing
KUBECONFIG=$PM_KUBECONFIG kubectl apply -f config/kcp/apibinding.yaml

# Create the authenticator Secret in the consumer workspace
KUBECONFIG=$PM_KUBECONFIG kubectl create secret generic boinc-auth \
  --from-literal=authenticator="<YOUR_AUTHENTICATOR_TOKEN>"

# Order a BOINC project + workload
KUBECONFIG=$PM_KUBECONFIG kubectl apply -f config/samples/boincproject.yaml
KUBECONFIG=$PM_KUBECONFIG kubectl apply -f config/samples/boincworkload.yaml
```

### 7. Verify

```bash
# Watch the workload status
KUBECONFIG=$PM_KUBECONFIG kubectl get boincworkloads -w

# Check controller logs
KUBECONFIG=$COMPUTE_KUBECONFIG kubectl -n msp-boinc logs -l app=msp-boinc-controller -f
```

## Local Development

Run the controller locally against a kcp workspace:

```bash
go run main.go --kcp-kubeconfig=operator.kubeconfig
```

## Project Structure

```
├── main.go                  # Controller entrypoint (multicluster-runtime)
├── apis/boinc/v1alpha1/     # CRD Go types (BoincWorkload, BoincProject)
├── operator/                # Reconciler (BOINC batch submission & status polling)
├── pkg/boincrpc/            # BOINC XML-RPC HTTP client
├── config/
│   ├── kcp/                 # APIResourceSchema, APIExport, APIBinding
│   ├── provider/            # ProviderMetadata, ContentConfiguration
│   ├── deploy/              # Deployment, RBAC, Namespace
│   └── samples/             # Sample CRs for testing
├── docs/architecture.md     # Mermaid architecture diagrams
├── Dockerfile               # Multi-stage build
└── Makefile                 # Build targets
```

## BOINC Server Configuration

The controller connects to a BOINC server via the `BoincProject` CRD's `spec.projectUrl`. This URL must be reachable from the controller pod.

For production, point `projectUrl` to your BOINC server (e.g., `https://boinc.example.com/my_project`). The authenticator token is stored in a Kubernetes Secret referenced by `spec.authenticatorSecretRef`.

For the test server running via Docker Compose on the same host as the Platform Mesh cluster:
- If using kind: `http://host.docker.internal/test_project`
- If using a remote cluster: `http://<host-ip>/test_project`
