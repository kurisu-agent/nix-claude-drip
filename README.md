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
  running session keeps working; the statusline shows `󰇚 <ver>` while
  downloading, then `󰜉 <ver>` (restart to apply).
- **Statusline.** `path · git · context% · effort · model · version · update-hint`.
- **Opinionated defaults** — a curated `settings.json` (see below), all overridable.
- **Runs anywhere with Nix.** NixOS host (the module, via `nix-ld`) or a glibc
  devcontainer (just the package — it runs on the system glibc loader, no
  patchelf).

## Opinionated defaults

On by default (`opinionatedDefaults = true`), layered *under* your own `settings`:

| key | value | |
|---|---|---|
| `effortLevel` | `"high"` | persisted reasoning effort |
| `tui` | `"fullscreen"` | fullscreen renderer |
| `terminalProgressBarEnabled` | `true` | terminal taskbar progress |
| `skipDangerousModePermissionPrompt` | `true` | no bypass-mode confirm |
| `env.CLAUDE_CODE_EXPERIMENTAL_AGENT_TEAMS` | `"1"` | agent teams |
| `env.CLAUDE_CODE_NO_FLICKER` | `"1"` | flicker-free fullscreen |
| `env.CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC` | `"1"` | telemetry / Sentry / surveys off |

Plus two launcher-side knobs: **`hideAccount`** (`IS_DEMO=1` — hides your account
on the banner) and **`autoTrust`** (pre-trusts the cwd so the statusline runs
despite the hidden trust dialog). Override any single key via `settings`, or set
`opinionatedDefaults = false` for a clean slate.

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

`claude` is the self-updating launcher · `claude-update` forces a check ·
`claude-hint` prints just the update indicator (for your own statusline).
