# claude-drip NixOS module. Puts the self-updating `claude` launcher on
# PATH, installs ~/.claude/settings.json (by two deliberately redundant
# paths — see the settings units in `config`), enables nix-ld (the native
# binary is a foreign glibc ELF), and optionally schedules a per-user systemd
# timer so the binary is refreshed even between sessions, or fetches it once
# at boot. On non-NixOS hosts (e.g. glibc devcontainers) consume the flake
# *package* instead — the binary runs on the system glibc with no module and
# no nix-ld.
#
# The composed flakes arrive as the first argument, applied by flake.nix
# ahead of the module args. `gumboFlake` is taken so this module can IMPORT
# gumbo's own nixosModule: enabling `services.claude-code.gumbo` then brings
# the daemon up as well as the client wiring, instead of leaving the operator
# to pin gumbo separately and remember to turn both halves on. `herdrFlake` +
# `herdrDripFlake` serve the same one-knob idea for the workspace manager:
# `services.claude-code.herdr` installs the pinned herdr and enables
# herdr-drip's two modules (hook keepalive + plugin provisioning) together.
{
  gumboFlake,
  herdrFlake,
  herdrDripFlake,
}:
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

  # The herdr that actually lands on PATH: the host's package choice with
  # herdr-drip's hardcore-plugin patch set applied on top (unless opted out).
  # Patching downstream of the choice is what lets a host override
  # `herdr.package` with an unpatched build and still carry the set.
  herdrPackage =
    if cfg.herdr.dripPatches then herdrDripFlake.lib.patchHerdr cfg.herdr.package else cfg.herdr.package;

  # gumbo (multi-account gateway) client wiring. Absolute `${pkg}/bin/gumbo`
  # when a package is given — PATH-independent, so the yolo function and the
  # statusline wrapper work regardless of the interactive PATH — else the bare
  # word, expecting `gumbo` on PATH (e.g. from services.gumbo).
  gumboBin = if cfg.gumbo.package == null then "gumbo" else lib.getExe' cfg.gumbo.package "gumbo";

  # `gumbo.launchEnv` rendered as arguments for the yolo `env` prefix. Each is
  # a DEFAULT — `VAR="${VAR:-value}"` — because the prefix is the LAST thing to
  # set the variable and a bare `VAR=value` there would silently beat the alias
  # env the resolve fragment exported a few lines earlier. Sorted, since
  # mapAttrsToList follows attribute order and a stable string keeps the
  # derivation from churning.
  launchEnvArgs = lib.concatStrings (
    lib.mapAttrsToList (n: v: ''${n}="''${${n}:-${v}}" '') cfg.gumbo.launchEnv
  );

  # GLOBAL routing: the two loopback env vars go into settings.env (merged
  # UNDER cfg.settings, so still overridable), so EVERY claude routes through
  # the gateway. Empty unless gumbo.enable && gumbo.global — yolo-scoped mode
  # keeps them out of settings and exports them per-launch in the function.
  gumboSettings = lib.optionalAttrs (cfg.gumbo.enable && cfg.gumbo.global) {
    env = {
      ANTHROPIC_BASE_URL = "http://${cfg.gumbo.addr}";
      CLAUDE_CODE_OAUTH_TOKEN = cfg.gumbo.placeholderToken;
    };
  };

  # Curated defaults (from the shared lib) layered UNDER cfg.settings, then
  # the dedicated `theme` knob on top (so `services.claude-code.theme` wins
  # over a `settings.theme` and stays in sync with the statusline flavour).
  # Precedence low → high: opinionatedDefaults < pluginSettings < gumboSettings
  # < cfg.settings, then theme. recursiveUpdate deep-merges `env`, so gumbo's
  # keys join the curated env defaults and stay vetoable via settings.env.
  mergedSettings =
    lib.recursiveUpdate (lib.recursiveUpdate (lib.recursiveUpdate (lib.optionalAttrs cfg.opinionatedDefaults claudeLib.opinionatedDefaults) pluginSettings) gumboSettings) cfg.settings
    // lib.optionalAttrs (cfg.theme != null) { theme = cfg.theme; };

  statusline = claudeLib.mkStatusBin (
    commonArgs // { effortLevel = mergedSettings.effortLevel or null; }
  );

  manageSettings = cfg.statusLine.enable || mergedSettings != { };

  # What the statusline would be WITHOUT gumbo: null when off, the user's
  # custom command when set, else the built-in. Both honour the stdin → one
  # line contract, so the gumbo wrapper can wrap either uniformly.
  baseStatusCommand =
    if !cfg.statusLine.enable then
      null
    else if cfg.statusLine.command != null then
      toString cfg.statusLine.command
    else
      "${statusline}/bin/claude-statusline";

  # Wrap the base statusline with the gumbo session segment. Lazy: this is only
  # forced when selected below, so the null-base branch (statusLine off) never
  # reaches mkGumboStatusline's innerCommand — a null is never interpolated.
  gumboStatusline = claudeLib.mkGumboStatusline {
    innerCommand = baseStatusCommand;
    inherit gumboBin;
    inherit (cfg.gumbo) daemon;
    alwaysShow = cfg.gumbo.global;
  };

  statusLineCommand =
    if baseStatusCommand == null then
      null # statusLine off → no segment
    else if cfg.gumbo.enable && cfg.gumbo.sessionStatusline then
      "${gumboStatusline}/bin/claude-statusline-gumbo"
    else
      baseStatusCommand; # gumbo off → byte-identical to before

  settingsFile = claudeLib.mkSettings {
    settings = mergedSettings;
    inherit statusLineCommand;
    inherit (cfg.statusLine) refreshInterval;
  };

  # The `yolo` body. Defined once here because it has two consumers that must
  # never drift apart: the interactive shell function below, and — under
  # `gumbo.yoloOnPath` — the same thing as a real command. POSIX-portable, since
  # environment.interactiveShellInit is sourced by BOTH bash and zsh (`name()
  # {}`, `local`, `${1#-}`, `[ ]`, `printf`, `$RANDOM`, `$$` behave identically
  # in the two).
  #
  # `exec` is the ONE thing the two consumers cannot share. In the command form
  # it is right: the wrapper has nothing left to do and should not linger as a
  # parent process. In the SHELL FUNCTION form it replaces the interactive shell
  # itself, so anything that makes claude exit promptly takes the terminal down
  # with it — `yolo --help` printed help and closed the window. Hence a
  # parameter, defaulted nowhere: each consumer states which it wants.
  gumboYoloBody = execPrefix: ''
    yolo() {
      local key frag m oneM
      # Per-launch session key: STABLE for this process (the statusline and
      # every request from this claude read the same key, so the launch
      # sticks to one account) and UNIQUE across launches — date seconds +
      # the interactive shell's pid + RANDOM. A second `yolo` in the same
      # shell and second still differs via $RANDOM. Chars are [a-z0-9-]:
      # valid in an HTTP header value and in the ?session= query.
      key="yolo-$(date +%s)-$$-$RANDOM"

      # Sticky selector header. ANTHROPIC_CUSTOM_HEADERS is newline-
      # separated `Name: Value` pairs; preserve any pre-existing value by
      # newline-appending. printf builds the newline (no literal newline in
      # the nix source, and command substitution strips only TRAILING
      # newlines, so the interior one survives).
      if [ -n "''${ANTHROPIC_CUSTOM_HEADERS:-}" ]; then
        ANTHROPIC_CUSTOM_HEADERS="$(printf '%s\nX-Gumbo-Session: %s' "$ANTHROPIC_CUSTOM_HEADERS" "$key")"
      else
        ANTHROPIC_CUSTOM_HEADERS="X-Gumbo-Session: $key"
      fi
      export ANTHROPIC_CUSTOM_HEADERS

      # Let the statusline segment and any interactive `gumbo` see the key
      # + daemon. GUMBO_DAEMON is exported only when this host knows the
      # endpoint at build time; inside a kart it does not, and the client reads
      # it from the identity share instead.
      export GUMBO_SESSION="$key"
      ${lib.optionalString (cfg.gumbo.daemon != null) ''export GUMBO_DAEMON="${cfg.gumbo.daemon}"''}
      # yolo-scoped routing (!global) is prefix-scoped onto the claude
      # invocation below via `env`, NOT exported here -- so a failed
      # launch cannot leave ANTHROPIC_BASE_URL + the placeholder token
      # lingering in the shell to misroute the next plain `claude`. That
      # scoping is the `env` prefix's doing and holds whether or not the
      # invocation is exec'd. Global routing lives in settings.json.
      # `yolo <alias>` (e.g. `yolo kimi`): resolve model/env from gumbo
      # config (no daemon needed) and drop the alias from the args. Attempt
      # only when arg 1 exists and is not a flag ([ "''${1#-}" = "$1" ] is
      # true when $1 has no leading '-'). resolve exits 0 for a known alias;
      # on ANY other exit (unknown alias, missing gumbo, unreadable config)
      # we leave args untouched and claude handles arg 1 as usual. SHIFT
      # before eval so the fragment's `set -- --model M "$@"` rebuilds the
      # args WITHOUT the alias name.
      if [ "$#" -gt 0 ] && [ "''${1#-}" = "$1" ]; then
        if frag="$(${gumboBin} resolve "$1" 2>/dev/null)"; then
          shift
          eval "$frag"
        fi
      fi

      ${lib.optionalString (!cfg.gumbo.global) ''
        # THE 1M CONTEXT WINDOW. Routed through the gateway, Claude Code classes
        # the endpoint as a third-party "gateway" rather than the first-party
        # subscription, and from there it cannot see the account's entitlement —
        # so it caps a perfectly well-known model at 200k, where the SAME `opus`
        # under a plain `claude` gets 1M. Nothing raises that cap after the fact:
        # CLAUDE_CODE_MAX_CONTEXT_TOKENS, CLAUDE_CODE_AUTO_COMPACT_WINDOW and the
        # `autoCompactWindow` setting are each min()'d against it, so they can
        # only ever clamp DOWN. (They are what gives an UNKNOWN model like kimi
        # its window — which is why launchEnv still carries one, and why that
        # knob looked like it was working here when it never was.) The one lever
        # that LIFTS the cap is the `[1m]` suffix on the model name.
        #
        # Read the model out of settings.json rather than naming one here, so
        # `yolo` and `claude` stay on the SAME model and differ only by the
        # suffix the gateway makes necessary. It has to be read at LAUNCH rather
        # than baked in at build time, because `/model` rewrites that file: a
        # build-time value goes stale the first time the model is switched.
        #
        # Both spellings `/model` writes have to be matched — the bare alias it
        # stores for a family (`opus`) and the full ID it stores for a specific
        # pick (`claude-fable-5`) — because either can be sitting in that file.
        #
        # ONLY the 1M families, and haiku is left out ON PURPOSE. The suffix is
        # not validated against the model: `haiku[1m]` is accepted and reports a
        # 1M window for a model whose real ceiling is 200k, so a blanket append
        # would push a session past the limit and take a 400 from the API. The
        # residual risk is a RETIRED id in a 1M family (a pre-4.6 sonnet), which
        # would be rewritten and shouldn't be; every model these families
        # currently ship is 1M, and a name matching nothing here is passed
        # through untouched, which is only ever the old 200k behaviour.
        #
        # Like launchEnv this is a DEFAULT, not an override: the `''${ANTHROPIC_MODEL:-...}`
        # below keeps an explicit value, and `yolo kimi` never sees it because the
        # resolve fragment above passes `--model`, which beats the environment.
        # Empty is the "say nothing" value — Claude Code reads an empty
        # ANTHROPIC_MODEL as unset and falls back to settings.json by itself — so
        # the assignment can always be present, fully quoted. Neither the quotes
        # nor the braces are cosmetic, and they guard against DIFFERENT shells:
        # `opus[1m]` is a glob, so an unquoted expansion would be pathname-
        # expanded by bash against the current directory — and in zsh, which
        # sources this body just as bash does, a brace-less `$m[1m]` is a
        # SUBSCRIPT, so it dies on `bad math expression` before claude ever runs.
        oneM=""
        if [ -z "''${ANTHROPIC_MODEL:-}" ]; then
          m="$(${lib.getExe pkgs.jq} -r '.model // empty' "''${CLAUDE_CONFIG_DIR:-$HOME/.claude}/settings.json" 2>/dev/null || true)"
          case "$m" in
            # already asking for the big window; appending again would double it
            *'[1m]'*) ;;
            # a family alias — claude resolves it to that family's current model
            opus | sonnet | fable) oneM="''${m}[1m]" ;;
            # a specific pick, as `/model` writes it
            claude-opus-* | claude-sonnet-* | claude-fable-* | claude-mythos-*) oneM="''${m}[1m]" ;;
          esac
        fi
      ''}
      # THE TOKEN IS A PLACEHOLDER AND NOTHING ELSE. It exists so Claude Code
      # considers itself authenticated and sends the request to the gateway at
      # all; gumbo attaches the real per-account credential upstream. There is
      # no shared secret to read any more — gumbo decides what a caller may do
      # from WHICH LISTENER accepted the connection (an owner unix socket with a
      # group and a mode, a loopback listener, a kart's bridge door), so a token
      # in this slot never carried authority and now does not pretend to.
      #
      # This used to `cat` an 0640 auth-token file, which was the client half of
      # a shared-token scheme. That scheme is gone: a token read out of a file is
      # a bearer credential every process of that group can lift, where a unix
      # socket's mode is checked by the kernel on every connect and cannot be
      # copied out of the box at all. `0136 — Split gumbo into an engine-free
      # core on lakitu and a credential-free client in the kart, so `gumbo ls`
      # and `yolo` work inside a guest that never holds a key`.
      ${execPrefix}${
        lib.optionalString (!cfg.gumbo.global)
          ''env ANTHROPIC_BASE_URL="http://${cfg.gumbo.addr}" CLAUDE_CODE_OAUTH_TOKEN="${cfg.gumbo.placeholderToken}" ANTHROPIC_MODEL="''${ANTHROPIC_MODEL:-$oneM}" ${launchEnvArgs}''
      }claude --dangerously-skip-permissions "$@"
    }
  '';

  # Sourced into an interactive shell: NO exec, or the shell dies with claude.
  # The `env` prefix already scopes the routing env to this one command, so
  # nothing leaks into the shell either way (that is what the prefix is for,
  # not the exec).
  gumboYoloFunction = gumboYoloBody "";

  # The same body as an executable, for launchers that never source a profile —
  # a terminal multiplexer's configured shell, a desktop entry, a script. It
  # defines the function and then calls it rather than running the body inline,
  # because `local` is an error at the top level of a script. Here `exec` IS
  # wanted: the wrapper is a process the launcher would otherwise keep around
  # for the life of the session, and replacing it also puts claude's own pid
  # where the launcher expects the command it started.
  gumboYoloCommand = pkgs.writeShellScriptBin "yolo" ''
    ${gumboYoloBody "exec "}
    yolo "$@"
  '';

  # One unit per name in `users`, named claude-drip-<kind>-<user>. The kind is
  # a parameter rather than baked in because four different units share this
  # shape (update service, its timer, the settings installer, the boot
  # prefetch) — and because a timer must be named after the service it
  # triggers, so the update service and the update timer have to agree on it.
  mkUserUnits =
    kind: f: lib.listToAttrs (map (u: lib.nameValuePair "claude-drip-${kind}-${u}" (f u)) cfg.users);
