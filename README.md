# no-sleeping-on-the-job

Keeps your computer awake while [Claude Code](https://claude.com/claude-code) is actually working, and lets it sleep again as soon as Claude is idle. Closing the lid still follows your normal lid behavior.

Works on macOS and Windows. Each platform has its own folder and a single-file installer.

## macOS

### Install

```bash
curl -fsSL https://raw.githubusercontent.com/kaheitzei/no-sleeping-on-the-job/master/macos/install.sh -o install.sh
bash install.sh
```

One file, nothing else to fetch. It will:

1. Write `prevent-sleep.sh` and `allow-sleep.sh` to `~/.claude/hooks/` (executable).
2. Wire them into `~/.claude/settings.json` as `UserPromptSubmit`/`PreToolUse` (acquire) and `Stop`/`SessionEnd` (release) hooks. It merges into what's already in that file instead of overwriting it, and makes a timestamped backup (`settings.json.bak-<epoch>`) first if the file exists.
3. Do nothing new if you run it again and the hooks are already wired up.

Start a new Claude Code session afterwards so it picks up the hooks.

### Uninstall

```bash
bash install.sh --uninstall
```

Removes exactly the hook entries this installer added (matched by script path) and deletes the two scripts. Everything else in `settings.json` is left alone.

### Verify

While a Claude Code session is running:

```bash
pmset -g assertions | grep caffeinate
```

Debug log (written to `/tmp/claude_caffeinate/hooks.log`): `touch ~/.claude/hooks/.sleep-debug` to turn it on, `rm ~/.claude/hooks/.sleep-debug` to turn it off.

### How it works

- `prevent-sleep.sh` runs on `UserPromptSubmit` and `PreToolUse` and holds one `caffeinate -dimsu` process per Claude session (PID in `/tmp/claude_caffeinate/<session_id>.pid`). Once the lock is held, each call is a cheap no-op. It refreshes the lock periodically and sweeps stale PID files left by crashed sessions.
- `allow-sleep.sh` runs on `Stop`. Instead of releasing right away, it starts a small watcher that polls `pmset -g assertions` for the Claude desktop app's own "keep awake while Claude works" assertion. It releases the `caffeinate` lock once that assertion is gone, or after a 6-hour cap. On `SessionEnd` it releases right away.
- Everything is per session and silent, and every hook always exits `0`.

## Windows

### Install

In PowerShell:

```powershell
irm https://raw.githubusercontent.com/kaheitzei/no-sleeping-on-the-job/master/windows/install.ps1 | iex
```

Or download [`windows/install.ps1`](windows/install.ps1) and run:

```powershell
powershell -ExecutionPolicy Bypass -File install.ps1
```

It writes four scripts to `%USERPROFILE%\.claude\hooks\` and wires the same four hook events into `%USERPROFILE%\.claude\settings.json`. Like the macOS installer, it merges, backs up, and skips hooks that are already there. Each hook runs as `powershell.exe -NoProfile -ExecutionPolicy Bypass -File "<path>"`, which works whether Claude Code runs hooks through cmd or Git Bash.

### Uninstall

```powershell
powershell -ExecutionPolicy Bypass -File install.ps1 -Uninstall
```

### Verify

`powercfg /requests` (from an **elevated** prompt) lists a `powershell.exe` entry under `DISPLAY` and `SYSTEM` while Claude is working.

Debug log (written to `%TEMP%\claude_awake\hooks.log`): `New-Item ~\.claude\hooks\.sleep-debug` to turn it on, `Remove-Item ~\.claude\hooks\.sleep-debug` to turn it off.

### How it works

- `keep-awake.ps1` plays the role of `caffeinate`. It's a hidden PowerShell process that calls `SetThreadExecutionState(ES_CONTINUOUS | ES_SYSTEM_REQUIRED | ES_DISPLAY_REQUIRED)` and exits after a TTL (default 1 h). Killing it drops the request right away.
- `prevent-sleep.ps1` keeps one such holder per session. It tracks the holder in `%TEMP%\claude_awake\<session_id>.pid` as PID + process start time, so a reused PID is never mistaken for it. It refreshes the holder every 30 min.
- `allow-sleep.ps1` mirrors the macOS logic. On `Stop` it starts a hidden watcher that keeps the holder alive while the Claude app has a power request open, and on `SessionEnd` it releases right away. A per-session named mutex serializes start, refresh and release.
- `common.ps1` holds the helpers both hooks share.

### Windows limitations

- **Background work after a turn ends is only covered when Claude Code runs elevated.** Windows exposes other apps' power requests only through `powercfg /requests`, which needs administrator rights. Without them the watcher finds no signal and releases at `Stop`, like a CLI-only session on macOS. The machine still stays awake for the whole active turn.
- Every hook call starts PowerShell, which takes about 0.7 s on each `PreToolUse`. The macOS hooks take a few milliseconds.

## Repo layout

```
macos/
  hooks/prevent-sleep.sh, hooks/allow-sleep.sh   hook sources
  install.sh.template, build.sh                  build.sh embeds hooks/ into install.sh
  install.sh                                     generated single-file installer
windows/
  hooks/*.ps1                                    hook sources
  install.ps1.template, build.ps1                build.ps1 embeds hooks\ into install.ps1
  install.ps1                                    generated single-file installer
```

After editing anything in `hooks/`, rerun that platform's build script (`./build.sh` or `powershell -File build.ps1`). Don't hand-edit the generated installers.
