# Preview-MD Makefile
# Wraps the SPM release build into Preview-MD.app (contains the Quick Look .appex).

APP_NAME          := Preview-MD
QL_NAME           := Preview-MD-QL
BUILD_DIR         := .build/release
DIST_DIR          := dist
APP_DIR           := $(DIST_DIR)/$(APP_NAME).app
CONTENTS          := $(APP_DIR)/Contents
MACOS_DIR         := $(CONTENTS)/MacOS
RESOURCES_DIR     := $(CONTENTS)/Resources
PLUGINS_DIR       := $(CONTENTS)/PlugIns
APPEX_DIR         := $(PLUGINS_DIR)/$(QL_NAME).appex
APPEX_CONTENTS    := $(APPEX_DIR)/Contents
APPEX_MACOS       := $(APPEX_CONTENTS)/MacOS
APPEX_RESOURCES   := $(APPEX_CONTENTS)/Resources
RESOURCE_BUNDLE   := PreviewMD_MdReaderCore.bundle
USER_APPS         := $(HOME)/Applications

VERSION           := $(shell /usr/libexec/PlistBuddy -c 'Print CFBundleShortVersionString' packaging/Info.plist)
DMG               := $(DIST_DIR)/$(APP_NAME)-$(VERSION).dmg

.PHONY: all build test run app appex clean install-ql sign dmg notarize release

all: app

build:
	swift build -c release

run:
	swift run Preview-MD

app: build
	rm -rf $(APP_DIR)
	mkdir -p $(MACOS_DIR) $(RESOURCES_DIR) $(PLUGINS_DIR)
	cp $(BUILD_DIR)/$(APP_NAME) $(MACOS_DIR)/$(APP_NAME)
	cp -R $(BUILD_DIR)/$(RESOURCE_BUNDLE) $(RESOURCES_DIR)/
	cp packaging/Info.plist $(CONTENTS)/Info.plist
	cp packaging/AppIcon.icns $(RESOURCES_DIR)/AppIcon.icns
	printf 'APPL????' > $(CONTENTS)/PkgInfo
	$(MAKE) appex
	@echo "Built $(APP_DIR)"

appex: build
	rm -rf $(APPEX_DIR)
	mkdir -p $(APPEX_MACOS) $(APPEX_RESOURCES)
	cp $(BUILD_DIR)/$(QL_NAME) $(APPEX_MACOS)/$(QL_NAME)
	cp -R $(BUILD_DIR)/$(RESOURCE_BUNDLE) $(APPEX_RESOURCES)/
	cp packaging/QLInfo.plist $(APPEX_CONTENTS)/Info.plist
	/usr/libexec/PlistBuddy \
		-c 'Set :CFBundleShortVersionString $(VERSION)' \
		-c 'Set :CFBundleVersion $(VERSION)' $(APPEX_CONTENTS)/Info.plist
	printf 'XPC!????' > $(APPEX_CONTENTS)/PkgInfo
	@echo "Built $(APPEX_DIR)"

install-ql: app
	mkdir -p $(USER_APPS)
	rm -rf $(USER_APPS)/$(APP_NAME).app
	cp -R $(APP_DIR) $(USER_APPS)/$(APP_NAME).app
	@echo "Installed to $(USER_APPS)/$(APP_NAME).app"
	@echo "Registering Quick Look extension..."
	# Unregister the unsigned dist/ build first — if Launch Services keeps both
	# copies, Quick Look can resolve to the unsigned one and silently refuse to
	# launch its extension.
	-/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister \
		-u "$(abspath $(APP_DIR))" 2>/dev/null || true
	-/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister \
		-f "$(USER_APPS)/$(APP_NAME).app" 2>/dev/null || true
	codesign --sign - --force --entitlements packaging/QL-entitlements.plist \
		"$(USER_APPS)/$(APP_NAME).app/Contents/PlugIns/$(QL_NAME).appex" 2>/dev/null || true
	codesign --sign - --force "$(USER_APPS)/$(APP_NAME).app" 2>/dev/null || true
	-pluginkit -a "$(USER_APPS)/$(APP_NAME).app/Contents/PlugIns/$(QL_NAME).appex" 2>/dev/null || true
	qlmanage -r >/dev/null 2>&1 || true
	qlmanage -r cache >/dev/null 2>&1 || true
	@echo "Done. Press Space on a .md file in Finder to test Quick Look."

test:
	swift test

# --- Distribution -----------------------------------------------------------
# Requires an Apple Developer ID. One-time setup:
#   1. Enroll at developer.apple.com ($99/yr), create a "Developer ID
#      Application" certificate in Xcode → Settings → Accounts.
#   2. export DEVELOPER_ID="Developer ID Application: Your Name (TEAMID)"
#   3. xcrun notarytool store-credentials preview-md \
#        --apple-id you@example.com --team-id TEAMID --password <app-specific>
#   4. make release

sign: app
ifndef DEVELOPER_ID
	$(error DEVELOPER_ID is not set. export DEVELOPER_ID="Developer ID Application: Name (TEAMID)")
endif
	codesign --sign "$(DEVELOPER_ID)" --force --timestamp --options runtime \
		--entitlements packaging/QL-entitlements.plist \
		"$(APP_DIR)/Contents/PlugIns/$(QL_NAME).appex"
	codesign --sign "$(DEVELOPER_ID)" --force --timestamp --options runtime \
		"$(APP_DIR)"
	codesign --verify --deep --strict "$(APP_DIR)"
	@echo "Signed $(APP_DIR)"

dmg: sign
	rm -f $(DMG)
	hdiutil create -volname "$(APP_NAME)" -srcfolder "$(APP_DIR)" -ov -format UDZO "$(DMG)"
	codesign --sign "$(DEVELOPER_ID)" --force --timestamp "$(DMG)"
	@echo "Built $(DMG)"

NOTARY_PROFILE ?= preview-md

notarize: dmg
	xcrun notarytool submit "$(DMG)" --keychain-profile "$(NOTARY_PROFILE)" --wait
	xcrun stapler staple "$(DMG)"
	@echo "Notarized and stapled $(DMG)"

release: notarize
	@echo "Ready to upload: $(DMG)"
	@echo "  gh release create v$(VERSION) $(DMG) --title 'v$(VERSION)' --notes-file CHANGELOG.md"

clean:
	rm -rf .build $(DIST_DIR)
