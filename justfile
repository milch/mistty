# Mistty — macOS terminal emulator built on libghostty

# Default recipe
default: build

# Re-render app icons from assets/AppIcon.svg.
# Produces both the base icon and a "DEV" variant (orange bottom banner)
# so debug builds are visually distinguishable from release in the Dock.
# Requires: magick (nix devshell), iconutil (macOS).
icon:
    #!/usr/bin/env bash
    set -euo pipefail
    SVG="assets/AppIcon.svg"
    OUT="Mistty/Resources/AppIcon.icns"
    OUT_DEV="Mistty/Resources/AppIcon-dev.icns"
    ICONSET="build/AppIcon.iconset"
    ICONSET_DEV="build/AppIcon-dev.iconset"
    rm -rf "$ICONSET" "$ICONSET_DEV"
    mkdir -p "$ICONSET" "$ICONSET_DEV"
    for spec in 16:icon_16x16.png 32:icon_16x16@2x.png 32:icon_32x32.png 64:icon_32x32@2x.png \
                128:icon_128x128.png 256:icon_128x128@2x.png 256:icon_256x256.png \
                512:icon_256x256@2x.png 512:icon_512x512.png 1024:icon_512x512@2x.png; do
      size=${spec%%:*}; name=${spec##*:}
      magick -background none "$SVG" -resize ${size}x${size} "$ICONSET/$name"
      # DEV variant: overlay an orange banner with white "DEV" text across the
      # bottom fifth. Text is illegible below ~32px but the orange still reads
      # as "not the release build" at small sizes.
      banner_h=$(awk "BEGIN {print int($size * 0.22)}")
      font_pt=$(awk "BEGIN {print int($size * 0.18)}")
      # Composite the banner on the base, then re-clip the result's alpha to
      # the base's alpha so the banner follows the bezel's rounded corners
      # instead of poking out to the square canvas edges.
      magick "$ICONSET/$name" \
        \( -size ${size}x${banner_h} -background "rgba(255,149,0,0.92)" \
           -gravity center -fill white -pointsize $font_pt \
           -font "/Library/Fonts/SF-Mono-Heavy.otf" label:DEV \) \
        -gravity south -compose Over -composite \
        \( "$ICONSET/$name" -alpha extract \) \
        -compose CopyOpacity -composite \
        "$ICONSET_DEV/$name"
    done
    iconutil -c icns "$ICONSET" -o "$OUT"
    iconutil -c icns "$ICONSET_DEV" -o "$OUT_DEV"
    echo "Icons: $OUT + $OUT_DEV"

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
    APP="build/Mistty-dev.app"
    rm -rf "$APP"
    mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
    cp .build/debug/Mistty "$APP/Contents/MacOS/Mistty"
    swift build --target MisttyCLI
    cp .build/debug/MisttyCLI "$APP/Contents/MacOS/mistty-cli"
    cp Mistty/Resources/Fonts/SymbolsNerdFontMono-Regular.ttf "$APP/Contents/Resources/"
    cp Mistty/Resources/Info.plist "$APP/Contents/"
    # Prefer the dev-variant icon so the Dock/Finder distinguishes dev from
    # release at a glance. Falls back to the base icon if the dev variant
    # hasn't been generated yet (first-time build before `just icon`).
    if [ -f Mistty/Resources/AppIcon-dev.icns ]; then
      cp Mistty/Resources/AppIcon-dev.icns "$APP/Contents/Resources/AppIcon.icns"
    else
      cp Mistty/Resources/AppIcon.icns "$APP/Contents/Resources/"
    fi
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
    cp Mistty/Resources/Fonts/SymbolsNerdFontMono-Regular.ttf "$APP/Contents/Resources/"
    cp Mistty/Resources/Info.plist "$APP/Contents/"
    cp Mistty/Resources/AppIcon.icns "$APP/Contents/Resources/"
    codesign -s - -f "$APP"
    echo "Bundled: $APP"

# Install to /Applications (debug)
install: bundle
    #!/usr/bin/env bash
    set -euo pipefail
    # Quit only the dev build so running a release copy isn't killed.
    osascript -e 'if application "/Applications/Mistty-dev.app" is running then tell application "/Applications/Mistty-dev.app" to quit' 2>/dev/null || true
    rm -rf /Applications/Mistty-dev.app
    cp -R build/Mistty-dev.app /Applications/Mistty-dev.app
    echo "Installed: /Applications/Mistty-dev.app"

# Install to /Applications (release)
install-release: bundle-release
    #!/usr/bin/env bash
    set -euo pipefail
    # Quit only the release build so a running dev copy isn't killed.
    osascript -e 'if application "/Applications/Mistty.app" is running then tell application "/Applications/Mistty.app" to quit' 2>/dev/null || true
    rm -rf /Applications/Mistty.app
    cp -R build/Mistty.app /Applications/Mistty.app
    echo "Installed: /Applications/Mistty.app (release)"

# Run the app (debug). Optionally from a worktree at .worktrees/<name>.
run worktree="":
    #!/usr/bin/env bash
    set -euo pipefail
    if [ -z "{{worktree}}" ]; then
      just install
    else
      DIR=".worktrees/{{worktree}}"
      if [ ! -d "$DIR" ]; then
        echo "Worktree not found: $DIR" >&2
        exit 1
      fi
      (cd "$DIR" && just install)
    fi
    open /Applications/Mistty-dev.app

# Run the app (release). Optionally from a worktree at .worktrees/<name>.
run-release worktree="":
    #!/usr/bin/env bash
    set -euo pipefail
    if [ -z "{{worktree}}" ]; then
      just install-release
    else
      DIR=".worktrees/{{worktree}}"
      if [ ! -d "$DIR" ]; then
        echo "Worktree not found: $DIR" >&2
        exit 1
      fi
      (cd "$DIR" && just install-release)
    fi
    open /Applications/Mistty.app

# Run tests
test:
    swift test

# Clean build artifacts
clean:
    swift package clean
    rm -rf build/

# Build libghostty from the vendored submodule (requires nix).
# On failure, prints a hint if the user is on Xcode 26.4+, because zig
# 0.15.2 (pinned by ghostty's build.zig.zon) can't link against that
# SDK and the raw error is a flood of "undefined symbol: _abort / …".
build-libghostty:
    #!/usr/bin/env bash
    if ! nix develop --command bash -c "cd vendor/ghostty && zig build -Dapp-runtime=none -Doptimize=ReleaseFast"; then
      xcode_version=$(xcodebuild -version 2>/dev/null | awk '/^Xcode/ {print $2}')
      if [ -n "$xcode_version" ]; then
        v=$(awk -F. '{print $1*100 + $2}' <<<"$xcode_version")
        if [ "$v" -ge 2604 ]; then
          echo "" >&2
          echo "Hint: Xcode $xcode_version detected. Zig 0.15.2 (pinned by upstream ghostty) can't" >&2
          echo "link against the Xcode 26.4+ macOS SDK — known upstream issue." >&2
          echo "Workarounds:" >&2
          echo "  - sudo xcode-select --switch /Applications/Xcode-26.3.app (or older)" >&2
          echo "  - build libghostty on another machine and copy" >&2
          echo "    vendor/ghostty/macos/GhosttyKit.xcframework" >&2
        fi
      fi
      exit 1
    fi

# Enter the nix dev shell
dev:
    nix develop

# Initialize submodules (first-time setup)
setup:
    git submodule update --init --recursive
    @echo "Now run 'just build-libghostty' to build libghostty"

# Set up a fresh git worktree: init the ghostty submodule and symlink the
# prebuilt GhosttyKit.xcframework from the main checkout so `swift build`
# can link without rebuilding libghostty per worktree.
setup-worktree:
    #!/usr/bin/env bash
    set -euo pipefail
    MAIN_WT=$(git worktree list --porcelain | awk '/^worktree / {print $2; exit}')
    if [ "$(pwd)" = "$MAIN_WT" ]; then
      echo "setup-worktree runs inside secondary worktrees only. Use 'just setup' in the main checkout."
      exit 1
    fi
    git submodule update --init vendor/ghostty
    XCF="vendor/ghostty/macos/GhosttyKit.xcframework"
    MAIN_XCF="$MAIN_WT/$XCF"
    if [ -e "$XCF" ]; then
      echo "xcframework already present at $XCF"
    elif [ -e "$MAIN_XCF" ]; then
      ln -s "$MAIN_XCF" "$XCF"
      echo "Symlinked $XCF -> $MAIN_XCF"
    else
      echo "Error: main checkout has no prebuilt xcframework at $MAIN_XCF"
      echo "Run 'just build-libghostty' in the main checkout first."
      exit 1
    fi
    echo "Worktree ready. Try: swift build"

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
