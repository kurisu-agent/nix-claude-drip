# Per-system lib entry. Wires the vendored palette into the claude builders.
# flake.nix calls this for each supported system and surfaces the result as
# `lib.${system}`.
{
  nixpkgs,
  system,
  paletteOverride ? { },
}:
let
  pkgs = nixpkgs.legacyPackages.${system};
  inherit (nixpkgs) lib;

  palette = import ./palette.nix { inherit paletteOverride; };

  claude = import ./claude.nix {
    inherit
      pkgs
      lib
      palette
      ;
  };
in
claude
// {
  inherit palette;
  # Re-tint without re-importing the whole lib.
  mkPalette = override: import ./palette.nix { paletteOverride = paletteOverride // override; };
}
