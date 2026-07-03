SHELL := /bin/bash

# Swift 6.4 / Xcode 27 XCBuild doesn't handle main.swift top-level code;
# the native SPM build system does. Always use --build-system native.

ARCH        := $(shell uname -m)
TRIPLE      := $(ARCH)-apple-macosx
BIN_DEBUG   := .build/$(TRIPLE)/debug/xcode-agent
BIN_RELEASE := .build/release/xcode-agent
INSTALL_DIR := /usr/local/bin
DIST_DIR    := dist

# Read version from source
VERSION     := $(shell grep 'let version' Sources/xcode/main.swift | sed 's/.*"\(.*\)".*/\1/')
ARCHIVE     := $(DIST_DIR)/xcode-agent-$(VERSION)-$(TRIPLE).tar.gz
RC_TAG      := v$(VERSION)-rc.1

.PHONY: build release install install-debug clean package release-rc promote-release

build:
	swift build --build-system native

release:
	swift build -c release --build-system native

install: release
	install -m 0755 $(BIN_RELEASE) $(INSTALL_DIR)/xcode-agent

install-debug: build
	install -m 0755 $(BIN_DEBUG) $(INSTALL_DIR)/xcode-agent

clean:
	swift package clean

# Package the release binary into a tarball under dist/
package: release
	mkdir -p $(DIST_DIR)
	cp $(BIN_RELEASE) $(DIST_DIR)/xcode-agent
	cd $(DIST_DIR) && tar czf xcode-agent-$(VERSION)-$(TRIPLE).tar.gz xcode-agent
	@echo "SHA256: $$(shasum -a 256 $(ARCHIVE) | awk '{print $$1}')"
	@echo "Archive: $(ARCHIVE)"

# Cut a release candidate (pre-release) and upload to GitHub
# Usage: make release-rc   (uses RC_TAG = vX.Y.Z-rc.1 by default)
#        make release-rc RC_TAG=v0.2.0-rc.2
release-rc: package
	@echo "Tagging pre-release $(RC_TAG)..."
	gh release create $(RC_TAG) $(ARCHIVE) \
		--repo chandilsachin/xcode-agent \
		--prerelease \
		--title "xcode-agent $(RC_TAG)" \
		--notes "Release candidate for v$(VERSION). Install for testing:\n\`\`\`\ncurl -L https://github.com/chandilsachin/xcode-agent/releases/download/$(RC_TAG)/xcode-agent-$(VERSION)-$(TRIPLE).tar.gz | tar xz\nsudo mv xcode-agent /usr/local/bin/xcode-agent\n\`\`\`\nOr: brew install chandilsachin/xcode-agent/xcode-agent-beta"
	@SHA=$$(shasum -a 256 $(ARCHIVE) | awk '{print $$1}'); \
	echo ""; \
	echo "Next steps:"; \
	echo "  1. Test on target machines (see install note above)"; \
	echo "  2. Update Formula/xcode-agent-beta.rb in the tap with:"; \
	echo "     version: $(VERSION)  sha256: $$SHA  tag: $(RC_TAG)"; \
	echo "  3. When ready: make promote-release"

# Promote the latest pre-release to production and update the tap formula
# Usage: make promote-release
promote-release: package
	@echo "Promoting v$(VERSION) to production..."
	gh release create v$(VERSION) $(ARCHIVE) \
		--repo chandilsachin/xcode-agent \
		--title "xcode-agent v$(VERSION)" \
		--notes "See CHANGELOG or commit history for details."
	@SHA=$$(shasum -a 256 $(ARCHIVE) | awk '{print $$1}'); \
	echo ""; \
	echo "Production release created."; \
	echo "Now update Formula/xcode-agent.rb in chandilsachin/homebrew-xcode-agent:"; \
	echo "  version: $(VERSION)"; \
	echo "  sha256:  $$SHA"; \
	echo "  url tag: v$(VERSION)"
