# @update github-release neovim/neovim
#
# The postPatch below is a workaround, not a version pin — read before removing.
#
# 0.12.5 changed how nvim binds its RPC socket: `uv_pipe_bind` became
# `uv_pipe_bind2(..., UV_PIPE_NO_TRUNCATE)` (src/nvim/event/socket.c). libuv
# used to silently truncate an over-long unix socket path; with NO_TRUNCATE it
# now returns EINVAL instead.
#
# nixpkgs' checkPhase runs `make functionaltest__treesitter`, and
# cmake/RunTests.cmake sets
#   TMPDIR = ${BUILD_DIR}/Xtest_tmpdir${TEST_SUFFIX}
# from which nvim derives each test server address as
#   $TMPDIR/nvim.<user>/<random>/T<n>.<pid>.<count>
# Inside the Nix darwin sandbox BUILD_DIR is
# /nix/var/nix/builds/nix-<pid>-<rand>/source/build, TEST_SUFFIX is
# "_treesitter", and the resulting address lands around 108 bytes — past
# macOS's 104-byte sun_path limit. Every test then dies before it starts with
#   nvim: Failed to --listen: invalid argument: "T1"
# which reads like a treesitter failure but is purely a path-length problem.
# (This never bit 0.12.4 because nixpkgs pins that version, so the overlay was
# a no-op and the binary came straight from the cache — the checkPhase had
# never actually run here.)
#
# Rehoming the test tmpdir from the cmake build dir to the sandbox root drops
# the 13 characters of "/source/build" and brings the address back under the
# limit, so the tests run for real rather than being switched off.
final: prev: {
  neovim-unwrapped = prev.neovim-unwrapped.overrideAttrs (oldAttrs: rec {
    version = "0.12.5";

    src = prev.fetchFromGitHub {
      owner = "neovim";
      repo = "neovim";
      rev = "v${version}";
      hash = "sha256-dpu2kncpm+2k+XR7qOEi4KeEy9a1E6X7kjf3s4AbcSo=";
    };

    postPatch = (oldAttrs.postPatch or "") + ''
      substituteInPlace cmake/RunTests.cmake \
        --replace-fail 'set(ENV{TMPDIR} "''${BUILD_DIR}/Xtest_tmpdir''${TEST_SUFFIX}")' \
                       'set(ENV{TMPDIR} "$ENV{TMPDIR}/Xtest_tmpdir''${TEST_SUFFIX}")'
    '';
  });
}
