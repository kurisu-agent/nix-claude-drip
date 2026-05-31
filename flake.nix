{
  description = "claude-drip — always-fresh native Claude Code for nix: self-updating binary swap + statusline";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
  };

  outputs =
    { self, nixpkgs }:
    let
      systems = [
        "x86_64-linux"
        "aarch64-linux"
      ];
      forAllSystems = f: nixpkgs.lib.genAttrs systems f;

      mkLib = system: import ./lib { inherit nixpkgs system; };

      # The runnable CLIs for a system, wired against one shared updater
      # (mkUpdater derives its platform from the system).
      mkBins =
        system:
        let
          l = mkLib system;
          updater = l.mkUpdater { };
          updaterBin = "${updater}/bin/claude-update";
        in
        {
          claude-update = updater;
          claude = l.mkLauncher { inherit updaterBin; };
          claude-hint = l.mkHint { inherit updaterBin; };
          claude-statusline = l.mkStatusBin { inherit updaterBin; };
        };
    in
    {
      lib = forAllSystems mkLib;

      packages = forAllSystems (
        system:
        let
          pkgs = nixpkgs.legacyPackages.${system};
          bins = mkBins system;
        in
        bins
        // {
          # Everything on PATH from one `nix profile install`.
          default = pkgs.symlinkJoin {
            name = "claude-drip";
            paths = builtins.attrValues bins;
          };
        }
      );

      nixosModules.default = import ./nixos;

      # `nix flake check` builds every CLI — which runs shellcheck on each.
      checks = forAllSystems (system: mkBins system);

      formatter = forAllSystems (system: nixpkgs.legacyPackages.${system}.nixfmt-rfc-style);
    };
}
