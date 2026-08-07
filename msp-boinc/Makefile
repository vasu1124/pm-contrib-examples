IMAGE_REGISTRY ?= ghcr.io/platform-mesh
IMAGE_NAME     ?= msp-boinc-controller
IMAGE_TAG      ?= latest
IMAGE          ?= $(IMAGE_REGISTRY)/$(IMAGE_NAME):$(IMAGE_TAG)

.PHONY: build
build: ## Build the controller binary
	go build -o bin/msp-boinc-controller main.go

.PHONY: run
run: ## Run the controller locally
	go run main.go --kcp-kubeconfig=$(KCP_KUBECONFIG)

.PHONY: image-build
image-build: ## Build the container image
	docker build -t $(IMAGE) .

.PHONY: image-push
image-push: ## Push the container image
	docker push $(IMAGE)

.PHONY: kind-load
kind-load: ## Load the image into kind cluster
	kind load docker-image $(IMAGE) --name $(KIND_CLUSTER)

.PHONY: generate
generate: ## Generate deepcopy methods
	go install sigs.k8s.io/controller-tools/cmd/controller-gen@latest
	controller-gen object paths=./apis/...

.PHONY: fmt
fmt: ## Run go fmt
	go fmt ./...

.PHONY: vet
vet: ## Run go vet
	go vet ./...

.PHONY: tidy
tidy: ## Run go mod tidy
	go mod tidy

.PHONY: help
help: ## Show this help
	@grep -E '^[a-zA-Z_-]+:.*?## .*$$' $(MAKEFILE_LIST) | sort | awk 'BEGIN {FS = ":.*?## "}; {printf "\033[36m%-15s\033[0m %s\n", $$1, $$2}'
