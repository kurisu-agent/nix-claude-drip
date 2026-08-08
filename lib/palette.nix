# Statusline palette — role colors for the prompt segments, plus one tint
# per model family.
#
# `variant` picks the Catppuccin flavour: "mocha" (dark, default) or
# "latte" (light). The Mocha role colors are bright pastels tuned for a
# dark terminal; on a light background they wash out, so the Latte set
# swaps in the darker, more saturated Latte equivalents.
#
# `paletteOverride` merges on top, so a consumer that themes the rest of
# its UI can pass matching role colors here for a consistent look:
#   mkStatusBin { variant = "latte"; paletteOverride = { accent = "#FF0099"; }; ... }
{
  variant ? "mocha",
  paletteOverride ? { },
}:
let
  flavours = {
    # Catppuccin Mocha (dark).
    mocha = {
      accent = "#a6e3a1"; # path
      branch = "#b4befe"; # git branch + hash
      success = "#94e2d5"; # added count / restart-ready hint
      warning = "#f9e2af"; # modified count / downloading hint
      error = "#f38ba8"; # deleted count / update-error hint
      muted = "#9399b2"; # dim segments (pct / version) — overlay2
      # Model families. The name is already spelled out in the segment, so
      # these are for recognising at a glance which model you're on without
      # reading — hence one hue each, well apart from the others.
      modelFable = "#cba6f7"; # mauve
      modelOpus = "#f38ba8"; # red
      modelSonnet = "#f9e2af"; # yellow
      modelHaiku = "#89dceb"; # sky
    };
    # Catppuccin Latte (light) — darker / more saturated so the segments
    # stay legible on a light terminal background.
    latte = {
      accent = "#40a02b"; # path (green)
      branch = "#7287fd"; # git branch + hash (lavender)
      success = "#179299"; # added count / restart-ready hint (teal)
      warning = "#df8e1d"; # modified count / downloading hint (yellow)
      error = "#d20f39"; # deleted count / update-error hint (red)
      muted = "#6c6f85"; # dim segments — subtext0, readable on a light bg
      modelFable = "#8839ef"; # mauve
      modelOpus = "#d20f39"; # red
      modelSonnet = "#df8e1d"; # yellow
      modelHaiku = "#209fb5"; # sapphire
    };
  };
  flavour =
    flavours.${variant}
      or (throw "nix-claude-drip palette: unknown variant '${variant}' (expected \"mocha\" or \"latte\")");
in
flavour // paletteOverride
