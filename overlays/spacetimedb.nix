# @update github-release clockworklabs/SpacetimeDB
# SpacetimeDB - distributed database with intelligent modules
#
# Installs the upstream release binaries rather than building from source.
# nixpkgs lags the release cadence badly (26.05 pins 2.2.0) and the source build
# is a large Rust workspace, so a from-source override would cost ~30 minutes on
# a cold CI runner. The release tarballs are a download.
#
# This mirrors ~/nix-kris/overlays/spacetimedb.nix, extended to every platform we
# build on: that overlay is aarch64-darwin only, but CI runs x86_64-linux. The
# aarch64-darwin URL and hash are identical to it, so a local `nix develop` is a
# store cache hit rather than a fresh download.
#
# To update to a new version:
# 1. Check the latest release:
#      curl -s https://api.github.com/repos/clockworklabs/SpacetimeDB/releases/latest | jq -r '.tag_name'
# 2. Bump `version` below (without the 'v' prefix).
# 3. Re-hash every platform (nix-prefetch-url caches into the store, so the
#    build that follows won't re-download):
#      for t in aarch64-apple-darwin x86_64-apple-darwin \
#               aarch64-unknown-linux-gnu x86_64-unknown-linux-gnu; do
#        h=$(nix-prefetch-url "https://github.com/clockworklabs/SpacetimeDB/releases/download/vVERSION/spacetime-$t.tar.gz")
#        echo "$t = $(nix hash convert --hash-algo sha256 --to sri "$h")"
#      done
# 4. Test: nix develop -c spacetime --version
#
# The tarball has no top-level directory; both binaries sit at the root:
#   - spacetimedb-cli (installed as 'spacetime', matching upstream)
#   - spacetimedb-standalone
#
# GitHub: https://github.com/clockworklabs/SpacetimeDB
# Releases: https://github.com/clockworklabs/SpacetimeDB/releases

final: prev:
let
  inherit (prev) lib stdenv;

  version = "2.8.0";

  # Nix system -> the Rust target triple naming its release asset, plus that
  # asset's hash. Windows is published too but is not a platform we support.
  targets = {
    aarch64-darwin = {
      triple = "aarch64-apple-darwin";
      hash = "sha256-d1EY/FjzukeMZB91gUcHYD+R6Po51tEuHVMnB1ZJqtE=";
    };
    x86_64-darwin = {
      triple = "x86_64-apple-darwin";
      hash = "sha256-uJ6Uz4yF0F17ikTT5xQZjEHBpSUJR3qU1gwR45Mx+dk=";
    };
    aarch64-linux = {
      triple = "aarch64-unknown-linux-gnu";
      hash = "sha256-vsKj7GaavbgwtpFQkVycLRwApcniIkvx8wiMvtxRSBg=";
    };
    x86_64-linux = {
      triple = "x86_64-unknown-linux-gnu";
      hash = "sha256-IKeWH+nOfHj9nosiyU/tiTN8obuKV6iWH+bn8iXyUzA=";
    };
  };

  system = stdenv.hostPlatform.system;

  target =
    targets.${system}
      or (throw "spacetimedb: no upstream release binary for ${system}");
in
{
  spacetimedb = stdenv.mkDerivation {
    pname = "spacetime";
    inherit version;

    src = prev.fetchurl {
      url = "https://github.com/clockworklabs/SpacetimeDB/releases/download/v${version}/spacetime-${target.triple}.tar.gz";
      inherit (target) hash;
    };

    # No subdirectory in the tarball; the binaries are at the root.
    sourceRoot = ".";

    # The Linux builds are ordinary dynamically-linked ELF binaries expecting a
    # FHS loader, so they need patching to run from the Nix store. Mach-O builds
    # need no equivalent.
    nativeBuildInputs = lib.optionals stdenv.hostPlatform.isLinux [
      prev.autoPatchelfHook
    ];

    buildInputs = lib.optionals stdenv.hostPlatform.isLinux [
      stdenv.cc.cc.lib
      prev.openssl
    ];

    installPhase = ''
      runHook preInstall

      mkdir -p $out/bin

      # Install the CLI binary as 'spacetime' (matching upstream's name)
      install -m755 spacetimedb-cli $out/bin/spacetime

      # Install the standalone server
      install -m755 spacetimedb-standalone $out/bin/spacetimedb-standalone

      runHook postInstall
    '';

    meta = {
      description = "SpacetimeDB CLI and standalone server - a distributed database with intelligent modules";
      homepage = "https://spacetimedb.com";
      # Business Source License 1.1 - converts to AGPL-3.0 on 2030-10-31
      license = lib.licenses.bsl11;
      platforms = builtins.attrNames targets;
      mainProgram = "spacetime";
      sourceProvenance = [ lib.sourceTypes.binaryNativeCode ];
    };
  };
}
