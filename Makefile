# PreviewMD Makefile
# Wraps the SPM release build into PreviewMD.app (contains the Quick Look .appex),
# signs it, and — with a Developer ID — notarizes the app and the DMG.

APP_NAME          := PreviewMD
QL_NAME           := PreviewMD-QL
# Universal by default. Multi-arch `swift build` goes through the Xcode build
# system (full Xcode required) and writes to .build/apple/Products/Release.
# A single arch (e.g. `make app ARCHS=arm64`) uses SwiftPM's native build
# system and works with just the Command Line Tools.
ARCHS             ?= arm64 x86_64
ifeq ($(words $(ARCHS)),1)
BUILD_DIR         := .build/$(strip $(ARCHS))-apple-macosx/release
else
BUILD_DIR         := .build/apple/Products/Release
endif
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
# Must match MdReaderResources.bundleName (<package>_<target>.bundle).
RESOURCE_BUNDLE   := PreviewMD_MdReaderCore.bundle
USER_APPS         := $(HOME)/Applications
LSREGISTER        := /System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister

# Pre-rename install, removed by `make install-ql` (only if its bundle ID matches).
LEGACY_APP        := $(USER_APPS)/Preview-MD.app
LEGACY_BUNDLE_ID  := com.preview-md.app

VERSION           := $(shell /usr/libexec/PlistBuddy -c 'Print CFBundleShortVersionString' packaging/Info.plist)
BUILD_NUMBER      ?= $(shell git rev-list --count HEAD 2>/dev/null || echo 0)
DMG               := $(DIST_DIR)/$(APP_NAME)-$(VERSION).dmg
APP_ZIP           := $(DIST_DIR)/$(APP_NAME)-$(VERSION)-notarize.zip
DMG_STAGING       := $(DIST_DIR)/dmg-staging
RELEASE_NOTES     := $(DIST_DIR)/RELEASE_NOTES.md

# --- Signing ----------------------------------------------------------------
# Ad-hoc ("-") by default so `make app` works without a certificate. For
# distribution: SIGN_IDENTITY="Developer ID Application: Name (TEAMID)".
# DEVELOPER_ID is still honored for backwards compatibility.
SIGN_IDENTITY     ?= $(if $(DEVELOPER_ID),$(DEVELOPER_ID),-)
NOTARY_PROFILE    ?= previewmd

ifeq ($(SIGN_IDENTITY),-)
TIMESTAMP_FLAG    :=
else
TIMESTAMP_FLAG    := --timestamp
endif
CODESIGN          := codesign --sign "$(SIGN_IDENTITY)" --force --options runtime $(TIMESTAMP_FLAG)

.PHONY: all build test run app appex sign clean install-ql \
        check-notary notarize-app dmg notarize release-notes release

all: app

build:
	swift build -c release $(foreach a,$(ARCHS),--arch $(a))

run:
	swift run $(APP_NAME)

define assemble_appex
	rm -rf $(APPEX_DIR)
	mkdir -p $(APPEX_MACOS) $(APPEX_RESOURCES)
	cp $(BUILD_DIR)/$(QL_NAME) $(APPEX_MACOS)/$(QL_NAME)
	cp -R $(BUILD_DIR)/$(RESOURCE_BUNDLE) $(APPEX_RESOURCES)/
	cp packaging/QLInfo.plist $(APPEX_CONTENTS)/Info.plist
	/usr/libexec/PlistBuddy \
		-c 'Set :CFBundleShortVersionString $(VERSION)' \
		-c 'Set :CFBundleVersion $(BUILD_NUMBER)' $(APPEX_CONTENTS)/Info.plist
	printf 'XPC!????' > $(APPEX_CONTENTS)/PkgInfo
endef

