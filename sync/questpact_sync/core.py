"""Sync engine: exports this PC's QuestPact characters to a shared folder and
writes everyone's into Interface/AddOns/QuestPact/PartnerData.lua.

WoW writes SavedVariables on logout, /reload or a clean exit, so we watch that
file's modified time. We never edit SavedVariables (the game would overwrite
them); partner data goes into an addon file instead, like TSM's AppData.lua.
"""

import hashlib
import json
import os
import platform
import re
import socket
import subprocess
import sys
import threading
import time
from dataclasses import asdict, dataclass, field
from datetime import datetime
from pathlib import Path

from .luadata import parse_saved_variables, to_lua

ADDON = "QuestPact"
SV_VAR = "QuestPactDB"
FORMAT = 1
SYSTEM = platform.system()  # Windows, Darwin, Linux


def app_dir():
    override = os.environ.get("QUESTPACT_HOME")
    if override:
        return Path(override)
    if SYSTEM == "Windows":
        return Path(os.environ.get("APPDATA", Path.home())) / "QuestPact"
    if SYSTEM == "Darwin":
        return Path.home() / "Library" / "Application Support" / "QuestPact"
    return Path(os.environ.get("XDG_CONFIG_HOME", Path.home() / ".config")) / "questpact"


def config_path():
    return app_dir() / "config.json"


def state_path():
    return app_dir() / "state.json"


def log_path():
    return app_dir() / "sync.log"


def wow_candidates():
    home = Path.home()
    if SYSTEM == "Windows":
        roots = [Path(r"C:\Program Files (x86)\World of Warcraft"), Path(r"C:\Program Files\World of Warcraft"),
                 Path(r"D:\World of Warcraft"), Path(r"D:\Games\World of Warcraft")]
    elif SYSTEM == "Darwin":
        roots = [Path("/Applications/World of Warcraft"), home / "Applications" / "World of Warcraft"]
    else:  # Lutris / Wine / Bottles prefixes
        roots = [home / "Games" / "world-of-warcraft" / "drive_c" / "Program Files (x86)" / "World of Warcraft",
                 home / "Games" / "battlenet" / "drive_c" / "Program Files (x86)" / "World of Warcraft",
                 home / ".wine" / "drive_c" / "Program Files (x86)" / "World of Warcraft"]
    return [r / flavor for r in roots for flavor in ("_forever_", "_classic_beta_")]


def detect_wow_dir():
    for c in wow_candidates():
        if (c / "WTF").is_dir():
            return str(c)
    return ""


@dataclass
class Config:
    wow_dir: str = ""
    shared_dir: str = ""
    machine_name: str = field(default_factory=lambda: socket.gethostname())
    poll_seconds: int = 10
    start_minimized: bool = False

    @classmethod
    def load(cls):
        try:
            data = json.loads(config_path().read_text(encoding="utf-8"))
        except (OSError, ValueError):
            return cls(wow_dir=detect_wow_dir())
        # Also accept the camelCase keys the earlier Node version wrote
        aliases = {"wowDir": "wow_dir", "sharedDir": "shared_dir", "machineName": "machine_name", "pollSeconds": "poll_seconds"}
        data = {aliases.get(k, k): v for k, v in data.items()}
        known = {k: v for k, v in data.items() if k in cls.__dataclass_fields__}
        cfg = cls(**known)
        if not cfg.wow_dir:
            cfg.wow_dir = detect_wow_dir()
        cfg.poll_seconds = max(3, int(cfg.poll_seconds or 10))
        return cfg

    def save(self):
        write_atomic(config_path(), json.dumps(asdict(self), indent=2))

    def problems(self):
        """Human-readable reasons this config can't sync yet (empty list = OK)."""
        out = []
        if not self.wow_dir or not (Path(self.wow_dir) / "WTF").is_dir():
            out.append("Choose your WoW Forever folder (the one containing WTF and Interface).")
        elif not addon_dir(self).is_dir():
            out.append(f"The {ADDON} addon isn't installed in {addon_dir(self).parent}.")
        if not self.shared_dir:
            out.append("Choose a shared folder for quest data.")
        elif not Path(self.shared_dir).is_dir():
            out.append(f"Shared folder not found: {self.shared_dir}")
        return out


