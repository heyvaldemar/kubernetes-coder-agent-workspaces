# Coder Community on kind, with every workspace inside the sandbox's boundary.
# CPU only, at no cloud cost.
# A shell for every recipe: macOS make 3.81 runs a simple recipe without one,
# and the PATH exported below then never reaches it.
SHELL := /usr/bin/env bash
BIN := $(CURDIR)/.cache/bin
export PATH := $(BIN):$(PATH)
CLUSTER := coder-workspaces
SANDBOX := vendor/kubernetes-ai-agent-sandbox

.PHONY: tools up demo test check down

tools:
	@./scripts/install-tools.sh >/dev/null

# The sandbox's kind/cluster.yaml and install-gvisor.sh, verbatim, under this
# repository's cluster name. GITHUB=app adds GitHub external auth from your
# own OAuth app (docs/first-workspace.md); GITHUB=placeholder is what the e2e
# runs, and `make test` needs it.
GITHUB ?=
up: tools
	kind create cluster --name $(CLUSTER) --config $(SANDBOX)/kind/cluster.yaml --wait 120s
	./$(SANDBOX)/scripts/install-gvisor.sh $(CLUSTER)
	CODER_GITHUB=$(GITHUB) ./scripts/install-coder.sh

# Sign in, push the template, start a workspace and run a command in it.
# docs/first-workspace.md walks the same steps by hand.
demo: tools
	./scripts/demo.sh

test: tools
	CLUSTER=$(CLUSTER) ./tests/e2e/run.sh

check: tools
	./scripts/validate.sh
	python3 tests/static/plant_violations.py

down: tools
	kind delete cluster --name $(CLUSTER)
