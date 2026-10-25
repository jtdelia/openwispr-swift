# CI runs `make lint`, `make test`, and `make build` on a macOS 27 runner with Xcode 27, and
# `make ui-test` only on manual dispatch.

# macOS ties permission grants to the signing identity. Ad-hoc builds lose them on every rebuild;
# `make run SIGNING_IDENTITY="Apple Development"` keeps them.
SIGNING_IDENTITY ?= -
DERIVED_DATA ?= build/DerivedData
XCODEBUILD = xcodebuild -project OpenWispr.xcodeproj -scheme OpenWispr -destination 'platform=macOS' \
	-derivedDataPath $(DERIVED_DATA) -skipMacroValidation -skipPackagePluginValidation
APP = $(DERIVED_DATA)/Build/Products/Debug/OpenWispr.app

.PHONY: lint test build check project ui-test run clean

project:
	xcodegen generate --quiet

lint:
	swiftlint lint --strict --quiet

test:
	swift test --package-path Packages/OpenWisprCore

build: project
	$(XCODEBUILD) -configuration Debug -quiet build

ui-test: project
	$(XCODEBUILD) test -only-testing:OpenWisprUITests

run: build
ifneq ($(SIGNING_IDENTITY),-)
	codesign --force --options runtime --sign "$(SIGNING_IDENTITY)" $(APP)/Contents/MacOS/*.dylib
	codesign --force --options runtime --entitlements App/OpenWispr/OpenWispr.entitlements \
		--sign "$(SIGNING_IDENTITY)" $(APP)
endif
	open $(APP)

check: lint test build

clean:
	rm -rf $(DERIVED_DATA) OpenWispr.xcodeproj
