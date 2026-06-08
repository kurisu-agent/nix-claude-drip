# claude-drip builders. Claude Code is fetched as the native binary from
# Anthropic's release channel and swapped in-place under ~/.claude/cc; the
# binary is never modified (it's a Bun single-file executable — patchelf
# corrupts its appended payload). It runs unmodified: on a glibc host or
# container via the system loader, on NixOS via programs.nix-ld (enabled by the
# module). The running version is the `current` symlink target at launch
# (exported as CLAUDE_DRIP_RUNNING) or the statusline stdin `.version`.
{
  pkgs,
  lib,
  palette,
  variant ? "mocha",
}:

let
  # Hex "#rrggbb" → "R;G;B" for the ANSI 38;2;R;G;B truecolor escapes.
  hexToRgbCsv =
    let
      hexDigit =
        c:
        {
          "0" = 0; "1" = 1; "2" = 2; "3" = 3; "4" = 4;
          "5" = 5; "6" = 6; "7" = 7; "8" = 8; "9" = 9;
          "a" = 10; "A" = 10; "b" = 11; "B" = 11;
          "c" = 12; "C" = 12; "d" = 13; "D" = 13;
          "e" = 14; "E" = 14; "f" = 15; "F" = 15;
        }
        .${c};
      hexByte = s: 16 * (hexDigit (builtins.substring 0 1 s)) + (hexDigit (builtins.substring 1 1 s));
      stripHash =
        s: if builtins.substring 0 1 s == "#" then builtins.substring 1 (builtins.stringLength s - 1) s else s;
    in
    hex:
    let
      h = stripHash hex;
    in
    "${toString (hexByte (builtins.substring 0 2 h))};${toString (hexByte (builtins.substring 2 2 h))};${toString (hexByte (builtins.substring 4 2 h))}";

  ccHome = "$HOME/.claude/cc";
  releaseBase = "https://downloads.claude.ai/claude-code-releases";

  effortGlyphs = {
    low = "󰪞";
    medium = "󰪠";
    high = "󰪢";
    xhigh = "󰪤";
    max = "󰪥";
  };

  # Muted/secondary segments (pct, model, version). The SGR-2 "dim"
  # attribute reads as a faint grey on a dark terminal, but on a light one
  # it washes the dark default foreground out to near-invisible — so light
  # themes use an explicit readable grey (palette.muted) instead.
  dimSeq =
    if variant == "latte" then "\\033[38;2;${hexToRgbCsv palette.muted}m" else "\\033[2m";

  # Full color set for the prompt (ACCENT/BRANCH/DIM + the hint colors).
  colorVars = ''
    RESET=$'\033[0m'
    ACCENT=$'\033[38;2;${hexToRgbCsv palette.accent}m'
    BRANCH=$'\033[38;2;${hexToRgbCsv palette.branch}m'
    SUCCESS=$'\033[38;2;${hexToRgbCsv palette.success}m'
    WARNING=$'\033[38;2;${hexToRgbCsv palette.warning}m'
    ERROR=$'\033[38;2;${hexToRgbCsv palette.error}m'
    DIM=$'${dimSeq}'
  '';

  # Just the colors the hint fragment references — keeps claude-hint clean
  # of unused-var (SC2034) noise.
  hintColors = ''
    RESET=$'\033[0m'
    SUCCESS=$'\033[38;2;${hexToRgbCsv palette.success}m'
    WARNING=$'\033[38;2;${hexToRgbCsv palette.warning}m'
    ERROR=$'\033[38;2;${hexToRgbCsv palette.error}m'
  '';

  # Update indicator. Assumes `running`, RESET, WARNING, SUCCESS, ERROR are
  # set; fires the gated hourly check, then sets `hint` to the icon+version
  # for the current state (downloading / restart-ready / error) or "".
  # Precedence: downloading > staged-restart > error, so a real pending
  # restart is never masked by a later failed fetch.
  hintFragment =
    {
      updaterBin,
      checkInterval,
      autoCheck ? true,
    }:
    ''
      CC_HOME="${ccHome}"
      ${lib.optionalString autoCheck ''
        stamp="$CC_HOME/.lastcheck"
        now=$(date +%s)
        mt=$(stat -c %Y "$stamp" 2>/dev/null || echo 0)
        if [ $((now - mt)) -ge ${toString checkInterval} ]; then
          mkdir -p "$CC_HOME"
          touch "$stamp"
          ( ${updaterBin} >/dev/null 2>&1 & ) &
        fi
      ''}

      # Both args must be known versions — an empty running version (e.g.
      # redacted under IS_DEMO, or a pre-first-render render) must NOT be
      # treated as "older than ondisk", or it would show a spurious hint.
      is_newer() {
        [ -n "$1" ] || return 1
        [ -n "$2" ] || return 1
        [ "$1" != "$2" ] || return 1
        [ "$(printf '%s\n%s\n' "$2" "$1" | sort -V | tail -1)" = "$1" ]
      }

      IFS=$'\x1f' read -r status target < <(jq -r '[.status // "", .target // ""] | join("")' "$CC_HOME/state.json" 2>/dev/null) || true
      ondisk=""
      [ -L "$CC_HOME/current" ] && ondisk="$(basename "$(readlink "$CC_HOME/current")")"

      hint=""
      if [ "$status" = downloading ] && is_newer "$target" "$running"; then
        hint="''${WARNING}󰇚 ''${target}''${RESET}"
      elif is_newer "$ondisk" "$running"; then
        hint="''${SUCCESS}󰜉 ''${ondisk}''${RESET}"
      elif [ "$status" = error ]; then
        hint="''${ERROR}󰀪''${RESET}"
      fi
    '';

  # mkUpdater — single-flight updater. Polls the release channel (or a
  # pinned version), SHA-256-verifies against the per-version manifest,
  # stages the unmodified native binary under versions/<ver>, and atomically
  # flips `current`. State lands in state.json for the hint to read.
  mkUpdater =
    {
      channel ? "latest",
      platform ? (if pkgs.stdenv.hostPlatform.isAarch64 then "linux-arm64" else "linux-x64"),
      pinVersion ? null,
    }:
    pkgs.writeShellApplication {
      name = "claude-update";
      runtimeInputs = with pkgs; [
        coreutils
        curl
        jq
        gnugrep
        util-linux
      ];
      text = ''
        base=${lib.escapeShellArg releaseBase}
        platform=${lib.escapeShellArg platform}

        CC_HOME="${ccHome}"
        VERS="$CC_HOME/versions"
        CURRENT="$CC_HOME/current"
        STATE="$CC_HOME/state.json"
        LOCK="$CC_HOME/update.lock"

        mkdir -p "$VERS"

        exec 9>"$LOCK"
        flock -n 9 || exit 0

        write_state() {
          jq -n --arg status "$1" --arg target "$2" --arg ondisk "$3" \
            --argjson at "$(date +%s)" \
            '{status:$status, target:$target, ondisk:$ondisk, checked_at:$at}' \
            > "$STATE.tmp" && mv -f "$STATE.tmp" "$STATE"
        }

        ondisk=""
        if [ -L "$CURRENT" ]; then
          ondisk="$(basename "$(readlink "$CURRENT")")"
        fi

        ${
          if pinVersion != null then
            ''latest=${lib.escapeShellArg pinVersion}''
          else
            ''latest="$(curl -fsSL --max-time 10 "$base/${channel}" || true)"''
        }
        if ! printf '%s' "$latest" | grep -qE '^[0-9]+\.[0-9]+\.[0-9]+'; then
          exit 0
        fi

        if [ "$ondisk" = "$latest" ]; then
          write_state idle "$ondisk" "$ondisk"
          exit 0
        fi

        if [ -x "$VERS/$latest/claude" ]; then
          ln -sfn "versions/$latest" "$CC_HOME/.current.tmp"
          mv -Tf "$CC_HOME/.current.tmp" "$CURRENT"
          write_state ready "$latest" "$latest"
          exit 0
        fi

        write_state downloading "$latest" "$ondisk"

        manifest="$(curl -fsSL --max-time 10 "$base/$latest/manifest.json" || true)"
        checksum="$(printf '%s' "$manifest" | jq -r --arg p "$platform" '.platforms[$p].checksum // empty' 2>/dev/null || true)"
        if ! printf '%s' "$checksum" | grep -qE '^[a-f0-9]{64}$'; then
          write_state error "$latest" "$ondisk"
          exit 0
        fi

        tmp="$VERS/.$latest.tmp"
        rm -rf "$tmp"
        mkdir -p "$tmp"
        if ! curl -fsSL --max-time 300 -o "$tmp/claude" "$base/$latest/$platform/claude"; then
          rm -rf "$tmp"
          write_state error "$latest" "$ondisk"
          exit 0
        fi

        actual="$(sha256sum "$tmp/claude" | cut -d' ' -f1)"
        if [ "$actual" != "$checksum" ]; then
          rm -rf "$tmp"
          write_state error "$latest" "$ondisk"
          exit 0
        fi

        chmod +x "$tmp/claude"
        rm -rf "''${VERS:?}/''${latest:?}"
        mv -Tf "$tmp" "$VERS/$latest"
        ln -sfn "versions/$latest" "$CC_HOME/.current.tmp"
        mv -Tf "$CC_HOME/.current.tmp" "$CURRENT"
        write_state ready "$latest" "$latest"

        # Keep the new version and the one we swapped away from ($ondisk);
        # sessions still on the old binary need its file until they restart.
        for d in "$VERS"/*/; do
          [ -e "$d" ] || continue
          v="$(basename "$d")"
          [ "$v" = "$latest" ] && continue
          [ "$v" = "$ondisk" ] && continue
          rm -rf "$d"
        done
      '';
    };

  # mkLauncher — the `claude` on PATH. Fires the gated check on startup
  # (so updates land even with no statusline), bootstraps a missing install
  # synchronously, exports CLAUDE_DRIP_RUNNING, then execs the unmodified
  # binary. No patchelf; relies on the system loader / nix-ld.
  mkLauncher =
    {
      updaterBin,
      checkInterval ? 3600,
      autoCheck ? true,
      hideAccount ? false,
      autoTrust ? false,
      autoOnboard ? false,
    }:
    pkgs.writeShellApplication {
      name = "claude";
      runtimeInputs = with pkgs; [
        coreutils
        ripgrep
      ]
      ++ lib.optional (autoTrust || autoOnboard) jq;
      text = ''
        export DISABLE_AUTOUPDATER=1
        export USE_BUILTIN_RIPGREP=0
        export PATH="$HOME/.local/bin:$PATH"
        ${lib.optionalString hideAccount "export IS_DEMO=1"}
        CC_HOME="${ccHome}"

        ${lib.optionalString autoTrust ''
          # Pre-trust the launch directory so the (trust-gated) statusline +
          # hooks run without the trust dialog — which IS_DEMO suppresses,
          # leaving no way to accept it interactively. Only writes the first
          # time a directory is seen, to minimise churn on ~/.claude.json.
          cj="$HOME/.claude.json"
          [ -f "$cj" ] || echo '{}' > "$cj"
          if [ "$(jq -r --arg p "$PWD" '.projects[$p].hasTrustDialogAccepted // false' "$cj" 2>/dev/null)" != "true" ]; then
            if jq --arg p "$PWD" '.projects[$p].hasTrustDialogAccepted = true' "$cj" > "$cj.drip.tmp" 2>/dev/null; then
              mv -f "$cj.drip.tmp" "$cj"
            else
              rm -f "$cj.drip.tmp"
            fi
          fi
        ''}

        ${lib.optionalString autoCheck ''
          stamp="$CC_HOME/.lastcheck"
          now=$(date +%s)
          mt=$(stat -c %Y "$stamp" 2>/dev/null || echo 0)
          if [ $((now - mt)) -ge ${toString checkInterval} ] && [ -e "$CC_HOME/current/claude" ]; then
            mkdir -p "$CC_HOME"
            touch "$stamp"
            ( ${updaterBin} >/dev/null 2>&1 & ) &
          fi
        ''}

        if [ ! -e "$CC_HOME/current/claude" ]; then
          echo "claude: no install found, fetching latest…" >&2
          ${updaterBin} || true
          if [ ! -e "$CC_HOME/current/claude" ]; then
            echo "claude: install failed (no network?)" >&2
            exit 1
          fi
        fi

        # Satisfy Claude's native-install self-check: it nags unless the binary
        # exists at ~/.local/bin/claude AND ~/.local/bin is on PATH (exported
        # above, so it's in claude's own env regardless of the parent shell).
        mkdir -p "$HOME/.local/bin"
        ln -sfn "$CC_HOME/current/claude" "$HOME/.local/bin/claude"

        CLAUDE_DRIP_RUNNING="$(basename "$(readlink "$CC_HOME/current")")"
        export CLAUDE_DRIP_RUNNING

        ${lib.optionalString autoOnboard ''
          # Suppress Claude's first-run onboarding flow — it prompts for login
          # even when credentials are already present, so an automated/headless
          # launch would otherwise stall. Write-once: only when onboarding
          # isn't already marked complete, to minimise churn on ~/.claude.json.
          cj="$HOME/.claude.json"
          [ -f "$cj" ] || echo '{}' > "$cj"
          if [ "$(jq -r '.hasCompletedOnboarding // false' "$cj" 2>/dev/null)" != "true" ]; then
            if jq --arg v "$CLAUDE_DRIP_RUNNING" \
                 '. + {hasCompletedOnboarding: true, lastOnboardingVersion: $v, hasSeenTasksHint: true}' \
                 "$cj" > "$cj.drip.tmp" 2>/dev/null; then
              mv -f "$cj.drip.tmp" "$cj"
            else
              rm -f "$cj.drip.tmp"
            fi
          fi
        ''}

        exec "$CC_HOME/current/claude" "$@"
      '';
    };

  # mkHint — `claude-hint`: fires the gated check and prints just the update
  # indicator (icon+version) for custom statuslines. Reads the running
  # version from CLAUDE_DRIP_RUNNING (set by the launcher), since it has no
  # session stdin.
  mkHint =
    {
      updaterBin,
      checkInterval ? 3600,
      autoCheck ? true,
    }:
    pkgs.writeShellApplication {
      name = "claude-hint";
      runtimeInputs = with pkgs; [
        coreutils
        jq
      ];
      text = ''
        ${hintColors}
        running="''${CLAUDE_DRIP_RUNNING:-}"
        ${hintFragment { inherit updaterBin checkInterval autoCheck; }}
        printf '%s' "$hint"
      '';
    };

  # mkStatusBin — `claude-statusline`: the full prompt
  # `<path> <branch> <a> <m> <d> <pct>% [<effort>] <model> <version> [hint]`.
  # Reads the running version from stdin `.version`; appends the same update
  # hint inline. effortLevel renders a heat-map glyph (effort isn't in stdin).
  mkStatusBin =
    {
      effortLevel ? null,
      fallbackVersion ? "",
      updaterBin ? null,
      checkInterval ? 3600,
      autoCheck ? true,
    }:
    let
      effortGlyph = if effortLevel == null then null else effortGlyphs.${effortLevel} or null;
    in
    pkgs.writeShellApplication {
      name = "claude-statusline";
      runtimeInputs = with pkgs; [
        coreutils
        jq
        git
        gnused
      ];
      text = ''
        set -u
        input=$(cat)

        # join on US (\x1f), not @tsv — tab is IFS-whitespace, so `read` would
        # collapse an empty leading field (e.g. missing .version) and shift.
        IFS=$'\x1f' read -r running model cwd pct_raw < <(
          printf '%s' "$input" | jq -r '[.version // "", (.model.display_name // "Claude"), (.workspace.current_dir // .cwd // ""), (.context_window.used_percentage // 0 | tostring)] | join("")'
        )
        [ -z "$running" ] && running=${lib.escapeShellArg fallbackVersion}

        pct=''${pct_raw%%.*}
        [ -z "$pct" ] && pct=0

        model_lc=$(printf '%s' "$model" | tr '[:upper:]' '[:lower:]' | sed -E 's/ ?\(([^)]*) context\)/ \1/')

        # Path shortener — first two segments + final, eliding the middle
        # with a nerd-font ellipsis (U+F141). Threshold n > 4.
        path_for_display() {
          p="$1"
          case "$p" in
            "$HOME")    printf '~'; return ;;
            "$HOME"/*)  p="~''${p#"$HOME"}" ;;
          esac
          IFS='/' read -ra segs <<< "$p"
          n=''${#segs[@]}
          if [ "$n" -le 4 ]; then
            printf '%s' "$p"
          else
            printf '%s/%s/%s/%s/%s' "''${segs[0]}" "''${segs[1]}" "''${segs[2]}" $'' "''${segs[$((n-1))]}"
          fi
        }
        short_cwd=$(path_for_display "$cwd")

        branch=""
        short_hash=""
        added=0
        modified=0
        deleted=0
        if [ -n "$cwd" ] && [ -d "$cwd" ]; then
          branch=$(git -C "$cwd" rev-parse --abbrev-ref HEAD 2>/dev/null || true)
          if [ -n "$branch" ]; then
            short_hash=$(git -C "$cwd" rev-parse --short=4 HEAD 2>/dev/null || true)
            while IFS= read -r gline; do
              x="''${gline:0:1}"; y="''${gline:1:1}"
              case "$x$y" in
                "??")          added=$((added+1))  ;;
                "M "|"T ")     modified=$((modified+1)) ;;
                "A "|" A")     added=$((added+1)) ;;
                "D "|" D")     deleted=$((deleted+1)) ;;
                " M"|" T")     modified=$((modified+1)) ;;
                "R "|"C ")     modified=$((modified+1)) ;;
                "UU"|"AA"|"DD"|"AU"|"UA"|"DU"|"UD") deleted=$((deleted+1)) ;;
              esac
            done < <(git -C "$cwd" status --porcelain 2>/dev/null)
          fi
        fi

        ${colorVars}

        line="''${ACCENT}''${short_cwd}''${RESET}"
        if [ -n "$branch" ]; then
          line="''${line} ''${BRANCH}''${branch}''${RESET}"
          [ -n "$short_hash" ] && line="''${line} ''${BRANCH}''${short_hash}''${RESET}"
          [ "$added"    -gt 0 ] && line="''${line} ''${SUCCESS}''${added}''${RESET}"
          [ "$modified" -gt 0 ] && line="''${line} ''${WARNING}''${modified}''${RESET}"
          [ "$deleted"  -gt 0 ] && line="''${line} ''${ERROR}''${deleted}''${RESET}"
        fi
        line="''${line} ''${DIM}''${pct}%''${RESET}"
        ${lib.optionalString (effortGlyph != null) ''
          line="''${line} ${effortGlyph}"
        ''}
        line="''${line} ''${DIM}''${model_lc}''${RESET}"
        [ -n "$running" ] && line="''${line} ''${DIM}''${running}''${RESET}"

        ${lib.optionalString (updaterBin != null) ''
          ${hintFragment { inherit updaterBin checkInterval autoCheck; }}
          [ -n "$hint" ] && line="''${line} ''${hint}"
        ''}

        printf '%s' "$line"
      '';
    };

  # The curated, opinionated settings.json defaults — the single source of
  # truth, shared by the NixOS module and any external consumer (via
  # mkSettings's `opinionated` flag, or by reading this set directly).
  opinionatedDefaults = {
    effortLevel = "high";
    skipDangerousModePermissionPrompt = true;
    terminalProgressBarEnabled = true;
    tui = "fullscreen";
    env = {
      CLAUDE_CODE_EXPERIMENTAL_AGENT_TEAMS = "1";
      CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC = "1";
      CLAUDE_CODE_NO_FLICKER = "1";
    };
  };

  # mkSettings — ~/.claude/settings.json. Layering, low → high precedence:
  # opinionatedDefaults (when `opinionated`) < `settings` < module-owned
  # `statusLine`. recursiveUpdate merges nested attrs (e.g. env), so a
  # consumer's extra env keys survive alongside the curated defaults.
  mkSettings =
    {
      settings ? { },
      statusLineCommand ? null,
      opinionated ? false,
    }:
    let
      base = lib.optionalAttrs opinionated opinionatedDefaults;
      managed = lib.optionalAttrs (statusLineCommand != null) {
        statusLine = {
          type = "command";
          command = statusLineCommand;
          padding = 0;
        };
      };
    in
    pkgs.writeText "claude-drip-settings.json"
      (builtins.toJSON (lib.recursiveUpdate (lib.recursiveUpdate base settings) managed));
in
{
  inherit
    mkUpdater
    mkLauncher
    mkHint
    mkStatusBin
    mkSettings
    opinionatedDefaults
    ;
}
