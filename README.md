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
2. Wire them into `~/.claude/settings.json` as `UserPromptSubmit`/`PreToolUse` (acquire) and `Stop`/`SessionEnd` (release) hooks. It merges into what's already in that file instead of overwriting it. Before writing it makes a timestamped backup (`settings.json.bak-<epoch>`), then replaces the file atomically. A symlinked `settings.json` stays a symlink.
3. Leave `settings.json` untouched if you run it again and the hooks are already there, including hooks you set up by hand with the `$HOME/.claude/hooks/...` paths.

If `settings.json` isn't valid JSON or has an unexpected shape, it stops with a message before changing anything.

Start a new Claude Code session afterwards so it picks up the hooks.

### Uninstall

```bash
bash install.sh --uninstall
```

Removes exactly this project's hook entries (matched by script path), stops any running watchers and `caffeinate` holders, and deletes the two scripts. Everything else in `settings.json` is left alone.

### Verify

While a Claude Code session is running:

```bash
pmset -g assertions | grep caffeinate
```

Debug log (written to `/tmp/claude_caffeinate/hooks.log`): `touch ~/.claude/hooks/.sleep-debug` to turn it on, `rm ~/.claude/hooks/.sleep-debug` to turn it off.

### How it works

- `prevent-sleep.sh` runs on `UserPromptSubmit` and `PreToolUse` and holds one `caffeinate -dimsu` process per Claude session (PID in `/tmp/claude_caffeinate/<session_id>.pid`). Once the lock is held, each call is a cheap no-op. `caffeinate` exits on its own after 1 h, and any hook call (or watcher poll) that finds it older than 30 min starts a fresh one. It also sweeps stale PID files left by crashed sessions.
- `allow-sleep.sh` runs on `Stop`. Instead of releasing right away, it starts a small watcher that polls `pmset -g assertions` every 20 s for the Claude desktop app's own "keep awake while Claude works" assertion. It releases the `caffeinate` lock once that assertion is gone, or after a 6-hour cap. The next `UserPromptSubmit` stops the watcher, so it can't release the new turn's lock. On `SessionEnd` it releases right away.
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

It writes four scripts to `%USERPROFILE%\.claude\hooks\` and wires the same four hook events into `%USERPROFILE%\.claude\settings.json`. It works like the macOS installer: it merges, backs up before writing, replaces the file atomically, writes nothing on a re-run, and stops with a message if the file can't be edited safely. It writes plain 2-space JSON and leaves non-ASCII text and characters like `<`, `>` and `'` as they are. Each hook runs as `powershell.exe -NoProfile -NonInteractive -ExecutionPolicy Bypass -File "<path>"`, which works whether Claude Code runs hooks through cmd or Git Bash.

### Uninstall

```powershell
powershell -ExecutionPolicy Bypass -File install.ps1 -Uninstall
```

Removes this project's hook entries, stops running watchers and holders, and deletes the four scripts.

### Verify

`powercfg /requests` (from an **elevated** prompt) lists a `powershell.exe` entry under `DISPLAY` and `SYSTEM` while Claude is working.

Debug log (written to `%TEMP%\claude_awake\hooks.log`): `New-Item ~\.claude\hooks\.sleep-debug` to turn it on, `Remove-Item ~\.claude\hooks\.sleep-debug` to turn it off.

### How it works

- `keep-awake.ps1` plays the role of `caffeinate`. It's a hidden PowerShell process that calls `SetThreadExecutionState(ES_CONTINUOUS | ES_SYSTEM_REQUIRED | ES_DISPLAY_REQUIRED)` and exits after a TTL (default 1 h). Killing it drops the request right away.
- `prevent-sleep.ps1` keeps one such holder per session. It tracks the holder in `%TEMP%\claude_awake\<session_id>.pid` as PID + process start time, so a reused PID is never mistaken for it. Any hook call (or watcher poll) that finds the holder older than 30 min replaces it.
- `allow-sleep.ps1` mirrors the macOS logic. On `Stop`, if Claude Code runs elevated, it starts a hidden watcher. Every 20 s the watcher checks whether the Claude desktop app (`WindowsApps\Claude_*\app\claude.exe`, not the CLI) still has a `SYSTEM` or `EXECUTION` power request open, and keeps the holder alive while it does, up to a 6-hour cap. Unelevated, it releases at `Stop` right away. The next `UserPromptSubmit` stops any watcher, and `SessionEnd` releases right away. A per-session named mutex serializes start, refresh and release.
- `common.ps1` holds the helpers both hooks share.

### Windows limitations

- **Background work after a turn ends is only covered when Claude Code runs elevated.** Windows exposes other apps' power requests only through `powercfg /requests`, which needs administrator rights. Without them the hooks release at `Stop`, like a CLI-only session on macOS. The machine still stays awake for the whole active turn.
- Elevated, the app's request is app-wide, just like on macOS: another busy session (or audio playing in the app) can keep this session's watcher holding on, up to the 6-hour cap.
- Every hook call starts PowerShell, which takes about 0.7 s on each `PreToolUse`. The macOS hooks take a few milliseconds.
- On PCs that lock PowerShell into Constrained Language Mode (AppLocker/WDAC), `keep-awake.ps1` can't call the Windows API and the hooks do nothing. The installer warns about this, and the debug log records it.

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

After editing anything in `hooks/`, rerun that platform's build script (`bash macos/build.sh` or `powershell -File windows\build.ps1`). Don't hand-edit the generated installers.
