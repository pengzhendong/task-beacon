.PHONY: build test app icons

build:
	swift build

test: build
	swift run taskbeacon-selftest

app:
	./scripts/package-app.sh

icons:
	zsh ./scripts/generate-icons.sh
