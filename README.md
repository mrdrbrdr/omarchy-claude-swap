# Claude Swap for Omarchy

A bar widget for [Omarchy](https://omarchy.org) that puts [claude-swap](https://github.com/realiti4/claude-swap) (multi-account switching for Claude Code) one click away. It replaces keeping the `cswap` TUI open in a terminal.

- **Bar:** the active account and how full its fullest limit is, for example `󰀙 1 72%`. It turns your theme's alert color when that limit reaches the auto-switch threshold or when something needs attention.
- **Dropdown:** every account's 5-hour, weekly and per-model meters with the time to reset. Each meter has a tick for an even pace through the window and one for the switch threshold. Hover a row for details.
- **Switch** to any account. Switches ask for a second click to confirm.
- **Auto-switch:** turn `cswap auto` on or off and set the threshold with − / +.
- **Manage accounts:** add the account Claude Code is logged in to, add a setup token or API key, hold an account out of rotation, remove one.
- **Rescue switch:** when claude-swap itself gets stuck, the widget switches for you. See below.
- **Several machines (optional):** drive your desktop and, say, a server where your agents run, as one.

Mouse only: left-click the bar icon to open the panel. It refreshes on its own.

## Requirements

- Omarchy 4 (the Quickshell-based shell)
- claude-swap 0.26 or newer: `uv tool install claude-swap`
- `jq` (ships with Omarchy)

## Install

```bash
omarchy plugin add https://github.com/mrdrbrdr/omarchy-claude-swap.git --enable
```

Update later with `omarchy plugin update mrdrbrdr.claude-swap`, then run `omarchy restart shell`. The shell keeps an already loaded widget in memory, so updated code only shows after a restart.

## Uninstall

1. If you turned on **Rotate automatically**, turn it off in the panel first. That stops and disables `claude-swap-auto.service` on every machine the widget drives.
2. Remove the widget:

   ```bash
   omarchy plugin remove mrdrbrdr.claude-swap
   ```

3. Optionally delete what the widget created on each machine:

   ```bash
   rm -f ~/.config/systemd/user/claude-swap-auto.service && systemctl --user daemon-reload
   rm -rf ~/.local/state/cswap-bar
   ```

Your accounts stay in claude-swap's own store and keep working with the `cswap` CLI. To remove claude-swap as well, run `uv tool uninstall claude-swap`.

## First run

1. Start `claude` and log in with your first account.
2. Open the widget. With no accounts yet, the **Manage accounts** section is already open. Click **Add this machine's login**.
3. For each further account, run `/login` in Claude Code, log in as that account, and click **Add this machine's login** again.
4. Turn on **Rotate automatically**. The first time, this installs `~/.config/systemd/user/claude-swap-auto.service`, which runs `cswap auto`. Set the threshold with − / +.

## The rescue switch

claude-swap can watch a per-model weekly limit as well (`cswap config set autoswitch.model Fable`), which is useful: it moves you off an account whose model quota is gone while its session window still looks fine. But when that model is spent on *every* account, its engine reports "all exhausted" and stops switching, even when the account you are on has no session quota left at all and another account has a fresh session window that every other model could use.

This widget fills that gap. Once per poll it checks whether all of this is true:

- claude-swap has no move of its own, meaning every account is past the threshold on the limits it watches
- the active account is out of session quota (its 5-hour or weekly limit is at 99% or more), so staying means not working
- another account, stored on every machine and not held out of rotation, still has session room

Then it switches there, on every machine, and posts a desktop notification. At most one such switch every 15 minutes, which holds across bar instances and shell restarts.

Turn it off with the **Switch automatically when everything is blocked** setting (`"autoFallback": false`). Note that it also applies when you switch to a spent account by hand: within a minute it moves you back off, because that account cannot serve a prompt.

## Several machines

Point the widget at more than one machine in `~/.config/omarchy/shell.json`:

```json
{ "id": "mrdrbrdr.claude-swap", "machines": "server,local", "localName": "desktop" }
```

or `omarchy bar set mrdrbrdr.claude-swap machines "server,local"`.

- `local` is this computer. Anything else is an ssh destination. The first machine is primary: its slot numbers and threshold are shown.
- Each remote machine needs key-based ssh without prompts, `bash`, `jq` and claude-swap. On a headless server, run `loginctl enable-linger` there so the auto-switch service keeps running while you are logged out.
- Switching, the threshold, auto-switch on/off, disable/enable and remove apply to every machine. If the machines end up on different accounts, the panel says so and offers to bring them back in line.
- **Accounts only travel outward from this computer.** "Add this machine's login" and "Copy to …" push this computer's stored login to the other machines. Nothing is ever imported from a remote machine, so a compromised server cannot plant an account on your desktop. Consider limiting the ssh key on the server to this computer's address, for example `from="100.x.y.z"` in its `authorized_keys`.

## How it works

`Panel.qml` is the widget. It calls `cswap-bar`, a small bash helper that runs `cswap` locally, or on another machine over ssh with its own multiplexed connection. Every command answers with one line of JSON.

- No listening ports, no root, no telemetry.
- Polling runs every 60 s, and every 15 s while the panel is open. claude-swap answers from its own usage cache, so the widget adds no calls to Anthropic's rate-limited usage endpoint.
- Setup tokens go to claude-swap on stdin, never on a command line. Account copies stream through ssh and are never written to a file outside claude-swap's own store.
- Machine names and account ids are checked against plain patterns before they reach `ssh` or `cswap`.

## Good to know

- A switch changes the login for new Claude Code sessions right away. Running sessions keep the old account until their token refreshes, which can take up to an hour. That is claude-swap behavior.
- When a running session moves to another account, its prompt cache is rebuilt under that account. That is why switches ask for a second click.
- Using several subscriptions is subject to Anthropic's terms for your plan. This widget only drives claude-swap and the official Claude Code login.

## Troubleshooting

- Updated code does not show: `omarchy restart shell`.
- QML errors: `journalctl --user | grep -i claude-swap`.
- Run the helper by hand: `~/.config/omarchy/plugins/mrdrbrdr.claude-swap/cswap-bar json | jq`.

## Credits

[claude-swap](https://github.com/realiti4/claude-swap) by realiti4 does the actual account work. The panel follows the look of Omarchy's own Agents widget.

MIT licensed.
