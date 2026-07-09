# Ymir — common developer tasks.
# See README.md for details. Scripts live in scripts/.

.DEFAULT_GOAL := help
.PHONY: help bootstrap generate release clean

help: ## Show this help
	@grep -E '^[a-zA-Z_-]+:.*?## .*$$' $(MAKEFILE_LIST) \
		| awk 'BEGIN {FS = ":.*?## "} {printf "  \033[36m%-12s\033[0m %s\n", $$1, $$2}'

bootstrap: ## Install prerequisites and generate the Xcode project
	@scripts/setup.sh

generate: ## Regenerate Ymir.xcodeproj from project.yml
	@xcodegen generate

release: generate ## Build the Release app, install to /Applications, and launch it
	@scripts/release_app.sh

clean: ## Remove build artifacts
	@rm -rf .build build/xcode
	@echo "Removed .build and build/xcode"
