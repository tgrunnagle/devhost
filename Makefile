SHELL_SCRIPTS = client/devhost client/add-devhost-context.sh guest/*.sh tests/run.sh tests/*.test.sh tests/fakes/*

.PHONY: test lint check

test:
	tests/run.sh

lint:
	shellcheck -s bash $(SHELL_SCRIPTS)

check: lint test
