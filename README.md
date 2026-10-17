# VALORANT ACE Exit Guard

[简体中文](README.zh-CN.md)

A Windows PowerShell tray guard that disables recognized Anti-Cheat Expert (ACE)
service/driver startup entries after VALORANT exits, then reports the actual result
in the Windows notification area.

It watches `VALORANT.exe` and `VALORANT-Win64-Shipping.exe`. Once all matching
processes have exited and remained absent for 30 seconds, the guard backs up
first-seen startup settings, disables recognized ACE entries, and checks the result.
A game restart cancels pending cleanup. The guard does not stop game processes,
unload kernel drivers, reboot the computer, or change service permissions.

This is an isolation utility. It does not establish that ACE caused a particular
crash or resolve other hardware or operating-system stability issues.

## Requirements

- 64-bit Windows with Windows PowerShell 5.1 and .NET Framework 4.8.
- An administrator account for installation and management.
- A stable local NTFS directory; keep the repository there after installation.
- An interactive user session for tray notifications. The guard starts at logon,
  not before the user logs in.

## Install

Download or clone this repository, open **64-bit Windows PowerShell as
administrator**, and change into the repository directory. Then run:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\Manage-Guard.ps1 -Action Install
```

Installation runs the tests, including a harmless real process start/exit probe,
creates the `Valorant.AceExitGuard` logon task, starts it, and verifies a fresh
startup receipt and running process. If VALORANT is already absent, it also runs
an initial cleanup. Later game exits need no additional UAC prompts.
If the watcher starts successfully but initial cleanup fails, management records
both outcomes and returns exit code 2; the watcher remains installed.

The guard disables ACE startup; a launcher may recreate or re-enable those entries
on a later game launch. The guard does not enable ACE for you or guarantee that an
ACE-dependent game will launch while its entries are disabled.

## Notifications and records

Notifications distinguish:

- Verified startup disablement with all identified components stopped.
- Verified startup disablement with components still running or runtime state unknown.
- Partial failure, access denied, or a game restarting during cleanup.

**Disabled startup does not mean an already loaded driver has been unloaded.**
Windows notification preferences may suppress banners. `NotificationRequested`
only records the API request; `NotificationShown` records the shell display event.
The tray menu opens the latest receipt. Its Exit item stops the current watcher;
the task starts again at the next logon.

Installed runtime records live in `.runtime\data`:

| File | Purpose |
| --- | --- |
| `watcher_ready.json`, `watcher_state.json` | Startup and game-session state |
| `last_isolation.json`, `isolation_*.json` | Actual before/after cleanup results |
| `original_start_values.json` | First-seen settings for each service/image pair |
| `events.jsonl` | Lifecycle, errors, and notification events; rotates at 5 MiB |
| `management_*.json` | Installation/update results and initial-cleanup outcome |
| `installed_task.xml`, `task_security_descriptor.txt` | Installed task audit |

These files contain machine-specific information and are excluded from Git.
An existing backup is preserved when a later cleanup sees the same service/image
pair. Service restoration is not automatic; retain the backup if you need to
restore individual original startup settings later.

## Status, update, and removal

Run from the repository directory:

```powershell
.\Manage-Guard.ps1 -Action Status
# Administrator Windows PowerShell:
.\Manage-Guard.ps1 -Action Update
.\Manage-Guard.ps1 -Action Uninstall
```

Update deploys reviewed source changes to the protected runtime and rechecks
startup. It stops only this guard and preserves its backups. Do not move the
directory after installation or run multiple copies of the guard.

Uninstall stops/removes the scheduled task and preserves runtime records. It
leaves current ACE startup settings unchanged. Install refuses an existing task
or runtime directory instead of overwriting it silently.

## Tests and verification

```powershell
# No service changes or game launch:
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\Test-Guard.ps1
# Administrator; adds a harmless cmd.exe WMI event probe:
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\Test-Guard.ps1 -RunEventProbe
# Administrator, after the first completed cleanup:
.\Verify-Guard.ps1
```

Tests cover exit grace, restarts, remaining game processes, short sessions,
recovery, target-path restrictions, and truthful success/failure notifications.
Verification does not launch VALORANT to force an end-to-end test. It can fail if
ACE has since been re-enabled or Windows suppressed the notification evidence;
inspect the recorded reason. If installed while VALORANT is running, wait for its
first exit and completed cleanup before verification. Verification inspects the
current watcher session, including after a later logon or task restart.

## Implementation and protection

WMI process tracing provides the main trigger. While a session is armed, a
15-second reconciliation covers a missed exit event. The UI timer drains events
without repeatedly scanning processes while idle. A small race remains between
checking game absence and configuring services; active drivers are never unloaded.

Targets require both an ACE service-name pattern and a recognized image path:
`Program Files\AntiCheatExpert`, or an ACE-named `.sys` directly under
`Windows\System32\drivers`. Unexpected paths and changed service identities are
reported instead of silently counted as success. Other anti-cheat products are
outside scope.

The task loads administrator-owned runtime copies rather than editable source.
Its transparent inline bootstrap pins directory components from the drive root
to runtime data, rejects reparse points, and checks owner/permissions before
loading scripts. Handles stay open while the watcher runs, preventing those
ancestor directories from being renamed; normal file work continues. Task and
runtime modifications are restricted to Administrators and SYSTEM. No antivirus
exclusions or system security settings are changed.

Source files:

- `Guard.Core.ps1`: target discovery, backups, isolation, state transitions, notices.
- `Watch-Ace.ps1`: process lifecycle watcher and tray UI.
- `Manage-Guard.ps1`: installation, update, status, removal.
- `Runtime.Security.ps1`: runtime path and ACL checks.
- `Test-Guard.ps1`, `Verify-Guard.ps1`: tests and installed-state verification.
