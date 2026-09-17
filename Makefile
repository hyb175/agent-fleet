# Build the native UI binary. The fleet version comes from bin/agent-fleet so
# `afui version` and `agent-fleet --version` cannot drift.
VERSION := $(shell sed -n 's/^AGENT_FLEET_VERSION="\(.*\)"/\1/p' bin/agent-fleet)

.PHONY: ui ui-test

ui:
	cd ui && go build -trimpath -ldflags "-s -w -X main.version=$(VERSION)" -o ../bin/afui ./cmd/afui

ui-test:
	cd ui && go vet ./... && test -z "$$(gofmt -l .)" && go test ./...
