# Mistty — macOS terminal emulator built on libghostty

# Default recipe
default: build

# Re-render app icon from assets/AppIcon.svg → Mistty/Resources/AppIcon.icns.
# Requires: magick (nix devshell), iconutil (macOS).
icon:
    #!/usr/bin/env bash
    set -euo pipefail
    SVG="assets/AppIcon.svg"
    OUT="Mistty/Resources/AppIcon.icns"
    ICONSET="build/AppIcon.iconset"
    rm -rf "$ICONSET"
    mkdir -p "$ICONSET"
    for spec in 16:icon_16x16.png 32:icon_16x16@2x.png 32:icon_32x32.png 64:icon_32x32@2x.png \
                128:icon_128x128.png 256:icon_128x128@2x.png 256:icon_256x256.png \
                512:icon_256x256@2x.png 512:icon_512x512.png 1024:icon_512x512@2x.png; do
      size=${spec%%:*}; name=${spec##*:}
      magick -background none "$SVG" -resize ${size}x${size} "$ICONSET/$name"
    done
    iconutil -c icns "$ICONSET" -o "$OUT"
    echo "Icon: $OUT"

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
    cp Mistty/Resources/AppIcon.icns "$APP/Contents/Resources/"
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
    cp Mistty/Resources/AppIcon.icns "$APP/Contents/Resources/"
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
