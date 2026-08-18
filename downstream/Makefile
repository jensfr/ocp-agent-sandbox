.PHONY: test-openshell-kata test-openshell-e2e test-all install-agent-sandbox install-openshell teardown preflight

test-openshell-kata:
	./scripts/run-tests.sh

test-openshell-e2e:
	./scripts/run-openshell-e2e.sh

test-all: test-openshell-kata test-openshell-e2e

install-agent-sandbox:
	./scripts/install-agent-sandbox.sh

install-openshell:
	./scripts/install-openshell.sh

teardown:
	./scripts/teardown.sh

preflight:
	@bash -c 'source scripts/lib/common.sh && source scripts/lib/cluster-checks.sh && run_preflight_checks'
