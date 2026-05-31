# Statusline palette — five role colors for the prompt segments.
# `paletteOverride` merges on top, so a consumer that themes the rest of its
# UI can pass matching role colors here for a consistent look:
#   mkStatusBin { paletteOverride = { accent = "#FF0099"; }; ... }
# Defaults are Catppuccin Mocha.
{ paletteOverride ? { } }:
{
  # Role colors — prompt segments.
  accent = "#a6e3a1"; # path
  branch = "#b4befe"; # git branch + hash
  success = "#94e2d5"; # added count / restart-ready hint
  warning = "#f9e2af"; # modified count / downloading hint
  error = "#f38ba8"; # deleted count / update-error hint
}
// paletteOverride
