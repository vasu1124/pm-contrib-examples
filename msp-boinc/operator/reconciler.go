package operator

import (
	"context"
	"fmt"
	"time"

	"github.com/go-logr/logr"
	corev1 "k8s.io/api/core/v1"
	apierrors "k8s.io/apimachinery/pkg/api/errors"
	metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"
	"k8s.io/apimachinery/pkg/types"
	"sigs.k8s.io/controller-runtime/pkg/cluster"
	ctrlclient "sigs.k8s.io/controller-runtime/pkg/client"
	"sigs.k8s.io/controller-runtime/pkg/reconcile"
	mcreconcile "sigs.k8s.io/multicluster-runtime/pkg/reconcile"

	boincv1alpha1 "github.com/platform-mesh/msp-boinc/apis/boinc/v1alpha1"
	"github.com/platform-mesh/msp-boinc/pkg/boincrpc"
)

const (
	// PhasePending indicates the workload has been created but not yet submitted.
	PhasePending = "Pending"
	// PhaseSubmitting indicates the workload is being submitted to the BOINC server.
	PhaseSubmitting = "Submitting"
	// PhaseRunning indicates the batch is running on BOINC volunteers.
	PhaseRunning = "Running"
	// PhaseCompleted indicates all workunits in the batch have completed.
	PhaseCompleted = "Completed"
	// PhaseFailed indicates an unrecoverable error occurred.
	PhaseFailed = "Failed"

	// pollInterval is the interval between BOINC status polls during active runs.
	pollInterval = 30 * time.Second
)

// Reconciler reconciles BoincWorkload objects from kcp consumer workspaces.
// It submits batch jobs to a BOINC server via XML-RPC and polls for status updates.
type Reconciler struct {
	log           *logr.Logger
	clusterGetter func(context.Context, string) (cluster.Cluster, error)
}

// NewReconciler creates a new Reconciler.
func NewReconciler(log *logr.Logger, clusterGetter func(context.Context, string) (cluster.Cluster, error)) *Reconciler {
	return &Reconciler{
		log:           log,
		clusterGetter: clusterGetter,
	}
}

// Reconcile handles a single BoincWorkload reconciliation event. It:
//  1. Fetches the BoincWorkload from the kcp consumer workspace.
//  2. Resolves the BoincProject and authenticator Secret.
//  3. Submits the batch to the BOINC server (if pending).
//  4. Polls the BOINC server for batch status (if running).
//  5. Updates the BoincWorkload status back in kcp.
func (r *Reconciler) Reconcile(ctx context.Context, req mcreconcile.Request) (reconcile.Result, error) {
	clusterName := req.ClusterName
	log := r.log.
		WithName("reconciler").
		WithValues("cluster", clusterName, "workload", req.NamespacedName.String())

	log.Info("Starting reconciliation")

	// Get the kcp client for this consumer workspace
	cl, err := r.clusterGetter(ctx, clusterName)
	if err != nil {
		log.Error(err, "failed to get cluster")
		return reconcile.Result{}, err
	}
	kcpClient := cl.GetClient()

	// Fetch the BoincWorkload
	workload := &boincv1alpha1.BoincWorkload{}
	if err := kcpClient.Get(ctx, req.NamespacedName, workload); err != nil {
		if apierrors.IsNotFound(err) {
			log.Info("BoincWorkload deleted, nothing to do")
			return reconcile.Result{}, nil
		}
		return reconcile.Result{}, fmt.Errorf("getting BoincWorkload: %w", err)
	}

	// Initialize phase if empty
	if workload.Status.Phase == "" {
		workload.Status.Phase = PhasePending
		if err := kcpClient.Status().Update(ctx, workload); err != nil {
			return reconcile.Result{}, fmt.Errorf("initializing phase: %w", err)
		}
		return reconcile.Result{Requeue: true}, nil
	}

	// Resolve the BoincProject
	project := &boincv1alpha1.BoincProject{}
	projectKey := types.NamespacedName{
		Namespace: workload.Namespace,
		Name:      workload.Spec.ProjectRef.Name,
	}
	if err := kcpClient.Get(ctx, projectKey, project); err != nil {
		return r.setFailed(ctx, kcpClient, workload, fmt.Sprintf("resolving BoincProject %q: %v", projectKey, err))
	}

	// Fetch the authenticator token from Secret
	authenticator, err := r.getAuthenticator(ctx, kcpClient, workload.Namespace, project.Spec.AuthenticatorSecretRef)
	if err != nil {
		return r.setFailed(ctx, kcpClient, workload, fmt.Sprintf("reading authenticator secret: %v", err))
	}

	// Create a BOINC RPC client
	boincClient := boincrpc.NewClient(project.Spec.ProjectURL, authenticator)

	switch workload.Status.Phase {
	case PhasePending:
		return r.handlePending(ctx, log, kcpClient, boincClient, workload)
	case PhaseSubmitting, PhaseRunning:
		return r.handleRunning(ctx, log, kcpClient, boincClient, workload)
	case PhaseCompleted, PhaseFailed:
		// Terminal states — nothing to do
		return reconcile.Result{}, nil
	default:
		log.Info("Unknown phase, resetting to Pending", "phase", workload.Status.Phase)
		workload.Status.Phase = PhasePending
		if err := kcpClient.Status().Update(ctx, workload); err != nil {
			return reconcile.Result{}, err
		}
		return reconcile.Result{Requeue: true}, nil
	}
}

