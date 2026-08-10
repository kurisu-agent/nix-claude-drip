# Evaluation check for the gumbo wiring: `services.claude-code.gumbo.enable`
# has to bring up BOTH halves, and has to stay completely inert when it is off.
#
# Deliberately an EVAL check, not a VM test. Everything asserted here is a
# property of the option system — what services.gumbo.enable resolves to, which
# binary the statusline and yolo call, whether the CLI is on PATH — so building
# a system closure to observe it would cost minutes and prove no more. The
# things a VM would add (does `gumbo serve` actually bind, does claude route)
# belong to gumbo's own tests, not to this module's wiring.
{
  nixpkgs,
  system,
  module,
}:

let
  pkgs = nixpkgs.legacyPackages.${system};
  inherit (nixpkgs) lib;

  # A host config is only needed as far as the options we read: nothing here
  # forces system.build.toplevel, so no bootloader or filesystem is required.
  eval =
    extra:
    (nixpkgs.lib.nixosSystem {
      modules = [
        module
        {
          nixpkgs.hostPlatform = system;
          system.stateVersion = "26.05";
        }
        { services.claude-code.enable = true; }
        extra
      ];
    }).config;

  # Every string here carries store-path context (the gumbo package is
  # interpolated into the shell init and the statusline command), and
  # builtins.match refuses a pattern that does. The assertions are about text
  # shape, not about building anything, so drop the context on both sides.
  noCtx = builtins.unsafeDiscardStringContext;
  infix = needle: hay: lib.hasInfix (noCtx needle) (noCtx hay);
  suffix = needle: hay: lib.hasSuffix (noCtx needle) (noCtx hay);

  # Does this yolo body REPLACE its caller with claude? Matched on the two
  # shapes the invocation can take (`env`-prefixed when routing is yolo-scoped,
  # bare when it is global) rather than on "exec", which also appears in the
  # body's prose.
  execsClaude = text: infix "exec env " text || infix "exec claude " text;

  off = eval { };
  on = eval { services.claude-code.gumbo.enable = true; };
  clientOnly = eval {
    services.claude-code.gumbo = {
      enable = true;
      serve = false;
    };
  };
  daemonElsewhere = eval {
    services.claude-code.gumbo.enable = true;
    services.gumbo.listen.localAddr = "127.0.0.1:9999";
  };
  # A kart: the endpoint is not known when the closure is built, so nothing may
  # be baked into the statusline or into yolo's environment. `0136 — Split gumbo
  # into an engine-free core on lakitu and a credential-free client in the kart,
  # so `gumbo ls` and `yolo` work inside a guest that never holds a key`.
  endpointAtRuntime = eval {
    services.claude-code.gumbo = {
      enable = true;
      serve = false;
      daemon = null;
    };
  };
  # The shape a non-interactive launcher needs: no shell function at all, yolo
  # only as a command.
  onPath = eval {
    services.claude-code.yoloAlias = false;
    services.claude-code.gumbo = {
      enable = true;
      yoloOnPath = true;
    };
  };

  # launchEnv: pool-wide launch env for the bare `yolo` that never calls
  # `gumbo resolve` and so never gets an alias's env.
  withLaunchEnv = eval {
    services.claude-code.gumbo = {
      enable = true;
      launchEnv.CLAUDE_CODE_MAX_CONTEXT_TOKENS = "1000000";
    };
  };
  globalLaunchEnv = eval {
    services.claude-code.gumbo = {
      enable = true;
      global = true;
      launchEnv.CLAUDE_CODE_MAX_CONTEXT_TOKENS = "1000000";
    };
  };

  gumboPkg = on.services.gumbo.package;
  hasPkg = c: lib.elem gumboPkg c.environment.systemPackages;
  statusline = c: c.services.claude-code.statusLine.resolvedCommand;

  checks = {
    # OFF by default: importing gumbo's module must not start anything.
    "gumbo daemon is off when the option is off" = !off.services.gumbo.enable;
    "gumbo CLI is not on PATH when the option is off" = !hasPkg off;
    "statusline carries no gumbo segment when the option is off" =
      statusline off == null || !suffix "claude-statusline-gumbo" (toString (statusline off));

    # ON: one knob wires the daemon, the CLI, and the client's two consumers.
    "enabling the option enables services.gumbo" = on.services.gumbo.enable;
    "enabling the option puts the gumbo CLI on PATH" = hasPkg on;
    "the daemon's unit runs the same package the client calls" =
      noCtx on.systemd.services.gumbo.serviceConfig.ExecStart == noCtx "${gumboPkg}/bin/gumbo serve";
    "the statusline gains the gumbo segment" = suffix "claude-statusline-gumbo" (
      toString (statusline on)
    );
    "yolo becomes the gumbo function, not the plain alias" =
      infix "X-Gumbo-Session" on.environment.interactiveShellInit;
    "yolo calls gumbo by absolute path, not by PATH lookup" =
      infix "${gumboPkg}/bin/gumbo resolve" on.environment.interactiveShellInit;
    # The shell function runs claude as a CHILD. `exec` here would replace the
    # interactive shell, so `yolo --help` -- claude printing help and exiting --
    # would close the user's terminal.
    "the shell function does not exec over the shell" =
      !execsClaude on.environment.interactiveShellInit;

    # The client's addr follows the daemon's LOCAL door, so the port is set in
    # one place. It tracks that door specifically and never the owner socket or
    # the kart door: the three are different authorities, not three spellings of
    # one address.
    "client addr defaults to the daemon's local door" =
      on.services.claude-code.gumbo.addr == on.services.gumbo.listen.localAddr;
    "moving services.gumbo.listen.localAddr moves the client with it" =
      daemonElsewhere.services.claude-code.gumbo.addr == "127.0.0.1:9999"
      && infix "http://127.0.0.1:9999" daemonElsewhere.environment.interactiveShellInit;
    "a matching addr raises no warning" =
      !lib.any (w: infix "differs from services.gumbo.listen.localAddr" w) on.warnings;

    # The CONTROL door is the owner socket, not the HTTP address — `yolo` and
    # the statusline ask the daemon over the door whose mode is the boundary.
    "the control endpoint defaults to the owner socket" =
      on.services.claude-code.gumbo.daemon == on.services.gumbo.listen.ownerSocket;
    "yolo exports the control endpoint, not the relay address" =
      infix "export GUMBO_DAEMON=\"${on.services.gumbo.listen.ownerSocket}\""
        on.environment.interactiveShellInit;

    # daemon = null is the kart shape: an endpoint that arrives at runtime.
    # Asserted on the shell init because that is the one place the rendered text
    # is reachable from `config` — the statusline wrapper is a store PATH here,
    # and reading its script would be import-from-derivation, which would drag a
    # full gumbo build into every evaluation of this check. The two share
    # `cfg.gumbo.daemon`, so one covers the decision both make.
    # Matched on the `export`, not on the bare name: the body carries a comment
    # explaining when the export is emitted, and that comment ships in every
    # rendering including this one.
    "a null endpoint bakes no GUMBO_DAEMON into yolo" =
      !infix "export GUMBO_DAEMON" endpointAtRuntime.environment.interactiveShellInit;
    "a null endpoint still routes claude at the relay" =
      infix "X-Gumbo-Session" endpointAtRuntime.environment.interactiveShellInit;

    # yoloOnPath: a real command, same routing, and no warning that nothing
    # routes just because the shell function is off.
    "yoloOnPath installs a yolo command" = lib.any (
      p: (p.pname or p.name or "") == "yolo"
    ) onPath.environment.systemPackages;
    # `.text` rather than readFile of the built script: reading the output
    # would be import-from-derivation, which would drag a full gumbo build into
    # every evaluation of this check.
    "the yolo command routes at the gateway" =
      let
        yoloPkg = lib.head (
          lib.filter (p: (p.pname or p.name or "") == "yolo") onPath.environment.systemPackages
        );
      in
      infix "http://${onPath.services.gumbo.listen.localAddr}" yoloPkg.text;
    # The command form is a wrapper with nothing left to do, so it DOES exec --
    # the opposite of the shell function above, and the reason the body takes
    # the prefix as a parameter.
    "the yolo command execs so no wrapper lingers" =
      let
        yoloPkg = lib.head (
          lib.filter (p: (p.pname or p.name or "") == "yolo") onPath.environment.systemPackages
        );
      in
      execsClaude yoloPkg.text;
    "yoloOnPath silences the nothing-routes warning" =
      !lib.any (w: infix "nothing routes claude through the gateway" w) onPath.warnings;
    "the warning still fires when neither form of yolo exists" =
      lib.any (w: infix "nothing routes claude through the gateway" w)
        (eval {
          services.claude-code.yoloAlias = false;
          services.claude-code.gumbo.enable = true;
        }).warnings;

    # launchEnv rides the same per-launch `env` prefix as the routing vars, so
    # it reaches claude on EVERY yolo — including the bare one, which never
    # calls resolve and so never sees an alias's env.
    "launchEnv reaches the claude invocation" =
      infix "CLAUDE_CODE_MAX_CONTEXT_TOKENS=" withLaunchEnv.environment.interactiveShellInit;
    # As a DEFAULT, not an assignment. The prefix is the last thing to set the
    # variable, so a bare `VAR=value` here would silently beat the alias env
    # the resolve fragment exported a few lines earlier — kimi's real window
    # would lose to the pool-wide one on `yolo kimi`.
    "launchEnv defers to an alias's env rather than overriding it" =
      infix "CLAUDE_CODE_MAX_CONTEXT_TOKENS=\"\${CLAUDE_CODE_MAX_CONTEXT_TOKENS:-1000000}\""
        withLaunchEnv.environment.interactiveShellInit;
    # Prefixed, never exported: an exported value would outlive a failed launch
    # and leak into the next plain `claude` in that shell.
    "launchEnv is not exported into the calling shell" =
      !infix "export CLAUDE_CODE_MAX_CONTEXT_TOKENS" withLaunchEnv.environment.interactiveShellInit;
    # Empty by default, so the rendered body is unchanged for every host that
    # does not ask for this. Matched on the ASSIGNMENT rather than on the bare
    # name, which — like "exec" above — also appears in the body's prose: the
    # 1M-window comment names this variable to explain why it is the wrong lever
    # for a model Claude Code recognises.
    "an empty launchEnv adds nothing" =
      !infix "CLAUDE_CODE_MAX_CONTEXT_TOKENS=" on.environment.interactiveShellInit;
    # global = true routes through settings.json and has no env prefix to hang
    # this on; settings.env is the place instead.
    "launchEnv is inert under global routing" =
      !infix "CLAUDE_CODE_MAX_CONTEXT_TOKENS" globalLaunchEnv.environment.interactiveShellInit;

    # The 1M window. Behind the gateway Claude Code cannot see the account's
    # entitlement and caps a model it otherwise knows at 200k, so the bare
    # `yolo` asks for the `[1m]` variant itself — the only lever that lifts the
    # cap, since every window knob is min()'d against it and can only clamp down.
    # Braced, because zsh sources this body too and reads a brace-less `$m[1m]`
    # as a subscript — `bad math expression`, before claude ever runs.
    "yolo asks for the 1M variant of the configured model" =
      infix "oneM=\"\${m}[1m]\"" on.environment.interactiveShellInit;
    # Read at LAUNCH from the file `/model` rewrites, never baked in at build
    # time — a build-time model goes stale the first time the model is switched,
    # and `claude` and `yolo` would silently drift onto different models.
    "the 1M model is read from settings.json at launch" =
      infix "-r '.model // empty' \"\${CLAUDE_CONFIG_DIR:-$HOME/.claude}/settings.json\""
        on.environment.interactiveShellInit;
    # A DEFAULT like launchEnv, so an explicit value and an alias's env both
    # still win. `yolo kimi` never reaches it anyway: resolve passes `--model`,
    # and a flag beats the environment.
    "the 1M model defers to an explicit ANTHROPIC_MODEL" =
      infix "ANTHROPIC_MODEL=\"\${ANTHROPIC_MODEL:-$oneM}\"" on.environment.interactiveShellInit;
    # Only the aliases that HAVE a 1M variant are rewritten; a full model ID,
    # `haiku`, `opusplan`, or a name already carrying the suffix passes through.
    "only the 1M-capable aliases are rewritten" =
      infix "opus | sonnet | fable)" on.environment.interactiveShellInit;
    # Quoted, and not cosmetically: `opus[1m]` is a glob, so an unquoted
    # expansion would be pathname-expanded by bash against the current directory.
    "the 1M model is never expanded unquoted" =
      !infix "ANTHROPIC_MODEL=$oneM" on.environment.interactiveShellInit;
    # global = true routes through settings.json and has no env prefix to hang
    # this on — same reason launchEnv is inert there.
    "the 1M model default is inert under global routing" =
      !infix "[1m]" globalLaunchEnv.environment.interactiveShellInit;

    # serve = false is the client-only escape hatch.
    "serve = false leaves the daemon off" = !clientOnly.services.gumbo.enable;
    "serve = false keeps the client wiring" =
      infix "X-Gumbo-Session" clientOnly.environment.interactiveShellInit;
  };

  failed = lib.attrNames (lib.filterAttrs (_: v: !v) checks);
in
if failed == [ ] then
  pkgs.runCommand "gumbo-wiring-ok" { } ''
    echo "${toString (lib.length (lib.attrNames checks))} gumbo wiring assertions hold" > $out
  ''
else
  throw "gumbo wiring check failed:\n  - ${lib.concatStringsSep "\n  - " failed}"
