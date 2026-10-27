# QuestPact

Quest together, even when you can't play together. Built for **WoW: Forever** (interface 16001).

- **Party window** (`/qp`, left-click the minimap button): shows the quests everyone in the group shares, the quests only you have, and the quests each QuestPact partner has that you don't, with objective progress. Shared quests are tracked automatically. The leader can tick quests to skip them for the whole group, and you're told when a partner turns in a quest you still have.
- **Catch-up window** (`/qp catchup`, right-click the minimap button): pick a partner's character and see:
  - the quests they turned in that you haven't, in the order and zone they did them, so you can follow their route
  - what's in their quest log right now, with their progress next to yours
  - every other quest they've completed that you haven't (names and zones come from Questie, if installed)

Partner data comes from three places, merged automatically:

1. **The sync app**, for playing at different times (e.g. weekday questing, weekend catch-up).
2. **Playing in a group together**: progress you hear over party comms is saved, no app needed.
3. **Other characters on your own account**.

## How the offline sync works

```
 Her PC                                   Your PC
 WoW logout -> SavedVariables\QuestPact.lua
           sync app -> shared folder/WIFE#1234@her-pc.json  (Google Drive / OneDrive / SMB)
                                          sync app -> AddOns\QuestPact\PartnerData.lua
                                          /reload or log in -> Catch-up window
```

WoW only writes SavedVariables on logout, `/reload` or a clean exit (never on a crash). The app watches for that file to change instead of watching `Wow.exe`. It never edits SavedVariables, because the game would overwrite them. Instead it writes your partner's data into `PartnerData.lua` inside the addon folder (the same approach the TSM desktop app uses with `AppData.lua`). This is safe while the game is running; `/reload` picks it up.

## Install

### Addon (both PCs)

Copy `addon\QuestPact` to `World of Warcraft\_forever_\Interface\AddOns\QuestPact`. Questie is optional but recommended (it supplies quest names and hides class/race quests you can't take).

### Sync app (both PCs): QuestPact Sync

A small desktop app (Python + tkinter) for Windows, macOS and Linux. In its window you can:

- choose your **WoW Forever folder** and the **shared quest folder** (Browse buttons, with live checks)
- name the PC
- tick **Start QuestPact Sync when I log in** (login launches always start minimized)
- tick **Start minimized** so every launch goes straight to the tray (it still opens the window if setup is incomplete)
- see which characters are in the shared folder, and an activity log

Minimizing or closing the window sends it to the system tray (Windows/Linux), where it keeps syncing; click the tray icon to bring it back. macOS has no tray here, so it minimizes to the Dock. Use **Quit** (in the window or the tray menu) to stop it. Launching it again just brings the running window back.

**Option A: installer (recommended, no Python needed).** Give the other PC the file for its OS:

| OS | File (in `sync/dist`) | What it does |
|---|---|---|
| Windows | `QuestPact-Sync-Setup-<ver>.exe` | Wizard, no admin needed. Installs the app; installs or updates the addon in your WoW Forever folder (never touching `PartnerData.lua`); asks for the shared folder and pre-fills the app's settings. Optional: start at login, desktop shortcut. Upgrades in place; uninstall removes the app and its startup entry but leaves the addon and your settings. |
| macOS | `QuestPact-Sync-<ver>.dmg` | Drag the app to Applications; the addon folder is included in the disk image. |
| Linux | `questpact-sync-<ver>-linux.tar.gz` | Unpack and run `./install.sh` (per user, adds an app-menu entry); `uninstall.sh` removes it. |

Unattended Windows install: `QuestPact-Sync-Setup-<ver>.exe /SILENT /WOWDIR="D:\WoW\_forever_" /SHAREDDIR="G:\My Drive\QuestPact"`

Windows SmartScreen will warn about the unsigned installer the first time ("More info" -> "Run anyway"); macOS Gatekeeper likewise (right-click the app -> Open).

To build them, run this on each OS (PyInstaller can't cross-compile). On Windows it also needs Inno Setup 6 (`winget install JRSoftware.InnoSetup --scope user`):

```
cd sync
python -m pip install -r requirements-build.txt
python build.py
```

**Option B: run from source** (Python 3.9+ with tkinter, which the python.org installers include):

```
cd sync
python -m pip install -r requirements-tray.txt   # optional tray icon
python run.pyw                                   # or double-click run.pyw on Windows
python run.pyw --once                            # one sync, no window
python run.pyw --headless                        # no window at all (e.g. a NAS)
```

Point both PCs at the same shared folder. With Google Drive for desktop that's something like `G:\My Drive\QuestPact` (share that folder with each other). An SMB share such as `\\NAS\games\QuestPact`, or Dropbox/OneDrive, works too. You don't need symlinks.

"Start when I log in" uses the normal per-user mechanism on each OS (no admin needed): the `HKCU\...\Run` registry key on Windows, `~/Library/LaunchAgents` on macOS, and `~/.config/autostart` on Linux.

Settings, state and log live in `%APPDATA%\QuestPact` (Windows), `~/Library/Application Support/QuestPact` (macOS) or `~/.config/questpact` (Linux).

Tests: `cd sync && python -m unittest discover -s tests`

## Typical week

1. Each of you logs in once with QuestPact installed, so every character gets a snapshot.
2. She quests during the week. Each logout exports her progress.
3. On the weekend, log in to your alt (or `/reload` if you're already in), open **Catch up**, pick her character, and work down "Turned in, in order".

## Commands

| | |
|---|---|
| `/qp` | Party window |
| `/qp catchup` | Catch-up window |
| `/qp config` | Settings |
| `/qp snapshot` | Save a snapshot now (written to disk on next `/reload` or logout) |
| `/qp status` | What partner data is loaded |

## Notes

- Quest history (turn-in order, zones, levels) is recorded from the moment QuestPact is installed. Anything finished earlier still shows up from the server's completed-quest list, just without order or dates.
- Snapshots are taken out of combat only, and party messages are held while you're in combat or under chat lockdown, per Forever's addon restrictions.
- `PartnerData.lua` contains only data. The sync app escapes everything it writes, so a shared JSON file can't inject code.
- Inspired by [QuestCoop](https://github.com/ttusing/QuestCoop) (MIT).