// handlePending submits the batch to the BOINC server.
func (r *Reconciler) handlePending(
	ctx context.Context,
	log logr.Logger,
	kcpClient ctrlclient.Client,
	boincClient *boincrpc.Client,
	workload *boincv1alpha1.BoincWorkload,
) (reconcile.Result, error) {
	log.Info("Submitting batch to BOINC server")

	// Generate a unique batch name
	batchName := fmt.Sprintf("pm-%s-%s", workload.Namespace, workload.Name)

	// Create the batch
	batchID, err := boincClient.CreateBatch(ctx, batchName)
	if err != nil {
		return r.setFailed(ctx, kcpClient, workload, fmt.Sprintf("creating batch: %v", err))
	}

	// Build job specifications
	replicaCount := int(workload.Spec.ReplicaCount)
	if replicaCount <= 0 {
		replicaCount = 1
	}

	jobs := make([]boincrpc.JobSpec, replicaCount)
	for i := range jobs {
		jobs[i] = boincrpc.JobSpec{
			Command: workload.Spec.Container.Command,
		}
		if workload.Spec.Resources.FlopsEstimate != "" {
			jobs[i].FlopsEstimate = workload.Spec.Resources.FlopsEstimate
		}
		if workload.Spec.Resources.MemoryBoundMB > 0 {
			jobs[i].MemoryBound = fmt.Sprintf("%d", workload.Spec.Resources.MemoryBoundMB*1024*1024)
		}
		if workload.Spec.Resources.DiskBoundMB > 0 {
			jobs[i].DiskBound = fmt.Sprintf("%d", workload.Spec.Resources.DiskBoundMB*1024*1024)
		}
	}

	// Submit the batch
	if err := boincClient.SubmitBatch(ctx, batchID, jobs); err != nil {
		return r.setFailed(ctx, kcpClient, workload, fmt.Sprintf("submitting batch: %v", err))
	}

	// Update status
	workload.Status.Phase = PhaseRunning
	workload.Status.BatchID = batchID
	workload.Status.BatchName = batchName
	workload.Status.TotalWorkunits = int32(replicaCount)
	workload.Status.ActiveWorkunits = int32(replicaCount)
	setCondition(&workload.Status.Conditions, metav1.Condition{
		Type:               "Submitted",
		Status:             metav1.ConditionTrue,
		LastTransitionTime: metav1.Now(),
		Reason:             "BatchSubmitted",
		Message:            fmt.Sprintf("Batch %d submitted with %d workunits", batchID, replicaCount),
	})

	if err := kcpClient.Status().Update(ctx, workload); err != nil {
		return reconcile.Result{}, fmt.Errorf("updating status after submit: %w", err)
	}

	log.Info("Batch submitted", "batchID", batchID, "workunits", replicaCount)
	return reconcile.Result{RequeueAfter: pollInterval}, nil
}

