# syntax=docker/dockerfile:1

FROM --platform=${BUILDPLATFORM} docker.io/golang:1.25.4 AS builder

WORKDIR /workspace

ARG goproxy=https://proxy.golang.org
ENV GOPROXY=$goproxy

COPY go.mod go.mod
COPY go.sum go.sum

RUN --mount=type=cache,target=/go/pkg/mod \
    go mod download

COPY ./ ./

ARG TARGETOS
ARG TARGETARCH

RUN --mount=type=cache,target=/root/.cache/go-build \
    --mount=type=cache,target=/go/pkg/mod \
    GOOS=${TARGETOS} GOARCH=${TARGETARCH} CGO_ENABLED=0 go build -o /workspace/bin/msp-boinc-controller main.go

FROM gcr.io/distroless/static:nonroot

WORKDIR /
COPY --from=builder /etc/ssl/certs /etc/ssl/certs
COPY --from=builder /workspace/bin/msp-boinc-controller /msp-boinc-controller
USER 65532:65532

ENTRYPOINT ["/msp-boinc-controller"]
