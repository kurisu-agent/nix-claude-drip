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

    # herdr — the terminal workspace manager for AI coding agents. Pinned HERE,
    # not by each consumer, because herdr is agent-workstation furniture of the
    # same family as `claude`, `yolo` and the statusline: its default_shell IS
    # `yolo`, and its claude integration hooks are what herdr-drip installs. One
    # authority for the version means a circuit's host and its kart guests cannot
    # drift a herdr apart from each other (they used to, via two separate pins).
    #
    # Exposed as `packages.<system>.herdr` only — deliberately NOT folded into
    # `packages.default`, so `nix profile install` still gets just the Claude
    # CLIs, and deliberately NOT a check, so herdr's rust+zig compile stays out
    # of this flake's fast `nix flake check`. Public, so unlike gumbo it adds no
    # credential requirement. Bump with `nix flake update herdr`.
    herdr = {
      url = "github:herdrdev/herdr";
      inputs.nixpkgs.follows = "nixpkgs";
    };

    # herdr-drip — our herdr plugins, curated config, and the two NixOS
    # modules this module composes: claude-agent-state (keeps herdr's
    # SessionStart hook alive across the settings.json overwrite THIS module
    # performs) and plugins (drip plugin installs pinned to herdr-drip's own
    # rev). Carried here for the same one-knob reason as gumbo:
    # `services.claude-code.herdr.enable = true` gets the binary, the hook
    # keepalive and the plugins together. Public, no credential requirement,
    # and enable-gated, so `nix flake check` stays as fast as before. Bump
    # with `nix flake update herdr-drip`.
    herdr-drip = {
      url = "github:kurisu-agent/herdr-drip";
      inputs.nixpkgs.follows = "nixpkgs";
    };
  };

  outputs =
    {
      self,
      nixpkgs,
      gumbo,
      herdr,
      herdr-drip,
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
          # Everything on PATH from one `nix profile install`. Built from `bins`
          # alone, so the herdr below stays out of it — see the input's comment.
          default = pkgs.symlinkJoin {
            name = "claude-drip";
            paths = builtins.attrValues bins;
          };

          # The pinned herdr, forwarded so consumers take the version from this
          # flake rather than pinning their own. nix-env re-exports it, and a
          # circuit reaches it from there for both its host and its kart guests.
          herdr = herdr.packages.${system}.default;
        }
      );

      # The module takes the composed flakes as its first argument: gumbo so
      # it can import gumbo's own nixosModule and default the client's
      # package/addr off the daemon's; herdr + herdr-drip so one
      # `herdr.enable = true` gets the binary, the hook keepalive and the
      # plugins. Consumers still import `nixosModules.default` unchanged.
      nixosModules.default = import ./nixos {
        gumboFlake = gumbo;
        herdrFlake = herdr;
        herdrDripFlake = herdr-drip;
      };

      # The host-side pull-through cache for the release channel. Deliberately
      # NOT imported by nixosModules.default: a client machine has no reason to
      # grow an nginx option surface it will never use, and a cache host has no
      # reason to run Claude Code. Import it where you want the cache, then
      # point the clients' `releaseBase` at it.
      nixosModules.cache = import ./nixos/cache.nix;

      # `nix flake check` builds every CLI — which runs shellcheck on each —
      # plus the statusline segment's own behaviour check (stubbed gumbo, so no
      # gumbo build), and on x86_64 (the only system gumbo builds for) evaluates
      # the gumbo wiring.
      checks = forAllSystems (
        system:
        mkBins system
        // {
          gumbo-segment = import ./lib/gumbo-segment-check.nix { inherit nixpkgs system; };
        }
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
