.PHONY: build test app icons

build:
	swift build

test:
	swift test

app:
	./scripts/package-app.sh

icons:
	zsh ./scripts/generate-icons.sh
