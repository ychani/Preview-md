# md-reader Makefile
# Wraps the SPM release binary into MdReader.app for double-click launch.

APP_NAME      := MdReader
BUILD_DIR     := .build/release
DIST_DIR      := dist
APP_DIR       := $(DIST_DIR)/$(APP_NAME).app
CONTENTS      := $(APP_DIR)/Contents
MACOS_DIR     := $(CONTENTS)/MacOS
RESOURCES_DIR := $(CONTENTS)/Resources

.PHONY: all build run app clean

all: app

build:
	swift build -c release

run:
	swift run

app: build
	rm -rf $(APP_DIR)
	mkdir -p $(MACOS_DIR) $(RESOURCES_DIR)
	cp $(BUILD_DIR)/$(APP_NAME) $(MACOS_DIR)/$(APP_NAME)
	@if [ -d "$(BUILD_DIR)/$(APP_NAME)_$(APP_NAME).bundle" ]; then \
		cp -R "$(BUILD_DIR)/$(APP_NAME)_$(APP_NAME).bundle" "$(RESOURCES_DIR)/"; \
	fi
	cp packaging/Info.plist $(CONTENTS)/Info.plist
	printf 'APPL????' > $(CONTENTS)/PkgInfo
	@echo "Built $(APP_DIR)"

clean:
	rm -rf .build $(DIST_DIR)
