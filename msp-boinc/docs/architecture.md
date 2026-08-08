# msp-boinc Architecture

## Sync Loop — BoincWorkload Lifecycle

```mermaid
sequenceDiagram
    autonumber
    actor User as Consumer
    participant CW as kcp Consumer Workspace
    participant Ctrl as msp-boinc Controller
    participant BOINC as BOINC Server (XML-RPC)
    participant Vol as BOINC Volunteer Clients

    User ->> CW: Create BoincProject + BoincWorkload CR
    Ctrl ->> CW: Watch via multicluster-runtime (APIExport VW)
    CW ->> Ctrl: New BoincWorkload event

    Ctrl ->> CW: Read BoincProject + authenticator Secret
    Ctrl ->> BOINC: create_batch RPC
    BOINC -->> Ctrl: batch_id
    Ctrl ->> BOINC: submit_batch RPC (N workunits)
    BOINC -->> Ctrl: OK
    Ctrl ->> CW: Update status: Phase=Running, batchId=...

    loop Every 30 seconds
        Ctrl ->> BOINC: query_batches RPC
        BOINC ->> Vol: Dispatch workunits
        Vol ->> Vol: Run Docker container via boinc2docker
        Vol ->> BOINC: Upload results
        BOINC -->> Ctrl: Batch status (completion %, error count)
        Ctrl ->> CW: Update status counts
    end

    BOINC -->> Ctrl: state=COMPLETED
    Ctrl ->> BOINC: retire_batch RPC
    Ctrl ->> CW: Update status: Phase=Completed
    User ->> CW: Read final status
```

## Component Topology

```mermaid
graph TB
    subgraph "kcp Control Plane"
        PW["Provider Workspace<br/>root:providers:boinc"]
        CW1["Consumer Workspace 1"]
        CW2["Consumer Workspace 2"]
        AE["APIExport<br/>boinc.berkeley.edu"]
        AB1["APIBinding"] --> AE
        AB2["APIBinding"] --> AE
        CW1 --- AB1
        CW2 --- AB2
        PW --- AE
    end

    subgraph "Kubernetes Cluster (msp-boinc namespace)"
        CTRL["msp-boinc-controller<br/>(Deployment)"]
        SEC["kcp-kubeconfig<br/>(Secret)"]
        CTRL --> SEC
    end

    subgraph "BOINC Infrastructure"
        BS["BOINC Server<br/>(Docker Compose)"]
        V1["Volunteer 1"]
        V2["Volunteer 2"]
        V3["Volunteer N..."]
        BS --> V1
        BS --> V2
        BS --> V3
    end

    CTRL -- "multicluster-runtime<br/>(watches via VW URL)" --> AE
    CTRL -- "XML-RPC<br/>submit_rpc_handler.php" --> BS
```

## Key Design Decisions

1. **No downstream K8s sync.** Unlike the MongoDB MSP which syncs CRs to a downstream cluster, this controller calls BOINC's HTTP XML-RPC API directly. There is no "target cluster" — BOINC distributes work to volunteer machines.

2. **Polling-based status sync.** BOINC has no webhook/callback mechanism. The controller uses `RequeueAfter: 30s` to periodically poll `query_batches` and update the workload status in kcp.

3. **Batch-level granularity.** BOINC's remote job submission API operates at the batch level. Individual workunit details are tracked by the BOINC server but only aggregate statistics (completion %, error count) are surfaced in the CRD status.

4. **Docker workloads via boinc2docker.** Container images are run on volunteer machines via BOINC's `boinc2docker` mechanism (VirtualBox VM wrapping Docker). The controller does not deploy containers to Kubernetes.
