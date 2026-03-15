# Mistty — macOS terminal emulator built on libghostty

# Default recipe
default: build

# Build the app (debug)
build:
    swift build

# Build the app (release)
build-release: build-libghostty
    swift build -c release

# Build the CLI tool
build-cli:
    swift build --target MisttyCLI

# Build CLI in release mode
build-cli-release:
    swift build --target MisttyCLI -c release

# Install CLI to /usr/local/bin
install-cli: build-cli-release
    cp .build/release/MisttyCLI /usr/local/bin/mistty-cli

# Uninstall CLI
uninstall-cli:
    rm -f /usr/local/bin/mistty-cli

# Package as .app bundle (debug)
bundle: build
    #!/usr/bin/env bash
    set -euo pipefail
    APP="build/Mistty.app"
    rm -rf "$APP"
    mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
    cp .build/debug/Mistty "$APP/Contents/MacOS/Mistty"
    swift build --target MisttyCLI
    cp .build/debug/MisttyCLI "$APP/Contents/MacOS/mistty-cli"
    cp Mistty/Resources/Info.plist "$APP/Contents/"
    codesign -s - -f "$APP"
    echo "Bundled: $APP"

# Package as .app bundle (release)
bundle-release: build-release
    #!/usr/bin/env bash
    set -euo pipefail
    APP="build/Mistty.app"
    rm -rf "$APP"
    mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
    cp .build/release/Mistty "$APP/Contents/MacOS/Mistty"
    swift build --target MisttyCLI -c release
    cp .build/release/MisttyCLI "$APP/Contents/MacOS/mistty-cli"
    cp Mistty/Resources/Info.plist "$APP/Contents/"
    codesign -s - -f "$APP"
    echo "Bundled: $APP"

# Install to /Applications (debug)
install: bundle
    #!/usr/bin/env bash
    set -euo pipefail
    osascript -e 'tell application "Mistty" to quit' 2>/dev/null || true
    rm -rf /Applications/Mistty.app
    cp -R build/Mistty.app /Applications/Mistty.app
    echo "Installed: /Applications/Mistty.app"

# Install to /Applications (release)
install-release: bundle-release
    #!/usr/bin/env bash
    set -euo pipefail
    osascript -e 'tell application "Mistty" to quit' 2>/dev/null || true
    rm -rf /Applications/Mistty.app
    cp -R build/Mistty.app /Applications/Mistty.app
    echo "Installed: /Applications/Mistty.app (release)"

# Run the app (debug)
run: install
    open /Applications/Mistty.app

# Run the app (release)
run-release: install-release
    open /Applications/Mistty.app

# Run tests
test:
    swift test

# Clean build artifacts
clean:
    swift package clean
    rm -rf build/

# Build libghostty from the vendored submodule (requires nix)
build-libghostty:
    nix develop --command bash -c "cd vendor/ghostty && zig build -Dapp-runtime=none -Doptimize=ReleaseFast"

# Enter the nix dev shell
dev:
    nix develop

# Initialize submodules (first-time setup)
setup:
    git submodule update --init --recursive
    @echo "Now run 'just build-libghostty' to build libghostty"

# Format Swift code (requires swift-format)
fmt:
    swift format --in-place --recursive Mistty/ MisttyTests/

# Check formatting without modifying
fmt-check:
    swift format --recursive Mistty/ MisttyTests/

# Show project info
info:
    @echo "Mistty — macOS terminal emulator"
    @echo ""
    @echo "Swift package:"
    @swift package describe 2>/dev/null | head -20
    @echo ""
    @echo "Ghostty submodule:"
    @git submodule status vendor/ghostty
