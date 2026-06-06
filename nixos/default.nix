# claude-drip NixOS module. Puts the self-updating `claude` launcher on
# PATH, activates ~/.claude/settings.json, enables nix-ld (the native binary
# is a foreign glibc ELF), and optionally schedules a per-user systemd timer
# so the binary is refreshed even between sessions. On non-NixOS hosts (e.g.
# glibc devcontainers) consume the flake *package* instead — the binary runs
# on the system glibc with no module and no nix-ld.
{
  config,
  lib,
  pkgs,
  ...
}:

let
  cfg = config.services.claude-code;

  # A "light*" Claude theme drives the Latte statusline flavour; everything
  # else (incl. theme = null → Claude's dark default) stays Mocha.
  paletteVariant = if cfg.theme != null && lib.hasPrefix "light" cfg.theme then "latte" else "mocha";

  claudeLib = import ../lib/claude.nix {
    inherit pkgs lib;
    palette = import ../lib/palette.nix {
      variant = paletteVariant;
      inherit (cfg.statusLine) paletteOverride;
    };
  };

  updater = claudeLib.mkUpdater {
    inherit (cfg) channel pinVersion;
  };
  updaterBin = "${updater}/bin/claude-update";

  commonArgs = {
    inherit updaterBin;
    inherit (cfg) checkInterval;
    autoCheck = cfg.autoUpdate;
  };

  launcher = claudeLib.mkLauncher (commonArgs // { inherit (cfg) hideAccount autoTrust autoOnboard; });
  hint = claudeLib.mkHint commonArgs;

  # Curated defaults (from the shared lib) layered UNDER cfg.settings, then
  # the dedicated `theme` knob on top (so `services.claude-code.theme` wins
  # over a `settings.theme` and stays in sync with the statusline flavour).
  mergedSettings =
    lib.recursiveUpdate (lib.optionalAttrs cfg.opinionatedDefaults claudeLib.opinionatedDefaults) cfg.settings
    // lib.optionalAttrs (cfg.theme != null) { theme = cfg.theme; };

  statusline = claudeLib.mkStatusBin (commonArgs // { effortLevel = mergedSettings.effortLevel or null; });

  manageSettings = cfg.statusLine.enable || mergedSettings != { };

  statusLineCommand =
    if !cfg.statusLine.enable then
      null
    else if cfg.statusLine.command != null then
      toString cfg.statusLine.command
    else
      "${statusline}/bin/claude-statusline";

  settingsFile = claudeLib.mkSettings {
    settings = mergedSettings;
    inherit statusLineCommand;
  };

  mkUserUnits = f: lib.listToAttrs (map (u: lib.nameValuePair "claude-drip-update-${u}" (f u)) cfg.users);
in
{
  options.services.claude-code = {
    enable = lib.mkEnableOption "claude-drip — self-updating native Claude Code";

    channel = lib.mkOption {
      type = lib.types.enum [
        "latest"
        "stable"
      ];
      default = "latest";
      description = ''
        Anthropic release channel the updater tracks. "latest" follows every
        release (Claude Code ships ~daily); "stable" lags on vetted builds.
        Ignored when `pinVersion` is set.
      '';
    };

    pinVersion = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = null;
      example = "2.1.158";
      description = "Freeze to an exact version; the updater won't move past it.";
    };

    autoUpdate = lib.mkOption {
      type = lib.types.bool;
      default = true;
      description = ''
        Fire the gated background update check (from the launcher, statusline,
        hint, and timer). When false, nothing polls automatically — run
        `claude-update` by hand. The statusline still shows already-staged
        state.
      '';
    };

    checkInterval = lib.mkOption {
      type = lib.types.ints.positive;
      default = 3600;
      description = "Minimum seconds between background update checks (shared across all triggers).";
    };

    theme = lib.mkOption {
      type = lib.types.nullOr (
        lib.types.enum [
          "dark"
          "light"
          "dark-daltonized"
          "light-daltonized"
          "dark-ansi"
          "light-ansi"
        ]
      );
      default = null;
      example = "light";
      description = ''
        Claude Code's own UI theme, written to settings.json's `theme` key.
        null leaves it unset (Claude defaults to dark). Any `light*` value
        also flips the built-in statusline to the Catppuccin Latte flavour
        so its colours stay legible on a light terminal; `dark*`/null keep
        the Mocha statusline.
      '';
    };

    statusLine = {
      enable = lib.mkOption {
        type = lib.types.bool;
        default = true;
        description = "Wire claude-drip's statusline into settings.json.";
      };
      command = lib.mkOption {
        type = lib.types.nullOr (lib.types.either lib.types.str lib.types.path);
        default = null;
        example = lib.literalExpression "./my-statusline.sh";
        description = ''
          Full statusline override — a command string or script path written
          verbatim into settings.json's statusLine.command. Pair with
          `claude-hint` to keep the update indicator. null = built-in.
        '';
      };
      paletteOverride = lib.mkOption {
        type = lib.types.attrsOf lib.types.str;
        default = { };
        example = {
          accent = "#FF0099";
        };
        description = "Re-tint the built-in statusline (accent / branch / success / warning / error).";
      };
    };

    opinionatedDefaults = lib.mkOption {
      type = lib.types.bool;
      default = true;
      description = ''
        Layer claude-drip's curated settings.json defaults UNDER your
        `settings` (which override them):
          effortLevel = "high";
          skipDangerousModePermissionPrompt = true;
          terminalProgressBarEnabled = true;          # OSC 9;4 terminal progress
          env.CLAUDE_CODE_EXPERIMENTAL_AGENT_TEAMS = "1";
          env.CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC = "1";  # telemetry/Sentry/feedback/surveys off
        Set false for a clean slate.
      '';
    };

    settings = lib.mkOption {
      type = with lib.types; attrsOf anything;
      default = { };
      description = ''
        Deep-merged into ~/.claude/settings.json, on top of
        `opinionatedDefaults` and under the module-owned `statusLine` (which
        always wins). Your keys (incl. env) survive. `effortLevel` here also
        drives the statusline glyph.
      '';
    };

    yoloAlias = lib.mkOption {
      type = lib.types.bool;
      default = true;
      description = "Define `alias yolo='claude --dangerously-skip-permissions'`.";
    };

    hideAccount = lib.mkOption {
      type = lib.types.bool;
      default = true;
      description = ''
        Export `IS_DEMO=1` from the launcher, hiding your account email + org
        on the Claude startup banner. Note `IS_DEMO` also suppresses the
        workspace-trust dialog, which would otherwise leave the statusline
        "skipped" with no way to accept — so keep `autoTrust` on alongside
        this. Set false to show the account.
      '';
    };

    autoTrust = lib.mkOption {
      type = lib.types.bool;
      default = true;
      description = ''
        Pre-mark each launch directory as trusted
        (`projects.<cwd>.hasTrustDialogAccepted = true` in ~/.claude.json)
        so the statusline + hooks run without the trust dialog. Required for
        the statusline to work when `hideAccount` (IS_DEMO) suppresses that
        dialog. Security note: this trusts every directory you run `claude`
        from — consistent with the bypass-permissions posture, but set false
        if you want Claude's per-directory trust gate enforced.
      '';
    };

    autoOnboard = lib.mkOption {
      type = lib.types.bool;
      default = true;
      description = ''
        On first launch, mark Claude's onboarding complete in ~/.claude.json
        (`hasCompletedOnboarding = true` + `lastOnboardingVersion`) if it isn't
        already. Claude's interactive first-run flow prompts for login even
        when credentials are present, which stalls an automated/headless launch;
        this seeds past it so `claude` drops straight into the prompt. Write-once
        (skips when onboarding is already marked done). Set false to keep the
        normal first-run onboarding.
      '';
    };

    installUpdateCli = lib.mkOption {
      type = lib.types.bool;
      default = true;
      description = "Put `claude-update` on PATH for manual / forced updates.";
    };

    updateTimer = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = ''
        Schedule a per-user systemd timer that refreshes the binary every
        `checkInterval`, independent of whether Claude is running — so it's
        already fresh before you open a session. Requires `users`.
      '';
    };

    users = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [ ];
      example = [ "alice" ];
      description = "Users the `updateTimer` runs for (each updates their own ~/.claude/cc).";
    };
  };

  config = lib.mkIf cfg.enable {
    # The native binary is a foreign glibc ELF; nix-ld gives NixOS a loader.
    programs.nix-ld.enable = true;
    programs.nix-ld.libraries = with pkgs; [
      stdenv.cc.cc.lib
      zlib
    ];

    environment.systemPackages = [
      launcher
      hint
    ]
    ++ lib.optional cfg.installUpdateCli updater;

    system.userActivationScripts = lib.mkIf manageSettings {
      claudeDripSettings.text = ''
        mkdir -p "$HOME/.claude"
        install -m 0644 ${settingsFile} "$HOME/.claude/settings.json"
      '';
    };

    environment.interactiveShellInit = lib.mkIf cfg.yoloAlias ''
      alias yolo='claude --dangerously-skip-permissions'
    '';

    systemd.services = lib.mkIf (cfg.updateTimer && cfg.autoUpdate) (
      mkUserUnits (u: {
        description = "claude-drip: refresh Claude Code for ${u}";
        after = [ "network-online.target" ];
        wants = [ "network-online.target" ];
        serviceConfig = {
          Type = "oneshot";
          User = u;
          Environment = "HOME=${config.users.users.${u}.home}";
        };
        script = updaterBin;
      })
    );

    systemd.timers = lib.mkIf (cfg.updateTimer && cfg.autoUpdate) (
      mkUserUnits (u: {
        description = "claude-drip: refresh Claude Code for ${u}";
        wantedBy = [ "timers.target" ];
        timerConfig = {
          OnBootSec = "2min";
          OnUnitActiveSec = "${toString cfg.checkInterval}s";
          Persistent = true;
        };
      })
    );

    assertions = [
      {
        assertion = !cfg.updateTimer || cfg.users != [ ];
        message = "services.claude-code.updateTimer requires services.claude-code.users to be non-empty.";
      }
    ];
  };
}
