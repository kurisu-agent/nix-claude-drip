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
    services.gumbo.addr = "127.0.0.1:9999";
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

    # The client's addr follows the daemon's, so the port is set in one place.
    "client addr defaults to the daemon's" =
      on.services.claude-code.gumbo.addr == on.services.gumbo.addr;
    "moving services.gumbo.addr moves the client with it" =
      daemonElsewhere.services.claude-code.gumbo.addr == "127.0.0.1:9999"
      && infix "http://127.0.0.1:9999" daemonElsewhere.environment.interactiveShellInit;
    "a matching addr raises no warning" =
      !lib.any (w: infix "differs from services.gumbo.addr" w) on.warnings;

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
      infix "http://${onPath.services.gumbo.addr}" yoloPkg.text;
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
