{
  description = "kleis, Sophia's lock provider: pinned development shell (niltempus n002, stage 1)";

  # One reviewed nixpkgs revision: Nim 2.2.12 (the reviewed version),
  # nimble 0.24.1, nph 0.7.0 and gcc 14.4.0.
  inputs.nixpkgs.url = "github:NixOS/nixpkgs/c59305bab2065cfecc4944690d9eedbb56f3a9fa";

  outputs = { self, nixpkgs }:
    let
      system = "x86_64-linux";
      pkgs = nixpkgs.legacyPackages.${system};
      lib = pkgs.lib;

      # The reviewed dependency manifest (niltempus, sha256 d7d51a85...) and the
      # upstream revisions it records. Each package is rebuilt from that
      # source and must match the manifest file for file.
      manifest = ./nix/kleis.nim-deps;
      reviewed = {
        bigints = {
          dir = "bigints-1.0.0-d7aee76dba84419721566fd5413a02cca231a806";
          src = pkgs.fetchFromGitHub {
            owner = "nim-lang";
            repo = "bigints";
            rev = "d843ecfe1e2a62c3b0e29d211df09763da408cac";
            hash = "sha256-dwA2T/PLtmihZun1l39RYIMt5/EpHf2ia6GM3ghJtnY=";
          };
        };
        graphemes = {
          dir = "graphemes-0.12.0-5a12349aea7c9682c87a086989a8afe7c8ade36b";
          src = pkgs.fetchFromGitHub {
            owner = "nitely";
            repo = "nim-graphemes";
            rev = "cc868c314ced482ed88dca2b470aa019480ce4c9";
            hash = "sha256-g8P5wkSZglyNZHax+F6ZqLre02fxunAaMK48CtRVofY=";
          };
        };
        nimkdl = {
          dir = "nimkdl-2.1.0-7d7e1e14205fb29c301af77414d2a617e6c755bb";
          src = pkgs.fetchFromGitHub {
            owner = "greenm01";
            repo = "nimkdl";
            rev = "4755e537a848e5f91465ccb314013fc0a7ce7c2f";
            hash = "sha256-6ug30C2GpOef486Lin3lAS9TCXxkXrYBYOYLNGEWLwI=";
          };
        };
        unicodedb = {
          dir = "unicodedb-0.13.0-5c5fc0c8a83d270aca74fe41d33158e9042bb91a";
          src = pkgs.fetchFromGitHub {
            owner = "nitely";
            repo = "nim-unicodedb";
            rev = "15c5e25e2a49a924bc97647481ff50125bba2c76";
            hash = "sha256-0khAhu84SI+/noc0SzQggH2NGgZ9FMqu1ASq4nWtRo8=";
          };
        };
      };

      # Nimble reads its package registry before running any task, even
      # offline with every dependency installed; nimble 0.24 downloads it
      # otherwise. One pinned registry commit makes that lookup offline and
      # deterministic.
      registry = pkgs.fetchFromGitHub {
        owner = "nim-lang";
        repo = "packages";
        rev = "09f05a91e9fc09b3e4626aa4d8f9a067716552ed";
        hash = "sha256-dB/ntRX4nIhAXSlW5DAzdPiNLdO+T1020HVZ4JH0eC4=";
      };

      nimPackage = name: p:
        pkgs.runCommand p.dir { } ''
          ${pkgs.bash}/bin/bash ${./nix/install-reviewed-package.sh} \
            ${manifest} ${name} ${p.src} ${./nix/nimblemeta}/${name}.json $out
        '';

      # The Nimble package store the reviewed build used, as ~/.nimble/pkgs2.
      nimPackages = pkgs.linkFarm "kleis-nim-packages"
        (lib.mapAttrsToList (name: p: { name = p.dir; path = nimPackage name p; }) reviewed);
    in
    {
      packages.${system}.nim-packages = nimPackages;

      # Tools and environment only: this shell gives no filesystem, device or
      # network isolation. The bwrap-isolated product build stays the gate.
      devShells.${system}.default = pkgs.mkShell.override { stdenv = pkgs.gcc14Stdenv; } {
        packages = [ pkgs.nim pkgs.nimble pkgs.nph pkgs.git ];
        shellHook = ''
          export HOME="$(mktemp -d "''${TMPDIR:-/tmp}/kleis-nix-home.XXXXXXXX")"
          mkdir -p "$HOME/.nimble/pkgs2"
          cp -rL ${nimPackages}/. "$HOME/.nimble/pkgs2/"
          cp ${registry}/packages.json "$HOME/.nimble/packages_official.json"
          chmod -R u+w "$HOME/.nimble"
        '';
      };
    };
}
