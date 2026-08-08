{
  description = "claude-drip — always-fresh native Claude Code for nix: self-updating binary swap + statusline";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";

    # gumbo — the multi-account Claude Code gateway `services.claude-code.gumbo`
    # routes at. Carried as an input rather than left to the consumer so that one
    # `gumbo.enable = true` gets BOTH halves: the client wiring here and gumbo's
    # own `services.gumbo` daemon, which this module imports and turns on.
    #
    # kurisu-agent/gumbo is PRIVATE, so evaluating this flake — or anything that
    # pins it — needs github credentials (`access-tokens` in nix.conf, or a
    # netrc). That is the price of the one-knob wiring; a consumer without access
    # can `inputs.nix-claude-drip.inputs.gumbo.follows = ...` it away, at the cost
    # of having to supply `services.claude-code.gumbo.package` themselves.
    gumbo = {
      url = "github:kurisu-agent/gumbo";
      inputs.nixpkgs.follows = "nixpkgs";
    };
  };

  outputs =
    {
      self,
      nixpkgs,
      gumbo,
    }:
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

      # The module takes the gumbo flake as its first argument so it can import
      # gumbo's own nixosModule and default the client's package/addr off the
      # daemon's. Consumers still import `nixosModules.default` unchanged.
      nixosModules.default = import ./nixos gumbo;

      # The host-side pull-through cache for the release channel. Deliberately
      # NOT imported by nixosModules.default: a client machine has no reason to
      # grow an nginx option surface it will never use, and a cache host has no
      # reason to run Claude Code. Import it where you want the cache, then
      # point the clients' `releaseBase` at it.
      nixosModules.cache = import ./nixos/cache.nix;

      # `nix flake check` builds every CLI — which runs shellcheck on each — and
      # on x86_64 (the only system gumbo builds for) evaluates the gumbo wiring.
      checks = forAllSystems (
        system:
        mkBins system
        // nixpkgs.lib.optionalAttrs (system == "x86_64-linux") {
          gumbo-wiring = import ./nixos/gumbo-wiring-check.nix {
            inherit nixpkgs system;
            module = self.nixosModules.default;
          };
        }
      );

      formatter = forAllSystems (system: nixpkgs.legacyPackages.${system}.nixfmt-rfc-style);
    };
}
