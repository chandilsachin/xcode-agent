SHELL := /bin/bash

# Swift 6.4 / Xcode 27 XCBuild doesn't handle main.swift top-level code;
# the native SPM build system does. Always use --build-system native.

BIN_DEBUG   := .build/arm64-apple-macosx/debug/xcode
BIN_RELEASE := .build/release/xcode
INSTALL_DIR := /usr/local/bin

.PHONY: build release install clean

build:
	swift build --build-system native

release:
	swift build -c release --build-system native

install: release
	install -m 0755 $(BIN_RELEASE) $(INSTALL_DIR)/xcode

install-debug: build
	install -m 0755 $(BIN_DEBUG) $(INSTALL_DIR)/xcode

clean:
	swift package clean