def addon_dir(cfg):
    return Path(cfg.wow_dir) / "Interface" / "AddOns" / ADDON


def write_atomic(path, text):
    path = Path(path)
    path.parent.mkdir(parents=True, exist_ok=True)
    tmp = path.with_name(f"{path.name}.{os.getpid()}.tmp")
    tmp.write_text(text, encoding="utf-8", newline="\n")
    os.replace(tmp, path)


def read_json(path, default):
    try:
        return json.loads(Path(path).read_text(encoding="utf-8"))
    except (OSError, ValueError):
        return default


class Log:
    """Appends to sync.log and fans out to listeners (the GUI)."""

    def __init__(self):
        self.listeners = []
        self.lock = threading.Lock()

    def __call__(self, msg):
        line = f"{datetime.now():%Y-%m-%d %H:%M:%S}  {msg}"
        with self.lock:
            try:
                log_path().parent.mkdir(parents=True, exist_ok=True)
                with open(log_path(), "a", encoding="utf-8") as f:
                    f.write(line + "\n")
            except OSError:
                pass  # logging must never stop a sync
        if not self.listeners:
            print(line, flush=True)
        for fn in list(self.listeners):
            fn(line)


log = Log()


# ---------------------------------------------------------------------------
# Export: SavedVariables -> <shared>/<ACCOUNT>@<machine>.json
# ---------------------------------------------------------------------------

def local_accounts(cfg):
    root = Path(cfg.wow_dir) / "WTF" / "Account"
    if not root.is_dir():
        return []
    out = []
    for acct in sorted(root.iterdir()):
        sv = acct / "SavedVariables" / f"{ADDON}.lua"
        if sv.is_file():
            out.append((acct.name, sv))
    return out


def export_name(account, machine):
    return re.sub(r"[^A-Za-z0-9#@._-]", "_", f"{account}@{machine}") + ".json"


def export_account(cfg, state, account, sv_file):
    mtime = sv_file.stat().st_mtime
    seen = state["exported"].get(account)
    if seen and seen.get("mtime") == mtime:
        return False
    # Wait until the client has finished writing
    if time.time() - mtime < 2:
        return False
    data = parse_saved_variables(sv_file.read_text(encoding="utf-8", errors="replace"))
    db = data.get(SV_VAR) or {}
    chars = db.get("chars") if isinstance(db, dict) else None
    if not isinstance(chars, dict):
        chars = {}
    payload = {"format": FORMAT, "account": account, "machine": cfg.machine_name,
               "exported": int(time.time()), "chars": chars}
    write_atomic(Path(cfg.shared_dir) / export_name(account, cfg.machine_name), json.dumps(payload))
    state["exported"][account] = {"mtime": mtime, "chars": sorted(chars)}
    log(f"Exported {account}: {', '.join(sorted(chars)) or 'no characters yet'}")
    return True


# ---------------------------------------------------------------------------
# Import: every exported account -> AddOns/QuestPact/PartnerData.lua
# Local accounts are included too, so two accounts on one PC see each other;
# the addon hides the character you're logged in on.
# ---------------------------------------------------------------------------

def collect_partners(shared_dir):
    chars, sources = {}, {}
    try:
        files = sorted(p for p in Path(shared_dir).iterdir() if p.suffix.lower() == ".json")
    except OSError:
        return None
    for f in files:
        data = read_json(f, None)
        if not isinstance(data, dict) or data.get("format") != FORMAT or not isinstance(data.get("chars"), dict):
            continue
        origin = f"{data.get('account')}@{data.get('machine')}"
        for key, c in data["chars"].items():
            if not isinstance(c, dict):
                continue
            if key not in chars or (c.get("updated") or 0) > (chars[key].get("updated") or 0):
                chars[key] = c
                sources[key] = origin
    return chars, sources


