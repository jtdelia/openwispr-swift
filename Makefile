# CI runs `make lint`, `make test`, and `make build`. Replace each placeholder
# with this project's real commands, such as `npm run lint` or `swift test`.

.PHONY: lint test build check

lint:
	@echo "lint: not configured yet. Edit the lint target in Makefile."

test:
	@echo "test: not configured yet. Edit the test target in Makefile."

build:
	@echo "build: not configured yet. Edit the build target in Makefile."

check: lint test build