in
{
  # gumbo's own module, for `services.gumbo` (the daemon, its rendered
  # config.toml, and the `gumbo` package). Unconditional — a NixOS import
  # cannot depend on config without recursing — but inert: gumbo's module is
  # all `mkIf cfg.enable`, and its package default is lazy, so a host that
  # never touches `services.claude-code.gumbo` gains an option surface and
  # nothing else. Importing here is what lets one `gumbo.enable = true` wire
  # both halves; see the `gumbo` options below.
  #
  # herdr-drip's two modules ride the same way, inert until
  # `services.claude-code.herdr.enable` (below) flips their enables: the
  # claude-agent-state hook keepalive and the pinned plugin provisioning.
  imports = [
    gumboFlake.nixosModules.default
    herdrDripFlake.nixosModules.claude-agent-state
    herdrDripFlake.nixosModules.plugins
  ];

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
        description = ''
          Re-tint the built-in statusline: the role colors
          (accent / branch / success / warning / error / muted) and the
          per-family model tints (modelFable / modelOpus / modelSonnet /
          modelHaiku).
        '';
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
      resolvedCommand = lib.mkOption {
        type = lib.types.nullOr lib.types.str;
        default = null;
        internal = true;
        description = ''
          Read-only: the command actually written into settings.json, after
          `command`/built-in selection and any gumbo wrapping. Everything that
          feeds settings.json is otherwise sealed inside a store path, so this
          is the only place a host — or a test — can see which statusline it
          ended up with. Not an input: setting it does nothing.
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
      default = false;
      description = ''
        Ship beads — the git-backed issue tracker / agent memory: nixpkgs'
        `bd` CLI on PATH plus the official `beads@beads-marketplace` plugin
        (slash commands, skills, and the SessionStart/PreCompact hooks
        running `bd prime`), the plugin fetched and refreshed by Claude Code
        at runtime like the others. Don't also run `bd setup claude` — the
        plugin already carries the hooks, and a second hook would prime every
        session twice (current bd detects the plugin and skips its own hook,
        so nothing breaks if you do).
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

    gumbo = {
      enable = lib.mkEnableOption ''
        route claude through a gumbo multi-account gateway. Turns on
        `services.gumbo` too (this module imports gumbo's own module), so one
        knob gets both the daemon and the client wiring — set
        `services.gumbo.enable = false` to keep the client half only and point
        `addr` at a gateway managed elsewhere'';

      serve = lib.mkOption {
        type = lib.types.bool;
        default = true;
        description = ''
          Bring up the gumbo daemon on this host (`services.gumbo.enable`)
          alongside the client wiring. The default is set with `mkDefault`, so
          an explicit `services.gumbo.enable` in your own config wins over it
          either way; this knob exists so a host can say "client only" without
          having to reach into another module's options.

          Turning it off does NOT change the client half: claude is still
          pointed at `addr`, which then has to be a gateway bound by something
          else (another host, a `systemd --user` unit, a hand-run `gumbo serve`).
        '';
      };

      package = lib.mkOption {
        type = lib.types.nullOr lib.types.package;
        default = config.services.gumbo.package;
        defaultText = lib.literalExpression "config.services.gumbo.package";
        example = lib.literalExpression "inputs.gumbo.packages.\${system}.default";
        description = ''
          The gumbo package providing the `gumbo` CLI (resolve/status/ls/use).
          Defaults to `services.gumbo.package` — i.e. the build from this
          flake's own `gumbo` input, the same one the daemon runs — so client
          and daemon cannot drift apart by default. This module puts it on PATH
          and uses its absolute `''${package}/bin/gumbo` in the yolo function
          and the statusline wrapper, so both work regardless of the
          interactive PATH.

          null means "expect `gumbo` on PATH" and emits the bare word instead:
          for a host that installs the CLI by some other route.
        '';
      };

      addr = lib.mkOption {
        type = lib.types.str;
        default = config.services.gumbo.listen.localAddr;
        defaultText = lib.literalExpression "config.services.gumbo.listen.localAddr";
        example = "127.0.0.1:8080";
        description = ''
          host:port of the gateway claude dials. Used to build
          ANTHROPIC_BASE_URL (http://<addr>) and as the `--addr` the statusline
          segment queries.

          Defaults to `services.gumbo.listen.localAddr` (itself 127.0.0.1:8787),
          so the daemon's own option is the single place to change the port and
          the client follows. Set this one only when the gateway is NOT the
          daemon this module manages — see `serve`. Inside a kart that is
          exactly the case: the gateway is a local `gumbo-client serve` relaying
          to the circuit's kart door, and this points at the relay.

          This tracks the LOCAL door specifically. gumbo has three listeners and
          they are not interchangeable — the owner unix socket carries authority
          over every credential in the store, and the kart door is namespaced
          and attributed per kart — so "the address claude posts to" is the
          unprivileged loopback one by construction.
        '';
      };

      daemon = lib.mkOption {
        type = lib.types.nullOr lib.types.str;
        default = config.services.gumbo.listen.ownerSocket;
        defaultText = lib.literalExpression "config.services.gumbo.listen.ownerSocket";
        example = "10.128.0.1:8503";
        description = ''
          The daemon endpoint the CLI verbs talk to: an absolute path for an
          owner unix socket, or `host:port` for a kart door. Passed explicitly
          to the statusline segment and exported as GUMBO_DAEMON by `yolo`, so
          neither depends on gumbo's config file being readable.

          Distinct from `addr`, and the distinction is the access model rather
          than a detail. `addr` is where the HTTP traffic goes — a byte relay
          claude posts to. This is the CONTROL door, and which door a request
          arrives on is the whole of what gumbo lets a caller do: the owner
          socket's group and mode are the boundary around every credential in
          the store.

          null means "pass nothing, let the binary find its own endpoint". That
          is what a kart wants: the endpoint arrives on the per-kart identity
          share at runtime and baking it into the guest closure would make a
          new kart need config, which is the thing `0136 — Split gumbo into an
          engine-free core on lakitu and a credential-free client in the kart,
          so `gumbo ls` and `yolo` work inside a guest that never holds a key`
          exists to prevent.
        '';
      };

      global = lib.mkOption {
        type = lib.types.bool;
        default = false;
        description = ''
          false (default): yolo-scoped routing — ONLY the `yolo` function
          points claude at the gateway (per-launch env), so a plain `claude`
          is untouched.
          true: route EVERY claude by writing ANTHROPIC_BASE_URL +
          CLAUDE_CODE_OAUTH_TOKEN into settings.env (merged UNDER
          `settings`, so still overridable).
        '';
      };

      placeholderToken = lib.mkOption {
        type = lib.types.str;
        default = "gumbo-placeholder-not-a-real-token";
        description = ''
          A clearly-fake CLAUDE_CODE_OAUTH_TOKEN. It exists only so Claude Code
          considers itself authenticated and sends the request to the loopback
          gateway; gumbo injects the real per-account credential upstream, so
          this is never a secret and never leaves the box. Override only if a
          Claude Code build rejects its shape — a prefix-shaped but obviously
          fake value like `sk-ant-oat01-gumbo-placeholder` satisfies both a
          prefix check and "clearly fake".
        '';
      };

      launchEnv = lib.mkOption {
        type = lib.types.attrsOf lib.types.str;
        default = { };
        example = {
          CLAUDE_CODE_MAX_CONTEXT_TOKENS = "1000000";
        };
        description = ''
          Env EVERY `yolo` launch gets, attached to the same per-launch `env`
          prefix as the routing vars — so it reaches claude without being
          exported into the calling shell, and a failed launch leaves nothing
          behind to misroute the next plain `claude`.

          Each entry is a DEFAULT, not an override: it expands to
          `VAR="''${VAR:-value}"`, so a gumbo alias's own `env` (which the
          resolve fragment exports just above) wins, and so does anything the
          caller already had set. That ordering is the whole point — a launch
          that actually asked for kimi must still get
          `aliases.kimi.env.CLAUDE_CODE_MAX_CONTEXT_TOKENS`, not the default
          meant for the Anthropic pool.

          The context window is the reason this exists. Claude Code assumes
          200k when it does not know a model's real window and auto-compacts
          five times too early on a 1M model. `gumbo resolve` fixes that for an
          alias, but a bare `yolo` never calls resolve — arg 1 has to be a
          non-flag for it to try — so nothing sets a window on the default
          path and the stale 200k stands.

          That story is only about models Claude Code does NOT recognise, which
          in practice means the third-party pools. For a model it DOES know,
          CLAUDE_CODE_MAX_CONTEXT_TOKENS cannot raise anything: the window is
          min()'d against the model's own ceiling, so the variable can only
          clamp down and a `claude-*` behind the gateway stays at 200k however
          large a number is put here. Lifting THAT is the `[1m]` model suffix's
          job, which the yolo function applies on its own — see the block above
          the `env` prefix.

          Only applies with `global = false`, which is where a per-launch env
          prefix exists to attach to. Under `global = true` every claude is
          routed through settings.json and `settings.env` is where this goes
          instead.
        '';
      };

      yoloOnPath = lib.mkOption {
        type = lib.types.bool;
        default = false;
        description = ''
          Also install `yolo` as a real command in systemPackages, not only as
          the interactive shell function `yoloAlias` defines. Same body, so the
          two cannot disagree; in an interactive shell the function shadows the
          command and nothing changes.

          For launchers that never source a profile and so never see the
          function: a multiplexer's configured `default_shell`, a desktop
          entry, a script. Without this, those launch a claude that is NOT
          routed through the gateway — silently, since a plain claude works
          fine, just on your own account.
        '';
      };

      sessionStatusline = lib.mkOption {
        type = lib.types.bool;
        default = true;
        description = ''
          Append a gumbo segment (`gumbo status --format line`: the account
          this launch's requests land on, plus 5h/7d headroom) to the
          statusline, keyed by the launch's session key. Time-boxed and
          fail-open, so it never blanks the row. No effect when
          statusLine.enable = false.
        '';
      };
    };

    herdr = {
      enable = lib.mkEnableOption ''
        herdr, the terminal workspace manager, with the drip riding it. One
        knob gets three things: the pinned herdr binary on PATH, herdr-drip's
        claude-agent-state module (keeps herdr's SessionStart hook alive
        across the settings.json overwrite THIS module performs), and
        herdr-drip's plugin provisioning (drip plugins installed pinned to
        the herdr-drip input's rev, curated config, yolo-shell + bun on the
        server's PATH). The sub-enables are set with mkDefault, so
        `services.herdr-drip.{claudeAgentState,plugins}` options remain
        individually overridable'';

      package = lib.mkOption {
        type = lib.types.package;
        default = herdrFlake.packages.${pkgs.stdenv.hostPlatform.system}.default;
        defaultText = lib.literalExpression "inputs.herdr.packages.\${system}.default";
        description = ''
          The herdr build to install. Defaults to this flake's own pinned
          herdr — the same node `packages.<system>.herdr` forwards — so
          every consumer runs the version this flake vouches for. Override
          it where a host must run a different build (e.g. a circuit host
          matching its kart guests' herdr); the drip modules resolve herdr
          from PATH, so they follow whatever is installed here. Supply it
          UNPATCHED — `dripPatches` below applies herdr-drip's patch set
          downstream of this choice.
        '';
      };

      dripPatches = lib.mkOption {
        type = lib.types.bool;
        default = true;
        description = ''
          Apply herdr-drip's source-patch set ("hardcore plugins" — the
          drip's opinions herdr has no plugin surface for, e.g. the running
          version rendered in the sidebar header) to `package` before
          installing. Applied HERE, downstream of the package choice, so a
          host that overrides `package` still gets the set; each patch
          fails the build loudly if a herdr bump breaks it. See herdr-drip's
          nix/herdr-patches.nix.
        '';
      };
    };
  };

  config = lib.mkIf cfg.enable {
    # The daemon half. mkDefault, so an explicit `services.gumbo.enable` in the
    # host's own config still decides — including turning it back ON when
    # `serve = false`, or off while the client wiring stays. Guarded by
    # cfg.gumbo.enable rather than assigned unconditionally so that a host
    # running gumbo for something other than claude is never overridden here.
    services.gumbo.enable = lib.mkIf cfg.gumbo.enable (lib.mkDefault cfg.gumbo.serve);

    # The herdr halves, same shape: mkDefault so a host can still pare either
    # back (e.g. `services.herdr-drip.plugins.enable = false`), guarded so a
    # host running the herdr-drip modules on its own terms is never touched.
    services.herdr-drip.claudeAgentState.enable = lib.mkIf cfg.herdr.enable (lib.mkDefault true);
    services.herdr-drip.plugins.enable = lib.mkIf cfg.herdr.enable (lib.mkDefault true);

    # Publish what the statusline resolved to (see the option's description).
    services.claude-code.statusLine.resolvedCommand = statusLineCommand;

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
    ++ lib.optional cfg.beads pkgs.beads
    ++ lib.optional (cfg.gumbo.enable && cfg.gumbo.package != null) cfg.gumbo.package
    ++ lib.optional (cfg.gumbo.enable && cfg.gumbo.yoloOnPath) gumboYoloCommand
    ++ lib.optional cfg.herdr.enable herdrPackage;

    # settings.json, delivery path #1 — user activation. Runs for every user
    # with a systemd user manager, including ones not named in `users`, which
    # is why it stays even though path #2 exists.
    system.userActivationScripts = lib.mkIf manageSettings {
      claudeDripSettings.text = ''
        mkdir -p "$HOME/.claude"
        install -m 0644 ${settingsFile} "$HOME/.claude/settings.json"
      '';
    };

    # `yolo`. Without gumbo it stays the plain alias; with gumbo it is the
    # session-minting function defined in the let block above.
    environment.interactiveShellInit = lib.mkIf cfg.yoloAlias (
      if cfg.gumbo.enable then
        gumboYoloFunction
      else
        ''
          alias yolo='claude --dangerously-skip-permissions'
        ''
    );

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

    # Soft nudges, not assertions: sessionStatusline defaults true, so a hard
    # `sessionStatusline → statusLine.enable` would break any gumbo user who
    # turns the statusline off. These only fire when gumbo is enabled.
    warnings =
      lib.optional (cfg.gumbo.enable && cfg.gumbo.sessionStatusline && !cfg.statusLine.enable)
        "services.claude-code.gumbo.sessionStatusline is set but statusLine.enable is false; the gumbo segment has no statusline to attach to."
      ++
        lib.optional (cfg.gumbo.enable && !cfg.gumbo.global && !cfg.yoloAlias && !cfg.gumbo.yoloOnPath)
          "services.claude-code.gumbo.enable is set with global = false, yoloAlias = false and gumbo.yoloOnPath = false; nothing routes claude through the gateway (only yolo does in non-global mode, and neither form of it is installed)."
      ++
        # `addr` defaults to services.gumbo.listen.localAddr, so these can only
        # disagree if both were set by hand — at which point claude is pointed
        # somewhere the managed daemon is not listening, and every launch fails
        # to connect.
        #
        # THE `global` + require_auth WARNING THAT USED TO SIT HERE IS GONE, and
        # its disappearance is the point rather than an omission. It said global
        # routing and the gateway's shared token were incompatible, because
        # settings.json is a static world-readable file that cannot hold a
        # secret. gumbo no longer has a shared token: what a caller may do comes
        # from which listener accepted the connection, so `global = true` is now
        # an ordinary configuration and the loopback door's mode is the boundary
        # the token used to pretend to be.
        lib.optional
          (
            cfg.gumbo.enable
            && config.services.gumbo.enable
            && cfg.gumbo.addr != config.services.gumbo.listen.localAddr
          )
          "services.claude-code.gumbo.addr (${cfg.gumbo.addr}) differs from services.gumbo.listen.localAddr (${config.services.gumbo.listen.localAddr}) while the daemon is managed here; claude will point at an address nothing is bound to.";

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
