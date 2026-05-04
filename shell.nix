{ pkgs, hspkgs }:
hspkgs.shellFor {
  packages = p: [ p.todou ];
  buildInputs = [
    hspkgs.cabal-install
    hspkgs.haskell-language-server
    hspkgs.hlint
    hspkgs.cabal2nix
    hspkgs.eventlog2html
    hspkgs.fast-tags
    hspkgs.graphmod
    pkgs.ghcid
    pkgs.bashInteractive
    pkgs.upx
    pkgs.zstd
    pkgs.zlib
    pkgs.pkg-config
    pkgs.concurrently
    pkgs.nodePackages.typescript
  ];

  shellHook = ''
    export LD_LIBRARY_PATH="${pkgs.bzip2}/lib:$LD_LIBRARY_PATH"
  '';
}
