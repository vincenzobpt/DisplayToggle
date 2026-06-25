# MiniLunar — Makefile
# Commands: make build, make run, make bundle, make install, make clean

SWIFT := swift
BUILD_DIR := .build
APP_NAME := DisplayToggle

# Source files (inside SPM structure)
SOURCES := Sources/MiniLunar/*.swift

# Output paths
BINARY_PATH := $(BUILD_DIR)/release/$(APP_NAME)
APP_BUNDLE := $(APP_NAME).app
APP_CONTENTS := $(APP_BUNDLE)/Contents
APP_MACOS := $(APP_CONTENTS)/MacOS
APP_RESOURCES := $(APP_CONTENTS)/Resources

# Install location (user's Applications folder)
INSTALL_DIR := $(HOME)/Applications

default: build

# ---- Build ----

.PHONY: build
build:
	$(SWIFT) build -c release --disable-sandbox
	@echo "✓ Build complete: $(BINARY_PATH)"

.PHONY: debug
debug:
	$(SWIFT) build -c debug
	@echo "✓ Debug build complete: $(BUILD_DIR)/debug/$(APP_NAME)"

# ---- Bundle as .app ----

.PHONY: bundle
bundle: build
	@echo "Creating $(APP_BUNDLE)..."
	@mkdir -p "$(APP_MACOS)" "$(APP_RESOURCES)"
	@cp "$(BINARY_PATH)" "$(APP_MACOS)/$(APP_NAME)"
	@cp "Resources/Info.plist" "$(APP_CONTENTS)/Info.plist"
	@if [ -f "Resources/AppIcon.icns" ]; then cp "Resources/AppIcon.icns" "$(APP_RESOURCES)/AppIcon.icns"; fi
	@chmod +x "$(APP_MACOS)/$(APP_NAME)"
	@echo "✓ $(APP_BUNDLE) created"

# ---- Run ----

.PHONY: run
run: bundle
	@echo "Launching $(APP_BUNDLE)..."
	@open "$(APP_BUNDLE)"

.PHONY: run-direct
run-direct: build
	@echo "Running binary directly..."
	@"$(BINARY_PATH)"

# ---- Install ----

.PHONY: install
install: bundle
	@mkdir -p "$(INSTALL_DIR)"
	@cp -R "$(APP_BUNDLE)" "$(INSTALL_DIR)/$(APP_BUNDLE)"
	@echo "✓ Installed to $(INSTALL_DIR)/$(APP_BUNDLE)"
	@echo "  You can now launch MiniLunar from your Applications folder."

.PHONY: install-launchd
install-launchd: install
	@echo "Creating LaunchAgent for auto-start at login..."
	@mkdir -p "$(HOME)/Library/LaunchAgents"
	@plutil -create xml1 "$(HOME)/Library/LaunchAgents/com.minilunar.app.plist" 2>/dev/null || true
	@defaults write "$(HOME)/Library/LaunchAgents/com.minilunar.app" Label "com.minilunar.app"
	@defaults write "$(HOME)/Library/LaunchAgents/com.minilunar.app" ProgramArguments -array \
		"$(INSTALL_DIR)/$(APP_BUNDLE)/Contents/MacOS/$(APP_NAME)"
	@defaults write "$(HOME)/Library/LaunchAgents/com.minilunar.app" RunAtLoad -bool true
	@defaults write "$(HOME)/Library/LaunchAgents/com.minilunar.app" KeepAlive -bool false
	@plutil -convert xml1 "$(HOME)/Library/LaunchAgents/com.minilunar.app.plist" 2>/dev/null || true
	@launchctl load "$(HOME)/Library/LaunchAgents/com.minilunar.app.plist"
	@echo "✓ LaunchAgent installed. MiniLunar will start automatically at login."

# ---- Clean ----

.PHONY: clean
clean:
	rm -rf "$(BUILD_DIR)" "$(APP_BUNDLE)"
	@echo "✓ Cleaned"

.PHONY: distclean
distclean: clean
	rm -f "$(INSTALL_DIR)/$(APP_BUNDLE)"
	rm -f "$(HOME)/Library/LaunchAgents/com.minilunar.app.plist"
	@echo "✓ Fully cleaned (app + launch agent removed)"

# ---- Test / Verify ----

.PHONY: check
check:
	@echo "=== MiniLunar Environment Check ==="
	@echo "macOS: $$(sw_vers -productVersion)"
	@echo "Apple Silicon: $$(sysctl -n hw.cputype | awk '{print $$0 & 255}' | grep -q 12 && echo YES || echo NO)"
	@echo "Swift: $$(swift --version | head -1)"
	@echo "DisplayServices: $$(test -e /System/Library/PrivateFrameworks/DisplayServices.framework/DisplayServices && echo AVAILABLE || echo NOT FOUND)"
	@echo "================================"
