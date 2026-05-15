{
  description = "Quickly update gitignore";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    flake-utils.url = "github:numtide/flake-utils";
  };

  outputs = { self, nixpkgs, flake-utils }:
    flake-utils.lib.eachDefaultSystem (system:
      let
        pkgs = nixpkgs.legacyPackages.${system};

        # Single source of truth for the version is build.zig.zon; extract it
        # here so the flake can't drift. CI enforces the same invariant across
        # all distribution manifests — see docs/RELEASING.md.
        zonText = builtins.readFile ./build.zig.zon;
        versionMatch = builtins.match ''.*\.version = "([^"]+)".*'' zonText;
        version = if versionMatch == null
          then throw "flake.nix: could not parse .version from build.zig.zon"
          else builtins.head versionMatch;

        zignore = pkgs.stdenv.mkDerivation {
          pname = "zignore";
          inherit version;
          src = ./.;

          nativeBuildInputs = [ pkgs.zig pkgs.makeWrapper ];

          # The zig setup-hook auto-wires configure/build/install. We point
          # the global cache at the sandbox so it can't reach the network.
          # No external zig deps in this project (templates are vendored).
          preConfigure = ''
            export ZIG_GLOBAL_CACHE_DIR="$TMPDIR/zig-cache"
            mkdir -p "$ZIG_GLOBAL_CACHE_DIR"
          '';

          # Runtime dep: zignore shells out to `git`.
          postInstall = ''
            wrapProgram "$out/bin/zignore" \
              --prefix PATH : ${pkgs.lib.makeBinPath [ pkgs.git ]}
          '';

          meta = {
            description = "Quickly update gitignore";
            mainProgram = "zignore";
            platforms = pkgs.lib.platforms.unix;
          };
        };
      in {
        packages.default = zignore;
        packages.zignore = zignore;

        apps.default = {
          type = "app";
          program = "${zignore}/bin/zignore";
        };

        devShells.default = pkgs.mkShell {
          packages = [
            pkgs.zig
            pkgs.zls          # language server
            pkgs.git          # runtime dep of zignore
            pkgs.gnumake      # Makefile uses GNU-make features
            pkgs.gnutar       # `make release-build` needs GNU tar flags
            pkgs.cosign       # release.yml signs SHA256SUMS — handy for local verify
            pkgs.fzf          # optional picker for `zignore add`
            pkgs.television   # optional picker (`tv`) for `zignore add`
          ];

          shellHook = ''
            echo "zignore dev shell — zig $(zig version)"
            echo "  zig build              build the binary"
            echo "  zig build test         run unit tests"
            echo "  zig build run -- …     exercise the CLI"
            echo "  nix build              build the wrapped package"
            echo "  nix run -- …           run the wrapped binary"
            echo "  make release-build     rehearse the release matrix locally"
            echo "  make repro TAG=vX.Y.Z  verify a published release"
          '';
        };

        formatter = pkgs.nixpkgs-fmt;
      });
}
