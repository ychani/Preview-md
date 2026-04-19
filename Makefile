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

.PHONY: all build run app appex clean install-ql

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
	printf 'APPL????' > $(CONTENTS)/PkgInfo
	$(MAKE) appex
	@echo "Built $(APP_DIR)"

appex: build
	rm -rf $(APPEX_DIR)
	mkdir -p $(APPEX_MACOS) $(APPEX_RESOURCES)
	cp $(BUILD_DIR)/$(QL_NAME) $(APPEX_MACOS)/$(QL_NAME)
	cp -R $(BUILD_DIR)/$(RESOURCE_BUNDLE) $(APPEX_RESOURCES)/
	cp packaging/QLInfo.plist $(APPEX_CONTENTS)/Info.plist
	printf 'XPC!????' > $(APPEX_CONTENTS)/PkgInfo
	@echo "Built $(APPEX_DIR)"

install-ql: app
	mkdir -p $(USER_APPS)
	rm -rf $(USER_APPS)/$(APP_NAME).app
	cp -R $(APP_DIR) $(USER_APPS)/$(APP_NAME).app
	@echo "Installed to $(USER_APPS)/$(APP_NAME).app"
	@echo "Registering Quick Look extension..."
	-/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister \
		-f "$(USER_APPS)/$(APP_NAME).app" 2>/dev/null || true
	-pluginkit -a "$(USER_APPS)/$(APP_NAME).app/Contents/PlugIns/$(QL_NAME).appex" 2>/dev/null || true
	qlmanage -r >/dev/null 2>&1 || true
	qlmanage -r cache >/dev/null 2>&1 || true
	@echo "Done. Open the app once to finish registration, then press Space on a .md file in Finder."

clean:
	rm -rf .build $(DIST_DIR)
