BIN_DIR ?= $(HOME)/.local/bin
TARGET = missioncontrol-fix
PLIST_NAME = com.user.missioncontrol-fix.plist
LAUNCH_AGENTS = $(HOME)/Library/LaunchAgents

all: build

build:
	@mkdir -p bin
	swiftc -O src/main.swift -F/System/Library/PrivateFrameworks -framework SkyLight -o bin/$(TARGET)
	@echo "✓ Built bin/$(TARGET)"

install: build
	@mkdir -p $(BIN_DIR)
	cp bin/$(TARGET) $(BIN_DIR)/$(TARGET)
	chmod +x $(BIN_DIR)/$(TARGET)
	@echo "✓ Installed $(TARGET) to $(BIN_DIR)/$(TARGET)"
	@./install.sh --service-only

uninstall:
	@./uninstall.sh

clean:
	rm -rf bin
	@echo "✓ Cleaned build artifacts"

.PHONY: all build install uninstall clean
