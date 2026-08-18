.PHONY: test-openshell-kata install-agent-sandbox install-openshell teardown preflight

test-openshell-kata:
	./scripts/run-tests.sh

install-agent-sandbox:
	./scripts/install-agent-sandbox.sh

install-openshell:
	./scripts/install-openshell.sh

teardown:
	./scripts/teardown.sh

preflight:
	@bash -c 'source scripts/lib/common.sh && source scripts/lib/cluster-checks.sh && run_preflight_checks'
