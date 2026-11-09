{
  description = "spacetime.nvim - Neovim plugin for SpacetimeDB";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/26.05";
    flake-utils.url = "github:numtide/flake-utils";
    spacetimedb.url = "github:krisajenkins/spacetimedb-nix";
  };

  outputs = { self, nixpkgs, flake-utils, spacetimedb }:
    flake-utils.lib.eachDefaultSystem (system:
      let
        pkgs = import nixpkgs {
          inherit system;
          config.allowUnfree = true;
          overlays = [
            (import ./overlays/neovim.nix)
          ];
        };
      in
      {
        devShells.default = pkgs.mkShell {
          buildInputs = with pkgs; [
            spacetimedb.packages.${system}.default
            lua-language-server
            luajitPackages.luacheck
            stylua
            neovim
            curl
            vhs # records scripts/record-demo.tape into demo.gif
            ncurses # tic, for the demo's semicolon-truecolor terminfo
          ];

          shellHook = ''
            echo "spacetime.nvim development environment"
            echo "Available tools:"
            echo "  - lua-language-server (type checking)"
            echo "  - luacheck (static analysis)"
            echo "  - stylua (code formatting)"
            echo "  - neovim (testing)"
            echo "  - spacetime (SpacetimeDB CLI)"
            echo "  - curl (HTTP transport)"
            echo "  - vhs (demo recording: make demo)"
            echo ""
            echo "Run 'make' to run all checks and tests"
          '';
        };
      }
    );
}
