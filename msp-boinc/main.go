package main

import (
	"context"
	"errors"
	"flag"
	"fmt"
	"os"

	"github.com/go-logr/logr"
	apisv1alpha1 "github.com/kcp-dev/kcp/sdk/apis/apis/v1alpha1"
	corev1alpha1 "github.com/kcp-dev/kcp/sdk/apis/core/v1alpha1"
	tenancyv1alpha1 "github.com/kcp-dev/kcp/sdk/apis/tenancy/v1alpha1"
	"github.com/kcp-dev/multicluster-provider/apiexport"
	"golang.org/x/sync/errgroup"
	"k8s.io/apimachinery/pkg/util/runtime"
	"k8s.io/client-go/kubernetes/scheme"
	"k8s.io/client-go/tools/clientcmd"
	ctrl "sigs.k8s.io/controller-runtime"
	kubezap "sigs.k8s.io/controller-runtime/pkg/log/zap"
	"sigs.k8s.io/controller-runtime/pkg/manager"
	mccontroller "sigs.k8s.io/multicluster-runtime/pkg/controller"
	mchandler "sigs.k8s.io/multicluster-runtime/pkg/handler"
	mcmanager "sigs.k8s.io/multicluster-runtime/pkg/manager"
	mcsource "sigs.k8s.io/multicluster-runtime/pkg/source"

	boincv1alpha1 "github.com/platform-mesh/msp-boinc/apis/boinc/v1alpha1"
	"github.com/platform-mesh/msp-boinc/operator"
)

func init() {
	runtime.Must(tenancyv1alpha1.AddToScheme(scheme.Scheme))
	runtime.Must(corev1alpha1.AddToScheme(scheme.Scheme))
	runtime.Must(apisv1alpha1.AddToScheme(scheme.Scheme))
	runtime.Must(boincv1alpha1.AddToScheme(scheme.Scheme))
}

func main() {
	if err := run(); err != nil {
		fmt.Fprintf(os.Stderr, "error: %v\n", err)
		os.Exit(1)
	}
}

func run() error {
	var kcpKubeconfig string
	flag.StringVar(&kcpKubeconfig, "kcp-kubeconfig", "", "kubeconfig to connect to kcp provider workspace where APIExport exists")

	zapOpts := kubezap.Options{Development: true}
	zapOpts.BindFlags(flag.CommandLine)
	flag.Parse()

	if kcpKubeconfig == "" {
		return errors.New("--kcp-kubeconfig must be specified")
	}

	logger := kubezap.New(kubezap.UseFlagOptions(&zapOpts))
	ctrl.SetLogger(logger)
	log := logger.WithName("setup")

	// Build kcp REST config
	kcpConfig, err := clientcmd.BuildConfigFromFlags("", kcpKubeconfig)
	if err != nil {
		return fmt.Errorf("building kcp kubeconfig: %w", err)
	}

	// Create the kcp apiexport provider — discovers all consumer workspaces
	// that have bound to our APIExport via APIExportEndpointSlice.
	provider, err := apiexport.New(kcpConfig, apiexport.Options{})
	if err != nil {
		return fmt.Errorf("creating apiexport provider: %w", err)
	}

	// Create the multi-cluster manager
	mgr, err := mcmanager.New(kcpConfig, provider, manager.Options{
		Logger: logger.WithName("manager"),
	})
	if err != nil {
		return fmt.Errorf("creating multi-cluster manager: %w", err)
	}

	// Build the reconciler and register it
	rec := operator.NewReconciler(&logger, mgr.GetCluster)
	if err := setupController(mgr, rec, log); err != nil {
		return fmt.Errorf("setting up controller: %w", err)
	}

	log.Info("Starting provider and manager")
	g, ctx := errgroup.WithContext(context.Background())
	g.Go(func() error { return wrapError("provider", provider.Run(ctx, mgr)) })
	g.Go(func() error { return wrapError("manager", mgr.Start(ctx)) })

	return g.Wait()
}

func setupController(mgr mcmanager.Manager, rec *operator.Reconciler, log logr.Logger) error {
	c, err := mccontroller.New("boinc-workload-controller", mgr, mccontroller.Options{
		Reconciler: rec,
	})
	if err != nil {
		return fmt.Errorf("creating controller: %w", err)
	}

	// Watch BoincWorkload resources across all kcp consumer workspaces
	if err := c.MultiClusterWatch(
		mcsource.TypedKind(
			&boincv1alpha1.BoincWorkload{},
			mchandler.TypedEnqueueRequestForObject[*boincv1alpha1.BoincWorkload](),
		),
	); err != nil {
		return fmt.Errorf("setting up multi-cluster watch for BoincWorkload: %w", err)
	}

	log.Info("Controller setup complete", "controller", "boinc-workload-controller")
	return nil
}

func wrapError(producer string, err error) error {
	return fmt.Errorf("%s: %w", producer, err)
}
