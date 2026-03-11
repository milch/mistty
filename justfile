# Mistty — macOS terminal emulator built on libghostty

# Default recipe
default: build

# Build the app (debug)
build:
    swift build

# Build the app (release)
build-release:
    swift build -c release

# Run the app (debug build)
run: build
    .build/debug/Mistty

# Run tests
test:
    swift test

# Clean build artifacts
clean:
    swift package clean

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
