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
    just _copy-ghostty-resources "$APP"
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
    just _copy-ghostty-resources "$APP"
    codesign -s - -f "$APP"
    echo "Bundled: $APP"

# Copy libghostty's bundled resources (themes, shell-integration, terminfo)
# into the target `.app/Contents/Resources/`. Without this, a UI-launched
# Mistty has no `GHOSTTY_RESOURCES_DIR` inherited from a parent terminal and
# ghostty's sentinel climb (`Contents/Resources/terminfo/78/xterm-ghostty`)
# fails — so themes silently fall back to defaults and spawned shells get
# `TERM=xterm-256color` instead of `xterm-ghostty`. CLI launches from within
# Ghostty accidentally "worked" because they inherited the parent's env.
#
# Resolves the source against the main worktree so secondary worktrees that
# don't rebuild libghostty themselves (see `setup-worktree`) still find the
# files next to the shared xcframework.
[private]
_copy-ghostty-resources app:
    #!/usr/bin/env bash
    set -euo pipefail
    SHARE="vendor/ghostty/zig-out/share"
    if [ ! -d "$SHARE/ghostty" ] || [ ! -d "$SHARE/terminfo" ]; then
      MAIN_WT=$(git worktree list --porcelain | awk '/^worktree / {print $2; exit}')
      if [ -n "$MAIN_WT" ] && [ -d "$MAIN_WT/$SHARE/ghostty" ]; then
        SHARE="$MAIN_WT/$SHARE"
      else
        echo "Error: $SHARE/{ghostty,terminfo} missing. Run 'just build-libghostty' first." >&2
        exit 1
      fi
    fi
    cp -R "$SHARE/ghostty" "{{app}}/Contents/Resources/ghostty"
    cp -R "$SHARE/terminfo" "{{app}}/Contents/Resources/terminfo"

# Install to /Applications (debug)
install: bundle
    #!/usr/bin/env bash
    set -euo pipefail
    just _atomic-install build/Mistty-dev.app /Applications/Mistty-dev.app
    just _link-cli /Applications/Mistty-dev.app/Contents/MacOS/mistty-cli

# Install to /Applications (release)
install-release: bundle-release
    #!/usr/bin/env bash
    set -euo pipefail
    just _atomic-install build/Mistty.app /Applications/Mistty.app
    just _link-cli /Applications/Mistty.app/Contents/MacOS/mistty-cli

# Atomically swap a built `.app` into /Applications, surviving the
# common case where `just install[-release]` is invoked from a pane
# inside the very app being upgraded. Strategy:
#   1. cp the new bundle to `${dst}.new` while the live one is still
#      mounted — this is the heavy step.
#   2. If the destination is currently running, fork a detached helper
#      that polls until the running binary exits, then rm + mv the
#      staging bundle into place and relaunch. Without the detach the
#      shell hosting `just` dies along with the app it's quitting and
#      the rm/mv never runs.
#   3. If the destination isn't running, swap immediately.
[private]
_atomic-install src dst:
    #!/usr/bin/env bash
    set -euo pipefail
    DST="{{dst}}"
    SRC="{{src}}"
    NEW="${DST}.new"

    rm -rf "$NEW"
    cp -R "$SRC" "$NEW"

    if pgrep -fq "$DST/Contents/MacOS/" 2>/dev/null; then
      # `( ... & )` runs in a subshell so the helper detaches from this
      # script's job control; nohup + redirected stdio keeps it alive
      # when its grandparent shell dies along with the running app.
      (
        nohup bash -c "
          while pgrep -fq \"$DST/Contents/MacOS/\" 2>/dev/null; do
            sleep 0.1
          done
          sleep 0.5
          rm -rf \"$DST\"
          mv \"$NEW\" \"$DST\"
          open \"$DST\"
        " </dev/null >/dev/null 2>&1 &
      )
      osascript -e "tell application \"$DST\" to quit" 2>/dev/null || true
      echo "$DST running — quitting; detached helper will swap and relaunch."
    else
      rm -rf "$DST"
      mv "$NEW" "$DST"
      echo "Installed: $DST"
    fi

# Symlink ~/.local/bin/mistty-cli -> the app's bundled binary. Keeps the CLI
# reachable from shells whose startup scripts reset PATH (nix-darwin's
# set-environment, path_helper, etc.) and strip ghostty's appended
# Contents/MacOS. User-writable dir — no sudo. Prints a PATH hint if
# ~/.local/bin isn't already on the caller's PATH, since shells vary on
# whether that dir is included by default.
[private]
_link-cli target name="mistty-cli":
    #!/usr/bin/env bash
    set -euo pipefail
    BIN="$HOME/.local/bin"
    LINK="$BIN/{{name}}"
    mkdir -p "$BIN"
    if [ "$(readlink "$LINK" 2>/dev/null)" != "{{target}}" ]; then
      ln -sfn "{{target}}" "$LINK"
      echo "Linked: $LINK -> {{target}}"
    fi
    case ":$PATH:" in
      *":$BIN:"*) ;;
      *) echo "Hint: $BIN is not on your PATH. Add it to your shell config to use '{{name}}' directly." >&2 ;;
    esac

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

# Apply all patches under patches/ghostty/ to the vendored submodule. Idempotent
# (skips a patch if `git apply --check` fails, on the assumption it's already
# in). Run after `git submodule update`; `build-libghostty` runs this first.
patch-ghostty:
    #!/usr/bin/env bash
    set -euo pipefail
    shopt -s nullglob
    for p in patches/ghostty/*.patch; do
      if git -C vendor/ghostty apply --check "../../$p" >/dev/null 2>&1; then
        echo "Applying $p"
        git -C vendor/ghostty apply "../../$p"
      else
        echo "Skipping $p (already applied or does not apply)"
      fi
    done

# Build libghostty from the vendored submodule (requires nix).
# On failure, prints a hint if the user is on Xcode 26.4+, because zig
# 0.15.2 (pinned by ghostty's build.zig.zon) can't link against that
# SDK and the raw error is a flood of "undefined symbol: _abort / …".
build-libghostty: patch-ghostty
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
    # Share libghostty's bundled resources (themes, shell-integration,
    # terminfo) with the worktree. `just bundle` copies these into the .app
    # so a UI-launched Mistty can resolve its theme and spawn shells with
    # `TERM=xterm-ghostty` instead of falling back to xterm-256color.
    SHARE="vendor/ghostty/zig-out/share"
    MAIN_SHARE="$MAIN_WT/$SHARE"
    if [ -e "$SHARE" ]; then
      echo "share dir already present at $SHARE"
    elif [ -e "$MAIN_SHARE" ]; then
      mkdir -p "$(dirname "$SHARE")"
      ln -s "$MAIN_SHARE" "$SHARE"
      echo "Symlinked $SHARE -> $MAIN_SHARE"
    else
      echo "Warning: main checkout has no $MAIN_SHARE — 'just bundle' in this worktree will fail until you run 'just build-libghostty' in the main checkout." >&2
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
