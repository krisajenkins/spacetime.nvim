{
  description = "spacetime.nvim - Neovim plugin for SpacetimeDB";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/26.05";
    flake-utils.url = "github:numtide/flake-utils";
  };

  outputs = { self, nixpkgs, flake-utils }:
    flake-utils.lib.eachDefaultSystem (system:
      let
        pkgs = import nixpkgs {
          inherit system;
          config.allowUnfree = true;
          overlays = [
            (import ./overlays/spacetimedb.nix)
            (import ./overlays/neovim.nix)
          ];
        };
      in
      {
        devShells.default = pkgs.mkShell {
          buildInputs = with pkgs; [
            lua-language-server
            luajitPackages.luacheck
            stylua
            neovim
            spacetimedb
            curl
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
            echo ""
            echo "Run 'make' to run all checks and tests"
          '';
        };
      }
    );
}