def import_partners(cfg, state):
    target_dir = addon_dir(cfg)
    if not target_dir.is_dir():
        return False
    found = collect_partners(cfg.shared_dir)
    if found is None:
        return False
    chars, sources = found
    state["partners"] = [
        {"key": k, "class": c.get("class"), "level": c.get("level"), "zone": c.get("zone"),
         "updated": c.get("updated"), "from": sources[k]}
        for k, c in sorted(chars.items())
    ]
    digest = hashlib.sha1(json.dumps(chars, sort_keys=True).encode()).hexdigest()
    target = target_dir / "PartnerData.lua"
    if state.get("imported_hash") == digest and target.exists():
        return False
    data = {"generated": int(time.time()), "from": sorted(set(sources.values())), "chars": chars}
    write_atomic(target, "-- Written by QuestPact sync. Do not edit; it is replaced on every sync.\n"
                         "-- /reload in game to load changes.\n"
                         f"QuestPact_PartnerData = {to_lua(data)}\n")
    state["imported_hash"] = digest
    log(f"Updated PartnerData.lua: {', '.join(sorted(chars)) or 'no characters'}")
    return True


def wow_running():
    try:
        if SYSTEM == "Windows":
            out = subprocess.run(["tasklist", "/FI", "IMAGENAME eq Wow.exe", "/NH"], capture_output=True, text=True,
                                 creationflags=getattr(subprocess, "CREATE_NO_WINDOW", 0), timeout=5).stdout
            return "wow.exe" in out.lower()
        out = subprocess.run(["ps", "-A", "-o", "comm="], capture_output=True, text=True, timeout=5).stdout
        return any(re.search(r"(^|/)(wow(\.exe)?|world of warcraft)$", line.strip(), re.I) for line in out.splitlines())
    except (OSError, subprocess.SubprocessError):
        return False


def load_state():
    state = read_json(state_path(), {})
    state.setdefault("exported", {})
    return state


def sync_once(cfg):
    """Runs one export+import pass. Returns a dict the UI can show."""
    state = load_state()
    problems = cfg.problems()
    # Exports only need WTF + shared folder; a missing addon only blocks the import
    blocking = [p for p in problems if "addon isn't installed" not in p]
    result = {"ok": not blocking, "problems": problems, "exported": False, "imported": False}
    if blocking:
        state["last_error"] = blocking[0]
        write_atomic(state_path(), json.dumps(state, indent=2))
        return result
    for account, sv in local_accounts(cfg):
        try:
            result["exported"] |= export_account(cfg, state, account, sv)
        except Exception as e:  # one bad file must not stop the rest
            log(f"Export of {account} failed: {e}")
    try:
        result["imported"] = import_partners(cfg, state)
    except Exception as e:
        log(f"Import failed: {e}")
    if result["imported"] and wow_running():
        log("WoW is running: type /reload in game to load the new partner data.")
    state["last_sync"] = time.time()
    state.pop("last_error", None)
    write_atomic(state_path(), json.dumps(state, indent=2))
    return result


class SyncWorker(threading.Thread):
    """Background loop. Call trigger() to sync immediately, update_config() after edits."""

    def __init__(self, cfg, on_result=None):
        super().__init__(daemon=True, name="QuestPactSync")
        self.cfg = cfg
        self.on_result = on_result
        self.wake = threading.Event()
        self.stopped = threading.Event()

    def trigger(self):
        self.wake.set()

    def update_config(self, cfg):
        self.cfg = cfg
        self.wake.set()

    def stop(self):
        self.stopped.set()
        self.wake.set()

    def run(self):
        while not self.stopped.is_set():
            try:
                r = sync_once(self.cfg)
            except Exception as e:
                log(f"Sync error: {e}")
                r = {"ok": False, "problems": [str(e)]}
            if self.on_result:
                self.on_result(r)
            self.wake.wait(self.cfg.poll_seconds)
            self.wake.clear()


def frozen():
    return getattr(sys, "frozen", False)