# Build, assemble, and sign (inside-out: appex with its entitlements, then app).
app: build
	rm -rf $(APP_DIR)
	mkdir -p $(MACOS_DIR) $(RESOURCES_DIR) $(PLUGINS_DIR)
	cp $(BUILD_DIR)/$(APP_NAME) $(MACOS_DIR)/$(APP_NAME)
	cp -R $(BUILD_DIR)/$(RESOURCE_BUNDLE) $(RESOURCES_DIR)/
	cp packaging/Info.plist $(CONTENTS)/Info.plist
	/usr/libexec/PlistBuddy -c 'Set :CFBundleVersion $(BUILD_NUMBER)' $(CONTENTS)/Info.plist
	cp packaging/AppIcon.icns $(RESOURCES_DIR)/AppIcon.icns
	printf 'APPL????' > $(CONTENTS)/PkgInfo
	$(assemble_appex)
	$(CODESIGN) --entitlements packaging/QL-entitlements.plist "$(APPEX_DIR)"
	$(CODESIGN) "$(APP_DIR)"
	codesign --verify --deep --strict --verbose=2 "$(APP_DIR)"
	@echo "Built $(APP_DIR) ($(VERSION) build $(BUILD_NUMBER), signed: $(SIGN_IDENTITY))"

# Assemble only the .appex into an existing dist/ app (unsigned; `make app` signs).
appex: build
	$(assemble_appex)
	@echo "Built $(APPEX_DIR)"

# Kept for compatibility: `make app` signs with SIGN_IDENTITY already.
sign: app

install-ql: app
	mkdir -p $(USER_APPS)
	@# Remove the pre-rename Preview-MD.app, but only if it really is ours.
	@if [ -d "$(LEGACY_APP)" ]; then \
		id=$$(/usr/libexec/PlistBuddy -c 'Print CFBundleIdentifier' "$(LEGACY_APP)/Contents/Info.plist" 2>/dev/null); \
		if [ "$$id" = "$(LEGACY_BUNDLE_ID)" ]; then \
			echo "Removing legacy $(LEGACY_APP) ($$id)"; \
			$(LSREGISTER) -u "$(LEGACY_APP)" 2>/dev/null || true; \
			rm -rf "$(LEGACY_APP)"; \
		else \
			echo "Leaving $(LEGACY_APP) alone (bundle ID '$$id' is not $(LEGACY_BUNDLE_ID))"; \
		fi; \
	fi
	rm -rf $(USER_APPS)/$(APP_NAME).app
	ditto $(APP_DIR) $(USER_APPS)/$(APP_NAME).app
	@echo "Installed to $(USER_APPS)/$(APP_NAME).app"
	@echo "Registering Quick Look extension..."
	# Unregister the dist/ build first — if Launch Services keeps both copies,
	# Quick Look can resolve to the wrong one and silently refuse to launch its
	# extension.
	-$(LSREGISTER) -u "$(abspath $(APP_DIR))" 2>/dev/null || true
	-$(LSREGISTER) -f "$(USER_APPS)/$(APP_NAME).app" 2>/dev/null || true
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
#   2. export SIGN_IDENTITY="Developer ID Application: Your Name (TEAMID)"
#   3. xcrun notarytool store-credentials previewmd \
#        --apple-id you@example.com --team-id TEAMID --password <app-specific>
#   4. make release
#
# Pipeline: app (sign appex → sign app → verify) → notarize-app (zip → submit →
# staple → spctl) → dmg (staging dir + Applications link → sign) → notarize
# (submit → staple → spctl) → release (notes from CHANGELOG → draft GH release).

# Fails before any build when notarization cannot succeed. The profile check
# asks notarytool itself (one quick request to Apple), since the keychain item's
# layout differs between API-key and Apple ID profiles; set
# NOTARY_SKIP_PROFILE_CHECK=1 to skip it.
check-notary:
	@if [ "$(SIGN_IDENTITY)" = "-" ]; then \
		echo "error: notarization needs a Developer ID, but SIGN_IDENTITY is ad-hoc (-)."; \
		echo "       Set SIGN_IDENTITY=\"Developer ID Application: Name (TEAMID)\" and retry."; \
		exit 1; \
	fi
	@if [ -z "$(NOTARY_SKIP_PROFILE_CHECK)" ] && \
	   ! xcrun notarytool history --keychain-profile "$(NOTARY_PROFILE)" >/dev/null 2>&1; then \
		echo "error: notarytool keychain profile '$(NOTARY_PROFILE)' not found or not working."; \
		echo "       Create it: xcrun notarytool store-credentials $(NOTARY_PROFILE) --apple-id ... --team-id ..."; \
		echo "       (or NOTARY_PROFILE=<name>; NOTARY_SKIP_PROFILE_CHECK=1 to bypass this check)"; \
		exit 1; \
	fi

