"""Start-at-login for each OS, per user, no admin rights needed.

Windows: HKCU\\Software\\Microsoft\\Windows\\CurrentVersion\\Run
macOS:   ~/Library/LaunchAgents/com.questpact.sync.plist
Linux:   ~/.config/autostart/questpact-sync.desktop  (XDG, works in GNOME/KDE/XFCE/...)
"""

import os
import plistlib
import shlex
import sys
from pathlib import Path

from .core import SYSTEM, frozen

NAME = "QuestPact Sync"
MAC_LABEL = "com.questpact.sync"


def launch_command():
    """argv that starts the app minimized, from either a packaged build or source."""
    if frozen():
        return [sys.executable, "--minimized"]
    run_script = str(Path(__file__).resolve().parent.parent / "run.pyw")
    python = Path(sys.executable)
    if SYSTEM == "Windows":
        # pythonw has no console window
        pythonw = python.with_name("pythonw.exe")
        if pythonw.exists():
            python = pythonw
    return [str(python), run_script, "--minimized"]


def _windows_cmdline(argv):
    return " ".join(f'"{a}"' if " " in a or not a else a for a in argv)


def _mac_plist():
    return Path.home() / "Library" / "LaunchAgents" / f"{MAC_LABEL}.plist"


def _linux_desktop():
    base = Path(os.environ.get("XDG_CONFIG_HOME", Path.home() / ".config"))
    return base / "autostart" / "questpact-sync.desktop"


def is_enabled():
    if SYSTEM == "Windows":
        import winreg
        try:
            with winreg.OpenKey(winreg.HKEY_CURRENT_USER, r"Software\Microsoft\Windows\CurrentVersion\Run") as k:
                winreg.QueryValueEx(k, NAME)
                return True
        except OSError:
            return False
    if SYSTEM == "Darwin":
        return _mac_plist().exists()
    return _linux_desktop().exists()


def enable():
    argv = launch_command()
    if SYSTEM == "Windows":
        import winreg
        with winreg.CreateKey(winreg.HKEY_CURRENT_USER, r"Software\Microsoft\Windows\CurrentVersion\Run") as k:
            winreg.SetValueEx(k, NAME, 0, winreg.REG_SZ, _windows_cmdline(argv))
    elif SYSTEM == "Darwin":
        p = _mac_plist()
        p.parent.mkdir(parents=True, exist_ok=True)
        with open(p, "wb") as f:
            plistlib.dump({"Label": MAC_LABEL, "ProgramArguments": argv, "RunAtLoad": True, "ProcessType": "Interactive"}, f)
    else:
        p = _linux_desktop()
        p.parent.mkdir(parents=True, exist_ok=True)
        p.write_text("[Desktop Entry]\nType=Application\nName=QuestPact Sync\n"
                     "Comment=Sync WoW quest progress with your partner\n"
                     f"Exec={' '.join(shlex.quote(a) for a in argv)}\n"
                     "X-GNOME-Autostart-enabled=true\nTerminal=false\n", encoding="utf-8")


def disable():
    if SYSTEM == "Windows":
        import winreg
        try:
            with winreg.OpenKey(winreg.HKEY_CURRENT_USER, r"Software\Microsoft\Windows\CurrentVersion\Run", 0,
                                winreg.KEY_SET_VALUE) as k:
                winreg.DeleteValue(k, NAME)
        except OSError:
            pass
    elif SYSTEM == "Darwin":
        _mac_plist().unlink(missing_ok=True)
    else:
        _linux_desktop().unlink(missing_ok=True)


def set_enabled(on):
    if on:
        enable()
    else:
        disable()
