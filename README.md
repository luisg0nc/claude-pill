# Claude Pill

<img width="270" height="193" alt="image" src="https://github.com/user-attachments/assets/7ca50cb1-bb24-4fde-939f-685be5f1ac59" />

A small Quickshell bar widget that surfaces Claude Code's session and weekly usage percentages. Like having `/status` always visible on your bar. Built for Hyprland on top of the end-4 / illogical-impulse dotfiles.

## What it shows

The collapsed pill is `✨ 50% · 7%`, where the first number is your session-window utilization and the second is the weekly utilization. Icon and text color shift through neutral, warning and error as you climb toward the cap.

Hover the pill for a popup with the full picture: subscription tier (Pro or Max), how long the OAuth token has left before it auto-refreshes, the session limit with reset time, the weekly limit with reset time, and the weekly Opus bucket if you have one.

If the OAuth token has expired the pill swaps the sparkle icon for a warning and the word "auth".

## How it works

The widget reads your existing Claude Code credentials from `~/.claude/.credentials.json` (the same file the `claude` CLI writes when you log in) and polls `https://api.anthropic.com/api/oauth/usage` with that token. That is the same endpoint the `/status` REPL command hits internally.

The response is cached on disk at `~/.local/state/quickshell/user/claude-usage-cache.json`. By default the network call only fires once every 10 minutes. There is also a hard 60 second floor that a manual refresh cannot bypass, because Anthropic's bucket does not refill any faster than that and there is nothing to gain from polling harder.

## Requirements

This is not a fully standalone Quickshell widget. The QML imports `qs.modules.common`, `qs.modules.common.widgets`, and `qs.services` from the end-4 illogical-impulse base config. You need those primitives in scope:

* Singletons: `Appearance`, `Config`, `Directories`, `FileUtils`
* Widgets: `StyledText`, `StyledPopup`, `StyledProgressBar`, `MaterialSymbol`, `BarGroup`

Plus:

* A working Claude Code install with `~/.claude/.credentials.json` present (run `claude` once and log in if you have not).
* `curl` on PATH.
* A Quickshell build that includes `Quickshell.Io` (for `Process` and `FileView`).

If you run a different Quickshell config you can lift the polling logic out of `services/ClaudeStatus.qml` since it has no end-4-specific dependencies of its own. The pill and popup are tied to the illogical-impulse widget set and would need their `StyledText` / `StyledPopup` / etc. replaced.

## Installing

Copy the three files into your config tree:

```
cp services/ClaudeStatus.qml             ~/.config/quickshell/ii/services/
cp modules/bar/ClaudeStatusIndicator.qml ~/.config/quickshell/ii/modules/bar/
cp modules/bar/ClaudeStatusPopup.qml     ~/.config/quickshell/ii/modules/bar/
```

Add a config block to `modules/common/Config.qml` inside the `bar` JsonObject:

```qml
property JsonObject claudeStatus: JsonObject {
    property bool enable: true
    property int fetchInterval: 600
    property string endpointOverride: ""
}
```

Wire the indicator into your bar. In the stock illogical-impulse layout this lives near the weather widget in `modules/bar/BarContent.qml`:

```qml
Loader {
    Layout.leftMargin: 4
    active: Config.options.bar.claudeStatus.enable
    visible: active
    sourceComponent: BarGroup {
        ClaudeStatusIndicator {}
    }
}
```

Reload Quickshell. On the stock illogical-impulse keybinds that is `Ctrl+Super+R`. The pill should appear immediately and start a first poll a moment later (or skip it and read the cache if you already have one from a previous session).

## Config

| Key | Default | Purpose |
|---|---|---|
| `bar.claudeStatus.enable` | `true` | Show or hide the pill. |
| `bar.claudeStatus.fetchInterval` | `600` | Seconds between polls. Soft floor only. |
| `bar.claudeStatus.endpointOverride` | `""` | Override the API URL if Anthropic ever moves it. |

These all live under `bar.claudeStatus` in `~/.config/illogical-impulse/config.json` once the schema block is in place. The 60 second hard floor lives in `ClaudeStatus.qml` as `minIntervalMs` and is intentionally not surfaced through config.

## Re-authenticating

The pill has no auth flow of its own. It reuses whatever token is in `~/.claude/.credentials.json`. If that token expires the pill shows "auth" and you log in again through Claude Code:

```
claude
/login
```

The pill watches the credentials file with `watchChanges: true`, so a successful re-login is picked up on the next poll without a shell reload.

## Debugging

```bash
# Is the token still valid?
jq -r '.claudeAiOauth | {expires_at_iso: (.expiresAt / 1000 | todate), expired: ((.expiresAt | tonumber) < (now * 1000))}' ~/.claude/.credentials.json

# When did the pill last successfully poll?
jq '{age_min: (((now*1000) - .fetched_at) / 60000 | floor), session: .data.five_hour.utilization, week: .data.seven_day.utilization}' ~/.local/state/quickshell/user/claude-usage-cache.json

# Hit the endpoint by hand
curl -sS \
  -H "Authorization: Bearer $(jq -r .claudeAiOauth.accessToken ~/.claude/.credentials.json)" \
  https://api.anthropic.com/api/oauth/usage | jq
```

If the manual `curl` returns 200 and the pill still shows "auth", check the Quickshell foreground log. The service prints to stderr on parse failures and on non-200 responses.

## The endpoint

`/api/oauth/usage` is not in any public Anthropic documentation. It was found by running `strings` on the `claude` binary and grepping for `oauth`, then hitting it once with a live token to confirm the response shape:

```json
{
  "five_hour":        { "utilization": 5,  "resets_at": "2026-05-12T04:00:00Z" },
  "seven_day":        { "utilization": 47, "resets_at": "2026-05-15T12:00:00Z" },
  "seven_day_opus":   { "utilization": 30, "resets_at": "2026-05-15T12:00:00Z" },
  "seven_day_sonnet": { "utilization": 17, "resets_at": "2026-05-15T12:00:00Z" }
}
```

`utilization` is 0 to 100. `seven_day_opus` and `seven_day_sonnet` can come back as `null` if you do not have a separate bucket for that model. If Anthropic ever ships a breaking change set `endpointOverride` and adjust `_ingestUsage` in `ClaudeStatus.qml`.

## License

MIT.