# $(call notarize_file,<path>): submit, wait, and fail unless Accepted.
define notarize_file
	@echo "Submitting $(1) for notarization (profile $(NOTARY_PROFILE))..."
	@xcrun notarytool submit "$(1)" --keychain-profile "$(NOTARY_PROFILE)" --wait \
		--output-format plist > "$(DIST_DIR)/notary-result.plist"
	@status=$$(/usr/libexec/PlistBuddy -c 'Print :status' "$(DIST_DIR)/notary-result.plist" 2>/dev/null); \
	sub=$$(/usr/libexec/PlistBuddy -c 'Print :id' "$(DIST_DIR)/notary-result.plist" 2>/dev/null); \
	if [ "$$status" != "Accepted" ]; then \
		echo "error: notarization of $(1) finished with status '$$status' (submission $$sub)."; \
		echo "       See: xcrun notarytool log $$sub --keychain-profile $(NOTARY_PROFILE)"; \
		exit 1; \
	fi; \
	echo "Notarization accepted (submission $$sub)"
	@rm -f "$(DIST_DIR)/notary-result.plist"
endef

notarize-app: check-notary app
	rm -f "$(APP_ZIP)"
	ditto -c -k --keepParent "$(APP_DIR)" "$(APP_ZIP)"
	$(call notarize_file,$(APP_ZIP))
	rm -f "$(APP_ZIP)"
	xcrun stapler staple "$(APP_DIR)"
	xcrun stapler validate "$(APP_DIR)"
	spctl -a -t execute -vv "$(APP_DIR)"
	@echo "Notarized and stapled $(APP_DIR)"

dmg: check-notary notarize-app
	rm -rf "$(DMG_STAGING)" "$(DMG)"
	mkdir -p "$(DMG_STAGING)"
	ditto "$(APP_DIR)" "$(DMG_STAGING)/$(APP_NAME).app"
	ln -s /Applications "$(DMG_STAGING)/Applications"
	hdiutil create -volname "$(APP_NAME)" -srcfolder "$(DMG_STAGING)" -ov -format UDZO "$(DMG)"
	rm -rf "$(DMG_STAGING)"
	codesign --sign "$(SIGN_IDENTITY)" --force $(TIMESTAMP_FLAG) "$(DMG)"
	@echo "Built $(DMG)"

notarize: check-notary dmg
	$(call notarize_file,$(DMG))
	xcrun stapler staple "$(DMG)"
	xcrun stapler validate "$(DMG)"
	spctl -a -t open --context context:primary-signature -vv "$(DMG)"
	@echo "Notarized and stapled $(DMG)"

# Extract only this version's `## [x.y.z]` section from CHANGELOG.md.
release-notes:
	mkdir -p $(DIST_DIR)
	@awk -v hdr="## [$(VERSION)]" ' \
		index($$0, "## [") == 1 { if (on) exit; if (index($$0, hdr) == 1) { on = 1; next } } \
		on { print }' CHANGELOG.md | sed -e '/./,$$!d' > "$(RELEASE_NOTES)"
	@if ! grep -q '[^[:space:]]' "$(RELEASE_NOTES)"; then \
		echo "error: CHANGELOG.md has no '## [$(VERSION)]' section (or it is empty)."; \
		rm -f "$(RELEASE_NOTES)"; exit 1; \
	fi
	@echo "Wrote $(RELEASE_NOTES) from CHANGELOG.md [$(VERSION)]"

# Creates a *draft* GitHub release — review and publish it on github.com.
release: check-notary release-notes notarize
	gh release create "v$(VERSION)" "$(DMG)" --draft \
		--title "PreviewMD $(VERSION)" --notes-file "$(RELEASE_NOTES)"

clean:
	rm -rf .build $(DIST_DIR)
