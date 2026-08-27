.PHONY: web ios-project simulator-build test-build simulator-test audit clean-generated

UI_DIR := app/ui
IOS_DIR := ios/NightBloodRemote
PROJECT := $(IOS_DIR)/NightBloodRemote.xcodeproj
SCHEME := NightBloodRemote

web:
	cd $(UI_DIR) && npm run build:ios-direct

ios-project: web
	cd $(IOS_DIR) && xcodegen generate

simulator-build: ios-project
	xcodebuild -project $(PROJECT) -scheme $(SCHEME) \
		-destination 'generic/platform=iOS Simulator' \
		-derivedDataPath /tmp/nightblood-public-derived-data \
		CODE_SIGNING_ALLOWED=NO build

test-build: ios-project
	xcodebuild -project $(PROJECT) -scheme $(SCHEME) \
		-destination 'generic/platform=iOS Simulator' \
		-derivedDataPath /tmp/nightblood-public-derived-data \
		CODE_SIGNING_ALLOWED=NO build-for-testing

simulator-test: ios-project
	@test -n "$(SIMULATOR)" || { \
		echo "Set SIMULATOR to an available device name."; \
		echo "Example: make simulator-test SIMULATOR='iPhone 17 Pro'"; \
		exit 2; \
	}
	xcodebuild -project $(PROJECT) -scheme $(SCHEME) \
		-destination 'platform=iOS Simulator,name=$(SIMULATOR)' \
		-derivedDataPath /tmp/nightblood-public-derived-data \
		CODE_SIGNING_ALLOWED=NO test

audit:
	/bin/sh scripts/audit-public-source.sh

clean-generated:
	@echo "Remove generated files only after reviewing the explicit paths below:"
	@echo "  $(PROJECT)"
	@echo "  $(UI_DIR)/dist-ios-direct"
	@echo "  /tmp/nightblood-public-derived-data"
