# Behaviour check for the gumbo statusline segment's two halves: the ACCOUNT
# (which identity is serving this launch) and the USAGE windows (`usage`, off by
# request on a row that does not want a headroom readout ticking every second).
#
# A real check rather than an eval assertion, because what is being asserted is
# what the rendered shell DOES with gumbo's output — and the whole risk in
# splitting a line on whitespace is that the split is one field off. Cheap all
# the same: `gumbo` and the inner statusline are both stubs, so nothing here
# builds gumbo or talks to a daemon.
{
  nixpkgs,
  system,
}:

let
  pkgs = nixpkgs.legacyPackages.${system};
  claudeLib = import ./default.nix { inherit nixpkgs system; };

  # An inner statusline: eats the JSON on stdin the way the real one does and
  # answers one fixed line, so every assertion below is about the segment.
  inner = pkgs.writeShellScriptBin "inner-line" ''
    cat > /dev/null
    printf '%s' "~/code opus"
  '';

  # `gumbo status --session K --format line` for an account with a hot window:
  # `<account>[*]` and then one space-joined group per window worth naming. The
  # `*` is the pin marker, and it belongs to the ACCOUNT half.
  busy = pkgs.writeShellScriptBin "gumbo" ''
    printf '%s' "hext3* 7·86%·2d21h2m"
  '';

  # An unassigned session — gumbo prints nothing at all until the first request
  # lands under the key. The segment must stay absent, not become a stray space.
  quiet = pkgs.writeShellScriptBin "gumbo" ''
    true
  '';

  wrapper =
    {
      usage,
      gumbo,
    }:
    claudeLib.mkGumboStatusline {
      innerCommand = "${inner}/bin/inner-line";
      gumboBin = "${gumbo}/bin/gumbo";
      inherit usage;
    };

  usageOn = wrapper {
    usage = true;
    gumbo = busy;
  };
  usageOff = wrapper {
    usage = false;
    gumbo = busy;
  };
  usageOffQuiet = wrapper {
    usage = false;
    gumbo = quiet;
  };
in
pkgs.runCommand "gumbo-segment-ok" { } ''
  fail=0
  expect() { # expect <what> <got> <want>
    if [ "$2" != "$3" ]; then
      echo "FAIL: $1" >&2
      echo "  got:  [$2]" >&2
      echo "  want: [$3]" >&2
      fail=1
    fi
  }
  # The statusline payload; only .model.display_name is read, and only by the
  # usage half (the Fable weekly is model-scoped).
  json='{"model":{"display_name":"Opus 5"}}'

  got=$(printf '%s' "$json" | GUMBO_SESSION=k ${usageOn}/bin/claude-statusline-gumbo)
  expect "usage on renders the account AND its windows" "$got" "~/code opus hext3* 7·86%·2d21h2m"

  got=$(printf '%s' "$json" | GUMBO_SESSION=k ${usageOff}/bin/claude-statusline-gumbo)
  expect "usage off keeps the account, pin marker included" "$got" "~/code opus hext3*"

  # An empty gumbo answer must leave the row exactly as the inner statusline
  # wrote it — no trailing separator for a segment that is not there.
  got=$(printf '%s' "$json" | GUMBO_SESSION=k ${usageOffQuiet}/bin/claude-statusline-gumbo)
  expect "an unassigned session still renders no segment" "$got" "~/code opus"

  # Non-global: no GUMBO_SESSION means this claude is not routed through the
  # gateway, so there is no account to name whichever half is on.
  got=$(printf '%s' "$json" | ${usageOff}/bin/claude-statusline-gumbo)
  expect "an un-routed launch still renders no segment" "$got" "~/code opus"

  # The payload is read only for the Fable weekly, so with the windows gone the
  # jq fork goes with them — this row repaints once a second.
  if grep -q jq ${usageOff}/bin/claude-statusline-gumbo; then
    echo "FAIL: usage off still forks jq per repaint" >&2
    fail=1
  fi

  [ "$fail" -eq 0 ] || exit 1
  echo "gumbo segment: account and usage halves behave" > $out
''
