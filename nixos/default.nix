# claude-drip NixOS module. Puts the self-updating `claude` launcher on
# PATH, installs ~/.claude/settings.json (by two deliberately redundant
# paths — see the settings units in `config`), enables nix-ld (the native
# binary is a foreign glibc ELF), and optionally schedules a per-user systemd
# timer so the binary is refreshed even between sessions, or fetches it once
# at boot. On non-NixOS hosts (e.g. glibc devcontainers) consume the flake
# *package* instead — the binary runs on the system glibc with no module and
# no nix-ld.
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
    variant = paletteVariant;
    palette = import ../lib/palette.nix {
      variant = paletteVariant;
      inherit (cfg.statusLine) paletteOverride;
    };
  };

  updater = claudeLib.mkUpdater {
    inherit (cfg) channel pinVersion releaseBase;
  };
  updaterBin = "${updater}/bin/claude-update";

  commonArgs = {
    inherit updaterBin;
    inherit (cfg) checkInterval;
    autoCheck = cfg.autoUpdate;
  };

  launcher = claudeLib.mkLauncher (
    commonArgs // { inherit (cfg) hideAccount autoTrust autoOnboard; }
  );
  hint = claudeLib.mkHint commonArgs;

  # beads is a two-part install whose parts only work together: the plugin's
  # SessionStart/PreCompact hooks run `bd prime`, which needs the CLI on PATH,
  # and the CLI without the plugin leaves Claude never primed. So one knob
  # ships both — and it lives here rather than in the shared
  # opinionatedDefaults because a settings-only consumer (mkSettings outside
  # this module) has no way to put `bd` on PATH alongside.
  beadsSettings = lib.optionalAttrs cfg.beads {
    extraKnownMarketplaces.beads-marketplace.source = {
      source = "github";
      repo = "gastownhall/beads";
    };
    enabledPlugins."beads@beads-marketplace" = true;
  };

  # The dedicated plugin knobs compile to plain settings.json keys, layered
  # between the curated defaults and cfg.settings — additive over the default
  # plugins, and still vetoable per key from `settings.enabledPlugins`.
  pluginSettings = lib.recursiveUpdate beadsSettings (
    lib.optionalAttrs (cfg.marketplaces != { }) { extraKnownMarketplaces = cfg.marketplaces; }
    // lib.optionalAttrs (cfg.plugins != [ ]) { enabledPlugins = lib.genAttrs cfg.plugins (_: true); }
  );

  # Curated defaults (from the shared lib) layered UNDER cfg.settings, then
  # the dedicated `theme` knob on top (so `services.claude-code.theme` wins
  # over a `settings.theme` and stays in sync with the statusline flavour).
  mergedSettings =
    lib.recursiveUpdate (lib.recursiveUpdate (lib.optionalAttrs cfg.opinionatedDefaults claudeLib.opinionatedDefaults) pluginSettings) cfg.settings
    // lib.optionalAttrs (cfg.theme != null) { theme = cfg.theme; };

  statusline = claudeLib.mkStatusBin (
    commonArgs // { effortLevel = mergedSettings.effortLevel or null; }
  );

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
    inherit (cfg.statusLine) refreshInterval;
  };

  # One unit per name in `users`, named claude-drip-<kind>-<user>. The kind is
  # a parameter rather than baked in because four different units share this
  # shape (update service, its timer, the settings installer, the boot
  # prefetch) — and because a timer must be named after the service it
  # triggers, so the update service and the update timer have to agree on it.
  mkUserUnits =
    kind: f: lib.listToAttrs (map (u: lib.nameValuePair "claude-drip-${kind}-${u}" (f u)) cfg.users);
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

    releaseBase = lib.mkOption {
      type = lib.types.str;
      default = "https://downloads.claude.ai/claude-code-releases";
      example = "http://mirror.example.net:8099/claude-code-releases";
      description = ''
        Root URL the updater reads the release channel from — the channel
        pointer (`<base>/<channel>`), the per-version manifest
        (`<base>/<version>/manifest.json`) and the binary itself
        (`<base>/<version>/<platform>/claude`). Point it at a mirror when you
        want the ~262 MiB binary fetched once for a LAN full of machines, or
        when the hosts doing the updating can't reach the internet directly.
        `services.claude-code-cache` (the sibling module in this flake) serves
        exactly this layout. The updater still checks the binary's sha256
        against the manifest, which catches a truncated or corrupted mirror —
        but the manifest comes from the same base, so this is an integrity
        check on the transfer, not a reason to trust an untrusted mirror.
      '';
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
      refreshInterval = lib.mkOption {
        type = lib.types.nullOr lib.types.ints.positive;
        default = 1;
        example = 3;
        description = ''
          Seconds between statusline re-renders, written to settings.json's
          `statusLine.refreshInterval`. null omits the key and leaves Claude's
          own cadence alone.

          The default of 1 exists for the update indicator. Without it Claude
          re-runs the statusline only on conversation events — and those go
          quiet exactly when the indicator has something to say, because a
          background download runs while you sit reading Claude's last answer.
          The download percentage would then freeze at whatever value the last
          keystroke happened to catch, and a finished update would keep
          claiming to be downloading until you typed again.

          Hazard: a statusline command that takes longer than the interval is
          aborted by the next tick and renders NOTHING, blanking the row
          entirely — so this is a floor on how fast your command must be, not
          just a polling rate. If you set a slow custom `statusLine.command`
          (one that shells out to the network, say), raise this above its
          worst-case runtime or set it to null.
        '';
      };
    };

    opinionatedDefaults = lib.mkOption {
      type = lib.types.bool;
      default = true;
      description = ''
        Layer claude-drip's curated settings.json defaults UNDER your
        `settings` (which override them):
          model = "claude-fable-5";
          effortLevel = "xhigh";
          tui = "fullscreen";
          skipDangerousModePermissionPrompt = true;
          disableClaudeAiConnectors = true;           # no claude.ai MCP connectors
          terminalProgressBarEnabled = true;          # OSC 9;4 terminal progress
          env.CLAUDE_CODE_EXPERIMENTAL_AGENT_TEAMS = "1";
          env.CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC = "1";  # telemetry/Sentry/feedback/surveys off
          env.CLAUDE_CODE_NO_FLICKER = "1";
          extraKnownMarketplaces.claude-plugins-official = ...;  # official Anthropic marketplace
          enabledPlugins."skill-creator@claude-plugins-official" = true;
          enabledPlugins."feature-dev@claude-plugins-official" = true;
        The plugin content is fetched and refreshed by Claude Code itself
        under ~/.claude/plugins — only the declaration is nix-managed.
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

    plugins = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [ ];
      example = [ "commit-commands@claude-plugins-official" ];
      description = ''
        Extra Claude Code plugins, each as a `"<plugin>@<marketplace>"`
        string, written to settings.json's `enabledPlugins` on top of the
        opinionated defaults (skill-creator and feature-dev from the official
        Anthropic marketplace). Only the declaration lives in nix: Claude Code
        fetches the plugin content itself at runtime into ~/.claude/plugins,
        so skills stay current independently of your flake pins and reach
        every project the user opens. Veto a default per key via
        `settings.enabledPlugins."<plugin>@<marketplace>" = false`, or set
        `opinionatedDefaults = false` for none at all.
      '';
    };

    marketplaces = lib.mkOption {
      type = with lib.types; attrsOf anything;
      default = { };
      example = lib.literalExpression ''
        { acme-tools.source = { source = "github"; repo = "acme/claude-plugins"; }; }
      '';
      description = ''
        Extra plugin marketplaces, merged into settings.json's
        `extraKnownMarketplaces`. The official `claude-plugins-official`
        marketplace is already declared by the opinionated defaults. Key each
        entry by the marketplace's canonical name so it merges with a copy
        Claude Code may have auto-registered instead of cloning twice.
      '';
    };

    beads = lib.mkOption {
      type = lib.types.bool;
      default = true;
      description = ''
        Ship beads — the git-backed issue tracker / agent memory — as part of
        the default stack: nixpkgs' `bd` CLI on PATH plus the official
        `beads@beads-marketplace` plugin (slash commands, skills, and the
        SessionStart/PreCompact hooks running `bd prime`), the plugin fetched
        and refreshed by Claude Code at runtime like the others. Don't also
        run `bd setup claude` — the plugin already carries the hooks, and a
        second hook would prime every session twice (current bd detects the
        plugin and skips its own hook, so nothing breaks if you do). Set
        false to drop both the package and the plugin.
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

    prefetch = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = ''
        Run the updater once per user at boot, so the binary is already staged
        before anyone's first `claude`. Without it, the first launch on a
        freshly-built machine blocks on the whole ~262 MiB download — the
        launcher bootstraps synchronously when nothing is installed at all.
        Requires `users`.

        Orthogonal to `updateTimer`: prefetch is the one-shot at boot, the
        timer is the recurring refresh. Enable both to get both; they take the
        same lock, so an overlap costs nothing but an early exit.
      '';
    };

    users = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [ ];
      example = [ "alice" ];
      description = ''
        Users this module provisions per-user system units for: the
        `updateTimer` refresh and the `prefetch` fetch (each into their own
        ~/.claude/cc), plus the settings.json installer that backstops the
        activation script on hosts with no systemd user manager. Empty means
        no per-user units at all — settings.json then arrives only via user
        activation, which is enough on a host where every user gets a logind
        session.
      '';
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
    ++ lib.optional cfg.installUpdateCli updater
    ++ lib.optional cfg.beads pkgs.beads;

    # settings.json, delivery path #1 — user activation. Runs for every user
    # with a systemd user manager, including ones not named in `users`, which
    # is why it stays even though path #2 exists.
    system.userActivationScripts = lib.mkIf manageSettings {
      claudeDripSettings.text = ''
        mkdir -p "$HOME/.claude"
        install -m 0644 ${settingsFile} "$HOME/.claude/settings.json"
      '';
    };

    environment.interactiveShellInit = lib.mkIf cfg.yoloAlias ''
      alias yolo='claude --dangerously-skip-permissions'
    '';

    systemd.services = lib.mkMerge [
      # settings.json, delivery path #2 — a per-user SYSTEM oneshot.
      #
      # Path #1 above is the only one on a stock desktop and is enough there,
      # but it is not enough everywhere. `system.userActivationScripts`
      # compiles into `systemd.user.services.nixos-activation`: a systemd
      # --user unit (ConditionUser=!@system, wantedBy default.target). A
      # --user unit only runs once that user's manager — user@<uid>.service —
      # has been started, and nothing starts a user manager without a
      # PAM/logind session. On a host whose sshd sets `UsePAM = false`, or in
      # any image or container with no logind at all, no user manager is ever
      # started, the activation script never fires, and settings.json is
      # simply never written.
      #
      # That failure is silent and misshapen. The launcher-side knobs
      # (autoTrust, autoOnboard) keep working, because they run inside the
      # launcher process rather than out of settings.json — so onboarding
      # looks healthy while everything that lives ONLY in settings.json (the
      # fullscreen TUI, the statusline, effortLevel, the env defaults) quietly
      # does not happen. It reads as "Claude is misbehaving", not as "a file
      # is missing", and costs an afternoon to trace.
      #
      # So this is additive and neither path can be dropped: #1 covers every
      # user with a session, including ones this module was never told about;
      # #2 covers the users it WAS told about on hosts with no session to hang
      # off. Both install the same store path with the same mode, so a machine
      # running both just writes identical bytes twice.
      #
      # Run as the user, never as root. A root-run `mkdir -p ~/.claude` leaves
      # a root-owned directory the user then cannot write, which breaks every
      # later state/cache write underneath it — and again surfaces as a
      # misbehaving tool rather than as a permissions error.
      #
      # RemainAfterExit holds the unit "active" once the file is in place so a
      # daemon-reload doesn't re-run it; the settingsFile store path is baked
      # into the script, so changing settings.json changes the unit and
      # nixos-rebuild restarts it — which installs the new file.
      (lib.mkIf manageSettings (
        mkUserUnits "settings" (u: {
          description = "claude-drip: install ~/.claude/settings.json for ${u}";
          wantedBy = [ "multi-user.target" ];
          path = [ pkgs.coreutils ];
          serviceConfig = {
            Type = "oneshot";
            RemainAfterExit = true;
            User = u;
            Group = config.users.users.${u}.group;
            Environment = "HOME=${config.users.users.${u}.home}";
          };
          script = ''
            mkdir -p "$HOME/.claude"
            install -m 0644 ${settingsFile} "$HOME/.claude/settings.json"
          '';
        })
      ))

      # The binary before the first launch. Type=simple, NOT oneshot: a
      # oneshot wantedBy multi-user.target holds that target until it exits,
      # so a ~262 MiB fetch on a cold machine would sit in front of boot
      # completion. A simple service counts as started the moment it forks,
      # and the download proceeds alongside everything else — which is all we
      # want, since nothing else in the boot depends on it having finished.
      (lib.mkIf cfg.prefetch (
        mkUserUnits "prefetch" (u: {
          description = "claude-drip: prefetch Claude Code for ${u}";
          wantedBy = [ "multi-user.target" ];
          after = [ "network-online.target" ];
          wants = [ "network-online.target" ];
          serviceConfig = {
            Type = "simple";
            User = u;
            Group = config.users.users.${u}.group;
            Environment = "HOME=${config.users.users.${u}.home}";
          };
          script = updaterBin;
        })
      ))

      (lib.mkIf (cfg.updateTimer && cfg.autoUpdate) (
        mkUserUnits "update" (u: {
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
      ))
    ];

    systemd.timers = lib.mkIf (cfg.updateTimer && cfg.autoUpdate) (
      mkUserUnits "update" (u: {
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
      {
        assertion = !cfg.prefetch || cfg.users != [ ];
        message = "services.claude-code.prefetch requires services.claude-code.users to be non-empty.";
      }
    ];
  };
}
