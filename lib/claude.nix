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
          "0" = 0;
          "1" = 1;
          "2" = 2;
          "3" = 3;
          "4" = 4;
          "5" = 5;
          "6" = 6;
          "7" = 7;
          "8" = 8;
          "9" = 9;
          "a" = 10;
          "A" = 10;
          "b" = 11;
          "B" = 11;
          "c" = 12;
          "C" = 12;
          "d" = 13;
          "D" = 13;
          "e" = 14;
          "E" = 14;
          "f" = 15;
          "F" = 15;
        }
        .${c};
      hexByte = s: 16 * (hexDigit (builtins.substring 0 1 s)) + (hexDigit (builtins.substring 1 1 s));
      stripHash =
        s:
        if builtins.substring 0 1 s == "#" then builtins.substring 1 (builtins.stringLength s - 1) s else s;
    in
    hex:
    let
      h = stripHash hex;
    in
    "${toString (hexByte (builtins.substring 0 2 h))};${
      toString (hexByte (builtins.substring 2 2 h))
    };${toString (hexByte (builtins.substring 4 2 h))}";

  ccHome = "$HOME/.claude/cc";

  # Upstream release channel. Only a default — mkUpdater takes a
  # `releaseBase` argument, see there for why anyone would move it.
  defaultReleaseBase = "https://downloads.claude.ai/claude-code-releases";

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
  dimSeq = if variant == "latte" then "\\033[38;2;${hexToRgbCsv palette.muted}m" else "\\033[2m";

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
  # of unused-var (SC2034) noise. DIM is in here (built the same
  # variant-aware way colorVars builds it) because the two quiet states,
  # offline and checking, are deliberately rendered in the muted colour: they
  # are status, not news, and shouldn't pull the eye the way a staged restart
  # or a failed fetch should.
  hintColors = ''
    RESET=$'\033[0m'
    SUCCESS=$'\033[38;2;${hexToRgbCsv palette.success}m'
    WARNING=$'\033[38;2;${hexToRgbCsv palette.warning}m'
    ERROR=$'\033[38;2;${hexToRgbCsv palette.error}m'
    DIM=$'${dimSeq}'
  '';

  # Update indicator. Assumes `running`, RESET, DIM, WARNING, SUCCESS, ERROR
  # are set; fires the gated hourly check, then sets `hint` to the glyph for
  # whatever the updater is doing, or "" when there is nothing to say.
  # Precedence, highest first:
  #   downloading > verifying > staged-restart > error > offline > checking
  # A transfer in flight leads because it is the only state whose render
  # changes second to second. Below it, a real pending restart is never
  # masked by a later failed fetch — the binary is already on disk and one
  # keystroke away, and a fetch that failed after that can wait for the next
  # hourly check. The two quiet states sit at the bottom because neither asks
  # anything of the user.
  hintFragment =
    {
      updaterBin,
      checkInterval,
      autoCheck ? true,
    }:
    ''
      CC_HOME="${ccHome}"

      # One wall-clock read, two consumers: the gate on the periodic check
      # just below, and the staleness test on the download heartbeat further
      # down — which runs whether or not that check is enabled.
      now=$(date +%s)
      ${lib.optionalString autoCheck ''
        stamp="$CC_HOME/.lastcheck"
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

      # One jq call for the whole file — status, target, the download
      # percentage and the heartbeat — joined on US (\x1f) rather than tabs,
      # for the same reason the statusline does it: tab is IFS-whitespace, so
      # `read` would collapse an empty leading field and shift every value
      # one slot left. `.pct` is null except mid-transfer, and jq's `//` only
      # treats null/false as empty, so a genuine 0 survives as "0".
      IFS=$'\x1f' read -r status target pct tick < <(jq -r '[.status // "", .target // "", (.pct // "" | tostring), (.tick // 0 | tostring)] | join("")' "$CC_HOME/state.json" 2>/dev/null) || true
      ondisk=""
      [ -L "$CC_HOME/current" ] && ondisk="$(basename "$(readlink "$CC_HOME/current")")"

      # state.json is written by a process we do not control the vintage of
      # (an older claude-drip's updater knew neither field, and the file
      # survives an upgrade), so neither number is trusted: anything that
      # isn't a plain integer becomes "wasn't told" instead of reaching the
      # arithmetic below, where it would abort the script and leave the whole
      # statusline blank.
      case $pct in
        *[!0-9]*) pct="" ;;
      esac
      case $tick in
        "" | *[!0-9]*) tick=0 ;;
      esac

      hint=""
      if [ "$status" = downloading ] && is_newer "$target" "$running"; then
        # An updater that is SIGKILLed — or whose laptop suspends — mid
        # transfer never gets to write a closing state, so `downloading` can
        # outlive the process that meant it and the percentage would sit
        # there looking live forever. `tick` is restamped on every progress
        # write, which the updater throttles to ~2 Hz, so a heartbeat older
        # than 45 s is ~90 missed writes: still worth showing (it is the last
        # thing that actually happened) but in the error colour, so it reads
        # as a corpse rather than as progress.
        #
        # `tick > 0` FIRST, and it is the upgrade path rather than paranoia.
        # A state.json written by an OLDER claude-drip carries no heartbeat at
        # all, so it normalises to 0 just above; without this test the first
        # render after an upgrade dates that file to 1970 and paints a
        # perfectly healthy transfer red. "Was never told" is not evidence of
        # death — the field exists to catch a writer that was KILLED, and a
        # writer that never stamped one cannot be judged by it.
        if [ "$tick" -gt 0 ] && [ $((now - tick)) -gt 45 ]; then
          dl="$ERROR"
        else
          dl="$WARNING"
        fi
        # No version here, and no progress bar: the row is width-constrained
        # and the version is about to be spelled out by the staged hint that
        # replaces this one. An unknown percentage (null, or a transfer whose
        # total size the server never declared) degrades to the bare icon —
        # "something is coming down" is still worth saying.
        if [ -n "$pct" ]; then
          hint="''${dl}󰇚 ''${pct}%''${RESET}"
        else
          hint="''${dl}󰇚''${RESET}"
        fi
      elif [ "$status" = verifying ] && is_newer "$target" "$running"; then
        # Same transfer, one step later — gated on the same comparison so the
        # row doesn't blink into existence for a download that was never
        # going to be shown in the first place.
        hint="''${WARNING}󰕥''${RESET}"
      elif is_newer "$ondisk" "$running"; then
        hint="''${SUCCESS}󰜉 ''${ondisk}''${RESET}"
      elif [ "$status" = error ]; then
        hint="''${ERROR}󰀪''${RESET}"
      elif [ "$status" = offline ]; then
        hint="''${DIM}󰅤''${RESET}"
      elif [ "$status" = checking ]; then
        hint="''${DIM}󰚰''${RESET}"
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
      # Root of the release-channel layout the updater walks: <base>/<channel>
      # is the pointer, <base>/<ver>/manifest.json the checksums, and
      # <base>/<ver>/<platform>/claude the ~262 MiB binary itself. It is an
      # argument because that binary is the same bytes for every machine that
      # tracks the same channel: a site that runs more than one of them can
      # mirror the layout locally and point this at the mirror, so the payload
      # crosses the WAN once instead of once per host per release. Anything
      # serving those three paths works — the updater only does GETs and
      # verifies the checksum out of the manifest either way, so a mirror is
      # never trusted more than the origin is.
      releaseBase ? defaultReleaseBase,
    }:
    let
      # An unresolvable version means different things on the two paths into
      # `latest`, and the difference matters to the user: a channel pointer
      # that comes back empty or unparseable means the far end wasn't
      # reachable (DNS, captive portal, a laptop on a train), which fixes
      # itself and should stay quiet — `offline`. A pinned version that isn't
      # a version number is a configuration mistake that will never resolve on
      # its own, so it gets the loud state.
      unresolved = if pinVersion != null then "error" else "offline";
    in
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

        # write_state <status> <target> <ondisk> [pct]
        #
        # The whole document is rewritten and moved into place, so a reader
        # never catches a half-written file. The fourth argument is the
        # download percentage and is optional: omitted (or empty) it lands as
        # JSON null rather than 0, which is the difference between "no idea
        # how far along this is" and "nothing has arrived yet" — the hint
        # renders those differently.
        #
        # `tick` is restamped on EVERY write, progress updates included,
        # because it is the only evidence that this process is still alive. An
        # updater that is killed mid-transfer cannot write a closing state, so
        # without a heartbeat the last percentage it managed to write would
        # stand as current forever. `checked_at` is untouched in meaning — it
        # has always been "when this state was written" — and stays for
        # anything already reading it.
        write_state() {
          jq -n --arg status "$1" --arg target "$2" --arg ondisk "$3" \
            --arg pct "''${4:-}" \
            --argjson at "$(date +%s)" \
            '{status:$status, target:$target, ondisk:$ondisk,
              pct: (if $pct == "" then null else ($pct | tonumber) end),
              tick:$at, checked_at:$at}' \
            > "$STATE.tmp" && mv -f "$STATE.tmp" "$STATE"
        }

        ondisk=""
        if [ -L "$CURRENT" ]; then
          ondisk="$(basename "$(readlink "$CURRENT")")"
        fi

        # Everything up to the manifest is small, quick network work — a
        # pointer of a few bytes and a JSON document — so it all reports as
        # one state. The user does not need "fetching the pointer" and
        # "fetching the manifest" told apart; they need to know the updater is
        # talking to the release channel rather than idle.
        write_state checking "" "$ondisk"

        ${
          if pinVersion != null then
            "latest=${lib.escapeShellArg pinVersion}"
          else
            ''latest="$(curl -fsSL --max-time 10 "$base/${channel}" || true)"''
        }
        if ! printf '%s' "$latest" | grep -qE '^[0-9]+\.[0-9]+\.[0-9]+'; then
          write_state ${unresolved} "" "$ondisk"
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

        manifest="$(curl -fsSL --max-time 10 "$base/$latest/manifest.json" || true)"
        checksum="$(printf '%s' "$manifest" | jq -r --arg p "$platform" '.platforms[$p].checksum // empty' 2>/dev/null || true)"
        # The manifest also carries the payload's exact byte count — the same
        # number the transfer reports as Content-Length — so the expected size
        # costs one more jq field over a document already in a variable, and
        # never a HEAD request of its own. `// 0` plus the digit guard mean
        # "the manifest didn't say", which disables the check that uses it
        # rather than failing the update.
        size="$(printf '%s' "$manifest" | jq -r --arg p "$platform" '.platforms[$p].size // 0' 2>/dev/null || true)"
        case $size in
          "" | *[!0-9]*) size=0 ;;
        esac
        if ! printf '%s' "$checksum" | grep -qE '^[a-f0-9]{64}$'; then
          write_state error "$latest" "$ondisk"
          exit 0
        fi

        tmp="$VERS/.$latest.tmp"
        rm -rf "$tmp"
        mkdir -p "$tmp"

        write_state downloading "$latest" "$ondisk"

        # On the timeouts. The old flag here was `--max-time 300`, a
        # wall-clock cap on the entire transfer — and the payload is ~262 MiB,
        # so 262 MiB in 300 s is a floor of ~0.92 MB/s. Any link slower than
        # that was guaranteed to be cut off part-way through and reported as a
        # failure indistinguishable from a real one: hotel wifi looked exactly
        # like a corrupt release. What we actually want to detect is a
        # transfer that has STOPPED, so:
        #   --connect-timeout 10   still fails fast when nothing answers
        #   --speed-limit 4096
        #   --speed-time 120       abort only after 120 s under 4 KB/s
        #   --max-time 1800        backstop for a link that crawls at exactly
        #                          enough speed to never trip the stall test
        # Do not put a wall-clock cap sized for a fast link back.
        #
        # WHY --speed-time IS 120 AND NOT SOMETHING TIGHTER. curl's low-speed
        # test starts counting as soon as the request is in flight, NOT once
        # the body starts — so a response that has not begun arriving is
        # "0 bytes/sec" as far as this test is concerned. That matters because
        # the obvious thing to put in front of this updater is a caching proxy,
        # and a caching proxy's whole trick for a fleet is to make the second
        # through Nth client WAIT, silently and with no bytes at all, while the
        # first one populates the entry. Measured directly: against a server
        # that withheld its response headers, this curl carrying the ORIGINAL
        # `--speed-time 30` aborted at exactly 30 s
        # with "Operation too slow", which would have killed precisely the
        # queued clients such a proxy exists to serve. 120 s leaves room for a
        # proxy to hold a client through a large upstream fetch and still
        # detects a genuinely dead link inside the same session. The sibling
        # `services.claude-code-cache` module pins its own lock windows well
        # under this figure for the same reason; the two numbers are a pair,
        # and neither should be moved without the other.
        #
        # On the progress meter. curl already counts the bytes, so the
        # percentage is free — no second request, no byte-counting loop of our
        # own — but reading it back has several sharp edges, every one of them
        # found the hard way:
        #   * `-fsSL` cannot be used: the `-s` in it silences the meter. `-fL
        #     --no-silent --progress-bar` keeps the fail-on-HTTP-error and the
        #     redirect-following of the old flags and asks for the meter
        #     explicitly.
        #   * The meter goes to stderr as \r-terminated records at ~4.8 Hz,
        #     each ending in a percentage. `2>&1 >/dev/null` puts stderr alone
        #     on the pipe: stdout is already the pipe by the time redirections
        #     are applied, so this reads backwards but is right, and it is the
        #     one ordering shellcheck exempts from SC2069.
        #   * The final record — the 100.0% one — ends with \n, not \r, so
        #     `read -d $'\r'` returns non-zero having still filled `rec`.
        #     Without `|| [ -n "$rec" ]` the download visibly stops at 99%.
        #     That newline is then part of the record (read only strips the
        #     delimiter it was given, and \n isn't it), so it has to come off
        #     before the `%` test below or the record is dropped anyway and
        #     the last thing shown is whatever curl drew a fifth of a second
        #     before the end.
        #   * Only records ending in `%` are progress. curl writes its
        #     failures to the same stream ("#=#=#   curl: (22) The requested
        #     URL returned error: 404"), whose last field is "404" — a
        #     perfectly plausible-looking percentage. The `*%` guard drops
        #     those, and the <= 100 clamp is the backstop. That same guard is
        #     what handles a server that declares no size: curl then draws
        #     "#=#=#" with no percentage at all, nothing is written, and the
        #     hint keeps rendering the bare icon. No separate branch needed.
        #   * Writes are throttled to ~2 Hz off $EPOCHREALTIME — bash's own
        #     clock, so no `date` fork per record. Unthrottled, one 262 MiB
        #     transfer rewrites state.json ~150 times to move a number that
        #     has 100 values.
        #   * The loop is the tail of a pipeline and so runs in a subshell:
        #     nothing it assigns survives it. That is fine, because its entire
        #     job is to write a file.
        last_us=0
        if ! curl -fL --no-silent --progress-bar \
              --connect-timeout 10 --speed-limit 4096 --speed-time 120 --max-time 1800 \
              -o "$tmp/claude" "$base/$latest/$platform/claude" 2>&1 >/dev/null |
            while IFS= read -r -d $'\r' rec || [ -n "$rec" ]; do
              rec="''${rec%$'\n'}"

              # A percentage is OPTIONAL, and the record is a heartbeat either
              # way. Only records ending in `%` carry a number: curl draws a
              # bare `#=#=#` for a transfer whose length the server never
              # declared, and its FAILURE lines land on this same stream
              # ending in a bare number ("curl: (22) … error: 404"), which a
              # `''${rec##* }` would otherwise read as "404%".
              #
              # Keeping the two apart is the whole point of this shape. An
              # earlier cut `continue`d on any record without a `%`, which
              # meant a chunked transfer wrote NO state at all for its entire
              # length — so `tick` stayed frozen at the single write above,
              # and 45 s in, the statusline's staleness rule painted a
              # perfectly healthy 262 MiB download as a dead one. An unknown
              # percentage must degrade to "downloading, amount unknown", not
              # to "downloading, apparently deceased".
              p=""
              case $rec in
                *%)
                  p="''${rec##* }"
                  p="''${p%\%}"
                  p="''${p%%.*}"
                  case $p in
                    "" | *[!0-9]*) p="" ;;
                  esac
                  if [ -n "$p" ] && [ "$p" -gt 100 ]; then
                    p=""
                  fi
                  ;;
              esac

              # 100 is exempt from the throttle: it is the last thing the
              # meter will ever say, it lands within half a second of the
              # write before it more often than not, and if this process is
              # killed in the gap before `verifying` then whatever is left in
              # the file is what the user stares at.
              now_us=''${EPOCHREALTIME/[.,]/}
              if [ "$p" = 100 ] || [ $((now_us - last_us)) -ge 500000 ]; then
                last_us=$now_us
                write_state downloading "$latest" "$ondisk" "$p"
              fi
            done
        then
          rm -rf "$tmp"
          write_state error "$latest" "$ondisk"
          exit 0
        fi

        # The bytes are in; what is left is hashing 262 MiB, which takes long
        # enough on a tired disk to be worth saying out loud rather than
        # looking like a download wedged at 100%.
        write_state verifying "$latest" "$ondisk"

        # Cheap disqualifier first: a file the manifest's own byte count
        # disagrees with cannot possibly hash correctly — a truncated transfer
        # is the usual cause — so it fails here in microseconds instead of
        # after a full read of the file. Skipped entirely when the manifest
        # didn't give a size.
        if [ "$size" -gt 0 ] && [ "$(stat -c %s "$tmp/claude")" != "$size" ]; then
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
      runtimeInputs =
        with pkgs;
        [
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
    model = "claude-fable-5";
    effortLevel = "xhigh";
    skipDangerousModePermissionPrompt = true;
    disableClaudeAiConnectors = true;
    terminalProgressBarEnabled = true;
    tui = "fullscreen";
    env = {
      CLAUDE_CODE_EXPERIMENTAL_AGENT_TEAMS = "1";
      CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC = "1";
      CLAUDE_CODE_NO_FLICKER = "1";
    };
    # Anthropic's official plugins, by declaration only — Claude Code clones
    # the marketplace and plugin content itself under ~/.claude/plugins, so
    # nothing is vendored into the nix store and the content tracks upstream
    # instead of a flake pin. The marketplace entry uses the canonical name so
    # it merges with the copy Claude auto-registers on first interactive
    # launch rather than cloning twice; declaring it here keeps a headless
    # first run deterministic. Caveat: DISABLE_NONESSENTIAL_TRAFFIC above also
    # switches off Claude's plugin auto-update check, so an installed
    # marketplace clone refreshes only on `/plugin marketplace update`.
    extraKnownMarketplaces.claude-plugins-official.source = {
      source = "github";
      repo = "anthropics/claude-plugins-official";
    };
    enabledPlugins = {
      "skill-creator@claude-plugins-official" = true;
      "feature-dev@claude-plugins-official" = true;
    };
  };

  # mkSettings — ~/.claude/settings.json. Layering, low → high precedence:
  # opinionatedDefaults (when `opinionated`) < `settings` < module-owned
  # `statusLine`. recursiveUpdate merges nested attrs (e.g. env), so a
  # consumer's extra env keys survive alongside the curated defaults.
  #
  # `refreshInterval` (seconds) is what makes a moving number in the
  # statusline possible at all. Without it Claude re-runs the statusline
  # command only on conversation events — and those go quiet for exactly as
  # long as a background download runs, which is precisely when there is
  # something to watch: measured at 1 invocation in 25 s on an idle session,
  # so a percentage would be painted once and then sit there. With it set to
  # 1 the row is re-rendered every second with nobody typing at all (30
  # invocations in 30 s, 1.000 s apart).
  #
  # It is a cliff, not a slope, and that is the hazard: a statusline command
  # that takes LONGER than the interval is aborted by the next tick and
  # renders nothing — a 1.5 s script at interval 1 produced a permanently
  # blank row, not a slow one. Set it only for a command comfortably faster
  # than the interval. null (the default) emits byte-for-byte the
  # settings.json this produced before the option existed.
  mkSettings =
    {
      settings ? { },
      statusLineCommand ? null,
      opinionated ? false,
      refreshInterval ? null,
    }:
    let
      base = lib.optionalAttrs opinionated opinionatedDefaults;
      managed = lib.optionalAttrs (statusLineCommand != null) {
        statusLine = {
          type = "command";
          command = statusLineCommand;
          padding = 0;
        }
        // lib.optionalAttrs (refreshInterval != null) { inherit refreshInterval; };
      };
    in
    pkgs.writeText "claude-drip-settings.json" (
      builtins.toJSON (lib.recursiveUpdate (lib.recursiveUpdate base settings) managed)
    );
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
