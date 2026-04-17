{
  description = "Mistty — macOS terminal emulator built on libghostty";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixpkgs-unstable";
    flake-utils.url = "github:numtide/flake-utils";

    # Same Zig overlay used by Ghostty
    zig = {
      url = "github:mitchellh/zig-overlay";
      inputs = {
        nixpkgs.follows = "nixpkgs";
        flake-utils.follows = "flake-utils";
      };
    };
  };

  outputs = { self, nixpkgs, flake-utils, zig }:
    flake-utils.lib.eachDefaultSystem (system:
      let
        pkgs = nixpkgs.legacyPackages.${system};
        # Ghostty requires Zig 0.15.2 — keep in sync with vendor/ghostty/flake.nix
        zigPkg = zig.packages.${system}."0.15.2";
      in {
        devShells.default = pkgs.mkShell {
          name = "mistty-dev";

          # Swift is provided by Xcode — not included here
          buildInputs = [
            zigPkg
            pkgs.git
            pkgs.imagemagick   # icon recipe: SVG → PNG iconset
          ];

          shellHook = ''
            # Use system Xcode SDK, not Nix-provided one (same as Ghostty's devShell)
            unset SDKROOT
            unset DEVELOPER_DIR
            export PATH=$(echo "$PATH" | awk -v RS=: -v ORS=: '$0 !~ /xcrun/ || $0 == "/usr/bin" {print}' | sed 's/:$//')

            echo "Mistty dev environment"
            echo "Zig: $(zig version)"
          '';
        };
      });
}