// handleRunning polls the BOINC server for batch status.
func (r *Reconciler) handleRunning(
	ctx context.Context,
	log logr.Logger,
	kcpClient ctrlclient.Client,
	boincClient *boincrpc.Client,
	workload *boincv1alpha1.BoincWorkload,
) (reconcile.Result, error) {
	if workload.Status.BatchID == 0 {
		return r.setFailed(ctx, kcpClient, workload, "batch ID is 0, cannot poll status")
	}

	log.Info("Polling BOINC batch status", "batchID", workload.Status.BatchID)

	status, err := boincClient.QueryBatch(ctx, workload.Status.BatchID)
	if err != nil {
		log.Error(err, "failed to query batch status, will retry")
		return reconcile.Result{RequeueAfter: pollInterval}, nil
	}

	// Update workunit counts
	workload.Status.FailedWorkunits = int32(status.NErrorJobs)

	// Derive active and succeeded from completion percentage and total
	total := int32(status.NJobs)
	if total > 0 {
		workload.Status.TotalWorkunits = total
	}
	succeeded := int32(float64(workload.Status.TotalWorkunits) * status.CompletionPct / 100.0)
	workload.Status.SucceededWorkunits = succeeded
	workload.Status.ActiveWorkunits = workload.Status.TotalWorkunits - succeeded - workload.Status.FailedWorkunits

	switch status.State {
	case boincrpc.BatchStateCompleted:
		workload.Status.Phase = PhaseCompleted
		workload.Status.ActiveWorkunits = 0
		setCondition(&workload.Status.Conditions, metav1.Condition{
			Type:               "Complete",
			Status:             metav1.ConditionTrue,
			LastTransitionTime: metav1.Now(),
			Reason:             "BatchCompleted",
			Message:            "All workunits have completed",
		})
		log.Info("Batch completed")

		// Retire the batch
		if retireErr := boincClient.RetireBatch(ctx, workload.Status.BatchID); retireErr != nil {
			log.Error(retireErr, "failed to retire batch (non-fatal)")
		}

	case boincrpc.BatchStateAborted:
		workload.Status.Phase = PhaseFailed
		workload.Status.Message = "Batch was aborted on BOINC server"
		log.Info("Batch aborted")

	default:
		workload.Status.Phase = PhaseRunning
	}

	if err := kcpClient.Status().Update(ctx, workload); err != nil {
		return reconcile.Result{}, fmt.Errorf("updating status after poll: %w", err)
	}

	// Continue polling if still running
	if workload.Status.Phase == PhaseRunning {
		return reconcile.Result{RequeueAfter: pollInterval}, nil
	}
	return reconcile.Result{}, nil
}

// getAuthenticator reads the authenticator token from the referenced Secret.
func (r *Reconciler) getAuthenticator(
	ctx context.Context,
	client ctrlclient.Client,
	namespace string,
	ref boincv1alpha1.SecretKeySelector,
) (string, error) {
	secret := &corev1.Secret{}
	key := types.NamespacedName{Namespace: namespace, Name: ref.Name}
	if err := client.Get(ctx, key, secret); err != nil {
		return "", fmt.Errorf("getting secret %q: %w", key, err)
	}

	data, ok := secret.Data[ref.Key]
	if !ok {
		return "", fmt.Errorf("key %q not found in secret %q", ref.Key, key)
	}

	return string(data), nil
}

// setFailed updates the workload status to Failed with the given message.
func (r *Reconciler) setFailed(
	ctx context.Context,
	client ctrlclient.Client,
	workload *boincv1alpha1.BoincWorkload,
	message string,
) (reconcile.Result, error) {
	workload.Status.Phase = PhaseFailed
	workload.Status.Message = message
	if err := client.Status().Update(ctx, workload); err != nil {
		return reconcile.Result{}, fmt.Errorf("updating failed status: %w", err)
	}
	return reconcile.Result{}, nil
}

// setCondition adds or updates a condition in the conditions slice.
func setCondition(conditions *[]metav1.Condition, condition metav1.Condition) {
	for i, c := range *conditions {
		if c.Type == condition.Type {
			(*conditions)[i] = condition
			return
		}
	}
	*conditions = append(*conditions, condition)
}
