# nix-claude-drip

Always-fresh [Claude Code](https://claude.com/claude-code) for Nix.

Claude Code ships ~daily; nixpkgs and the node-bundle flakes lag behind. **drip**
keeps you on the latest by swapping the **native binary in place** — no
`nixos-rebuild` to update Claude — and surfaces the whole lifecycle in the
statusline.

> Why "drip"? A drip-feed of updates — you stay dripped out in the freshest Claude.

## What it does

- **Self-updating native binary.** Hourly check against Anthropic's release
  channel, SHA-256-verified download, atomic swap under `~/.claude/cc`. The
  running session keeps working; the statusline shows `󰇚 47%` while
  downloading, then `󰜉 <ver>` (restart to apply).
- **Statusline.** `path · git · model · context% · effort · version · update-hint`,
  with the model tinted by family — mauve **fable**, red **opus**, yellow
  **sonnet**, sky **haiku** — so which one you're on reads at a glance.
- **Fleet-friendly.** Point `releaseBase` at a mirror — or at the pull-through
  cache module in this flake — and the ~262 MiB binary crosses the WAN once
  per release instead of once per machine.
- **Opinionated defaults** — a curated `settings.json` (see below), all overridable.
- **The agent workstation, one knob each.** `services.claude-code.gumbo`
  brings up the multi-account gateway and its `yolo` launcher;
  `services.claude-code.herdr` installs the pinned
  [herdr](https://herdr.dev) with
  [herdr-drip](https://github.com/kurisu-agent/herdr-drip)'s plugins, hook
  keepalive and source patches. Sections below.
- **Runs anywhere with Nix.** NixOS host (the module, via `nix-ld`) or a glibc
  devcontainer (just the package — it runs on the system glibc loader, no
  patchelf).

## Update indicator

The last statusline segment is the updater's lifecycle, one glyph per state:

| hint | state | |
|---|---|---|
| | idle | nothing appended — you're on the latest |
| `󰚰` | checking | reading the channel pointer and manifest |
| `󰇚 47%` | downloading | transfer in flight (bare `󰇚` if the size is unknown) |
| `󰕥` | verifying | bytes in, SHA-256 running |
| `󰜉 1.2.3` | staged | new version on disk — restart to apply |
| `󰀪` | error | checksum mismatch, or a fetch that failed after connecting |
| `󰅤` | offline | channel unreachable |

Precedence is `downloading > verifying > staged > error > offline > checking`, so
a pending restart is never masked by a later failed fetch.

**The percentage is a number that moves, not a bar** — there is deliberately no
progress bar, the row is width-constrained. It repaints at
`statusLine.refreshInterval` (default 1s), which is a floor: ~262 MiB over a
9 MB/s link is ~29 seconds, so ~29 visible steps, and on a very fast link you
get a handful and then `󰕥`. A transfer whose updater was killed mid-flight
(SIGKILL, suspend) can't write a closing state, so a percentage whose heartbeat
goes 45s stale turns red — a frozen number never passes for a live one.

## Opinionated defaults

On by default (`opinionatedDefaults = true`), layered *under* your own `settings`:

| key | value | |
|---|---|---|
| `effortLevel` | `"xhigh"` | persisted reasoning effort |
| `tui` | `"fullscreen"` | fullscreen renderer |
| `terminalProgressBarEnabled` | `true` | terminal taskbar progress |
| `skipDangerousModePermissionPrompt` | `true` | no bypass-mode confirm |
| `env.CLAUDE_CODE_EXPERIMENTAL_AGENT_TEAMS` | `"1"` | agent teams |
| `env.CLAUDE_CODE_NO_FLICKER` | `"1"` | flicker-free fullscreen |
| `env.CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC` | `"1"` | telemetry / Sentry / surveys off |
| `extraKnownMarketplaces` | `claude-plugins-official` | official Anthropic plugin marketplace |
| `enabledPlugins` | `skill-creator`, `feature-dev` | official skills, in every project |

Plus two launcher-side knobs: **`hideAccount`** (`IS_DEMO=1` — hides your account
on the banner) and **`autoTrust`** (pre-trusts the cwd so the statusline runs
despite the hidden trust dialog). Override any single key via `settings`, or set
`opinionatedDefaults = false` for a clean slate.

## Plugins & skills

Official Anthropic skills arrive the same way the binary does: **declared in
nix, fetched by Claude itself**. The defaults enable `skill-creator` and
`feature-dev` from the official marketplace via settings.json's
`enabledPlugins`; Claude Code clones the marketplace under `~/.claude/plugins`
and serves the skills to every project — nothing vendored into the nix store,
no flake pin going stale. Add more with the module's `plugins` /
`marketplaces` options, or veto a default per key
(`settings.enabledPlugins."feature-dev@claude-plugins-official" = false`).

One interaction to know: `CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC=1` (also an
opinionated default) turns off Claude's plugin auto-update check along with
telemetry, so an installed marketplace clone refreshes only when you run
`/plugin marketplace update` in a session.

**beads** — the git-backed issue tracker / memory for coding agents — is one
knob away (`beads = true`, off by default): the pair that only works
together, nixpkgs' `bd` CLI on PATH and the official
`beads@beads-marketplace` plugin (slash commands, skills, `bd prime` on
session start and pre-compaction), the plugin fetched fresh by Claude like
the rest. Skip `bd setup claude` — the plugin already carries the hooks.

## gumbo — the multi-account gateway

[gumbo](https://github.com/kurisu-agent/gumbo) pools several Claude accounts (and
Anthropic-compatible upstreams) behind one loopback listener, picking an account
per launch by 5h/7d headroom. drip **pins gumbo as a flake input and imports its
module**, so one knob is the whole thing:

```nix
services.claude-code.gumbo.enable = true;
```

That brings up `services.gumbo` — the daemon, its rendered `config.toml`, the
`gumbo` CLI on PATH — *and* the client half: `yolo` becomes a function that mints
a per-launch session key, stamps it as `X-Gumbo-Session` so the launch sticks to
one account, and points that one claude at the gateway. Off by default: with the
knob unset the module is imported but inert, and nothing about a drip host
changes.

Accounts, providers, routes and aliases are gumbo's own options
(`services.gumbo.providers`, `.routes`, `.aliases`); credentials are registered
out of band with `gumbo login` and never live in nix. `yolo kimi` resolves an
alias's model + env through `gumbo resolve`.

| key | default | |
|---|---|---|
| `enable` | `false` | client wiring + the daemon |
| `serve` | `true` | set `false` for client-only — the gateway is bound elsewhere |
| `addr` | `services.gumbo.listen.localAddr` | where the HTTP traffic goes; follows the daemon's local door |
| `daemon` | `services.gumbo.listen.ownerSocket` | the CONTROL door the CLI verbs ask; `null` = let the binary find it (a kart) |
| `global` | `false` | `true` routes *every* claude, not just `yolo` |
| `yoloOnPath` | `false` | `yolo` as a real command too, for launchers that never source a profile |
| `sessionStatusline` | `true` | appends `account · 5h N% · 7d N% left`, time-boxed and fail-open |
| `package` | `services.gumbo.package` | `null` means "expect `gumbo` on PATH" |

**gumbo is a private repo**, so evaluating this flake — or anything that pins it
— needs GitHub credentials in `access-tokens`. Without access,
`inputs.nix-claude-drip.inputs.gumbo.follows` it away and supply
`services.claude-code.gumbo.package` yourself.

## herdr — the workspace manager, with its drip

Same one-knob idea for [herdr](https://herdr.dev):

```nix
services.claude-code.herdr.enable = true;
```

That installs the herdr this flake pins (`packages.<system>.herdr` forwards
the same node) and enables both of
[herdr-drip](https://github.com/kurisu-agent/herdr-drip)'s modules:
claude-agent-state, which keeps herdr's SessionStart hook alive across the
settings.json overwrite this module performs, and plugins, which keeps the
drip's plugins installed pinned to the herdr-drip input's rev with the
curated config and `yolo-shell` + `bun` on the server's PATH. Both
sub-enables are `mkDefault`, so `services.herdr-drip.*` options can pare
either half back; `herdr.package` overrides which herdr build the host runs
(the drip modules resolve herdr from PATH and follow it).

herdr-drip's **hardcore plugins** — its source-patch set for what herdr has
no plugin surface for — are applied to `herdr.package` by default, downstream
of the package choice, so an overriding host supplies an unpatched build and
still gets the set. `herdr.dripPatches = false` opts out.

## Use it

NixOS module:

```nix
# inputs.nix-claude-drip.url = "github:kurisu-agent/nix-claude-drip";
imports = [ nix-claude-drip.nixosModules.default ];
services.claude-code.enable = true;
```

Anywhere (`nix profile`, e.g. inside a container):

```
nix profile install github:kurisu-agent/nix-claude-drip
```

## Fleets

Claude Code ships ~daily and the binary is ~262 MiB, so every machine pulling
its own copy is the same download over and over. `releaseBase` moves where the
updater looks — channel pointer, manifest and binary all hang off it.

`nixosModules.cache` is a mirror you can point it at: a dumb nginx pull-through
cache with **no timer, no polling and no knowledge of versions, manifests or
checksums**. Clients keep their existing fetch path and still verify the
SHA-256 themselves, so rollback is pointing `releaseBase` back at upstream. It
isn't imported by `nixosModules.default` — a client doesn't need an nginx
option surface, and a cache host doesn't need Claude Code.

```nix
# the cache host
imports = [ nix-claude-drip.nixosModules.cache ];
services.claude-code-cache = {
  enable = true;
  listenAddress = "0.0.0.0";  # loopback by default; it's plain HTTP with no auth
  openFirewall = true;
};

# every client
services.claude-code.releaseBase = "http://cache.example.net:8502";
```

| key | default | |
|---|---|---|
| `listenAddress` / `port` | `"127.0.0.1"` / `8502` | its own socket, no name-based routing |
| `upstream` | the Anthropic channel | point it at another cache to chain them |
| `cacheDir` | `/var/cache/claude-code-cache` | created and unsandboxed for nginx |
| `maxSize` / `inactive` | `"2g"` / `"7d"` | disuse reclaims; the size cap is a backstop |
| `channelTtl` | `"1m"` | how fast the fleet notices a release |
| `channels` | `[ "latest" "stable" ]` | anything else is cached as immutable |

Two more knobs on the client module:

| key | default | |
|---|---|---|
| `prefetch` | `false` | fetch once at boot, per user in `users`, so nobody's first `claude` blocks on ~262 MiB |
| `statusLine.refreshInterval` | `1` | seconds per statusline repaint; `null` omits the key |

`prefetch` is orthogonal to `updateTimer` — one-shot at boot versus recurring
refresh, same lock, enable either or both — and like the timer it needs `users`.
Raise `refreshInterval` (or set it to `null`) if you swap in a slow custom
`statusLine.command`: a command that outlives the interval is aborted by the
next tick and renders *nothing*.

**No systemd user manager? Set `users`.** `settings.json` normally arrives via
user activation, which is a `systemd --user` unit — so it never runs on a host
where no user manager is started: sshd with `UsePAM = false`, a container, an
image with no logind. The symptom is lopsided rather than obviously missing:
onboarding and trust look fine (they're launcher-side), while everything that
lives only in `settings.json` — the fullscreen TUI, the statusline,
`effortLevel`, the env defaults — silently doesn't happen. Naming users in
`users` installs the same file from a system unit too, which needs no session.

`claude` is the self-updating launcher · `claude-update` forces a check ·
`claude-hint` prints just the update indicator (for your own statusline).
