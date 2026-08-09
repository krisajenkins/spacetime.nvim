# @update github-release neovim/neovim
final: prev: {
  neovim-unwrapped = prev.neovim-unwrapped.overrideAttrs (oldAttrs: rec {
    version = "0.12.4";

    src = prev.fetchFromGitHub {
      owner = "neovim";
      repo = "neovim";
      rev = "v${version}";
      hash = "sha256-KSLFsrnoEOV712cnUtA8s4EoISp+ON36jslKxSvDthQ=";
    };
  });
}
