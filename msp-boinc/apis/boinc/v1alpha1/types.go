package v1alpha1

import (
	metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"
)

// SecretKeySelector selects a key of a Secret.
type SecretKeySelector struct {
	Name string `json:"name"`
	Key  string `json:"key"`
}

// BoincProjectSpec defines the desired state of BoincProject
type BoincProjectSpec struct {
	ProjectURL             string            `json:"projectUrl"`
	DisplayName            string            `json:"displayName"`
	AuthenticatorSecretRef SecretKeySelector `json:"authenticatorSecretRef"`
}

// BoincProjectStatus defines the observed state of BoincProject
type BoincProjectStatus struct {
	Phase         string       `json:"phase"`
	Message       string       `json:"message,omitempty"`
	LastProbeTime *metav1.Time `json:"lastProbeTime,omitempty"`
}

// +kubebuilder:object:root=true
// +kubebuilder:subresource:status
// +kubebuilder:printcolumn:name="Phase",type="string",JSONPath=".status.phase",description="The phase of the BOINC project"

// BoincProject is the Schema for the boincprojects API
type BoincProject struct {
	metav1.TypeMeta   `json:",inline"`
	metav1.ObjectMeta `json:"metadata,omitempty"`

	Spec   BoincProjectSpec   `json:"spec,omitempty"`
	Status BoincProjectStatus `json:"status,omitempty"`
}

// +kubebuilder:object:root=true

// BoincProjectList contains a list of BoincProject
type BoincProjectList struct {
	metav1.TypeMeta `json:",inline"`
	metav1.ListMeta `json:"metadata,omitempty"`
	Items           []BoincProject `json:"items"`
}

// LocalObjectReference contains enough information to let you locate the
// referenced object inside the same namespace.
type LocalObjectReference struct {
	Name string `json:"name"`
}

// ContainerSpec describes the container that runs the BOINC task
type ContainerSpec struct {
	Image   string `json:"image"`
	Command string `json:"command"`
}

// ResourceSpec describes compute resources needed for BOINC tasks
type ResourceSpec struct {
	FlopsEstimate string `json:"flopsEstimate,omitempty"`
	MemoryBoundMB int64  `json:"memoryBoundMB,omitempty"`
	DiskBoundMB   int64  `json:"diskBoundMB,omitempty"`
}

// InputFile describes an input file needed for the task
type InputFile struct {
	Name string `json:"name"`
	URL  string `json:"url"`
}

// BoincWorkloadSpec defines the desired state of BoincWorkload
type BoincWorkloadSpec struct {
	ProjectRef   LocalObjectReference `json:"projectRef"`
	Container    ContainerSpec        `json:"container"`
	Resources    ResourceSpec         `json:"resources,omitempty"`
	ReplicaCount int32                `json:"replicaCount"`
	InputFiles   []InputFile          `json:"inputFiles,omitempty"`
}

// BoincWorkloadStatus defines the observed state of BoincWorkload
type BoincWorkloadStatus struct {
	Phase              string             `json:"phase"`
	BatchID            int64              `json:"batchId,omitempty"`
	BatchName          string             `json:"batchName,omitempty"`
	ActiveWorkunits    int32              `json:"activeWorkunits"`
	SucceededWorkunits int32              `json:"succeededWorkunits"`
	FailedWorkunits    int32              `json:"failedWorkunits"`
	TotalWorkunits     int32              `json:"totalWorkunits"`
	Message            string             `json:"message,omitempty"`
	Conditions         []metav1.Condition `json:"conditions,omitempty"`
}

// +kubebuilder:object:root=true
// +kubebuilder:subresource:status
// +kubebuilder:printcolumn:name="Phase",type="string",JSONPath=".status.phase",description="The phase of the BOINC workload"
// +kubebuilder:printcolumn:name="Active",type="integer",JSONPath=".status.activeWorkunits",description="Number of active workunits"
// +kubebuilder:printcolumn:name="Succeeded",type="integer",JSONPath=".status.succeededWorkunits",description="Number of succeeded workunits"

// BoincWorkload is the Schema for the boincworkloads API
type BoincWorkload struct {
	metav1.TypeMeta   `json:",inline"`
	metav1.ObjectMeta `json:"metadata,omitempty"`

	Spec   BoincWorkloadSpec   `json:"spec,omitempty"`
	Status BoincWorkloadStatus `json:"status,omitempty"`
}

// +kubebuilder:object:root=true

// BoincWorkloadList contains a list of BoincWorkload
type BoincWorkloadList struct {
	metav1.TypeMeta `json:",inline"`
	metav1.ListMeta `json:"metadata,omitempty"`
	Items           []BoincWorkload `json:"items"`
}

func init() {
	SchemeBuilder.Register(&BoincProject{}, &BoincProjectList{}, &BoincWorkload{}, &BoincWorkloadList{})
}
