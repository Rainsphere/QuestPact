"""Builds QuestPact Sync for the OS you run it on. Nobody needs Python to run the result.

    python -m pip install -r requirements-build.txt
    python build.py

Output in dist/:
  Windows  QuestPact Sync.exe + QuestPact-Sync-Setup-<ver>.exe (installer, needs Inno Setup 6)
  macOS    QuestPact Sync.app + QuestPact-Sync-<ver>.dmg
  Linux    questpact-sync + questpact-sync-<ver>-linux.tar.gz (with install.sh)

PyInstaller can't cross-compile, so build on each OS you want to ship to.
"""

import os
import platform
import shutil
import subprocess
import sys
import tarfile
from pathlib import Path

HERE = Path(__file__).resolve().parent
DIST = HERE / "dist"
BUILD = HERE / "build"
SYSTEM = platform.system()

sys.path.insert(0, str(HERE))
from questpact_sync import __version__ as VERSION  # noqa: E402
from questpact_sync.tray import make_image  # noqa: E402


def tcl_env():
    """Inside a Windows venv, Tcl looks for init.tcl next to the venv's python.exe and fails,
    so PyInstaller decides tkinter is broken and leaves it out. Point it at the base install."""
    env = dict(os.environ)
    base_tcl = Path(sys.base_prefix) / "tcl"
    if SYSTEM == "Windows" and sys.prefix != sys.base_prefix and base_tcl.is_dir():
        env.setdefault("TCL_LIBRARY", str(base_tcl / "tcl8.6"))
        env.setdefault("TK_LIBRARY", str(base_tcl / "tk8.6"))
    return env


def make_icons():
    BUILD.mkdir(exist_ok=True)
    big = make_image(256)
    ico = BUILD / "questpact.ico"
    big.save(ico, sizes=[(16, 16), (24, 24), (32, 32), (48, 48), (64, 64), (128, 128), (256, 256)])
    png = BUILD / "questpact.png"
    big.save(png)
    return ico, png


def pyinstaller(icon):
    name = "questpact-sync" if SYSTEM == "Linux" else "QuestPact Sync"
    args = [
        sys.executable, "-m", "PyInstaller",
        "--noconfirm", "--clean", "--windowed",
        "--onedir" if SYSTEM == "Darwin" else "--onefile",  # .app bundles are directories
        "--name", name,
        "--icon", str(icon),
        "--distpath", str(DIST),
        "--workpath", str(BUILD),
        "--specpath", str(BUILD),
        # pystray picks its backend at runtime, so PyInstaller can't see it
        "--hidden-import", {"Windows": "pystray._win32", "Darwin": "pystray._darwin"}.get(SYSTEM, "pystray._xorg"),
        str(HERE / "run.pyw"),
    ]
    if SYSTEM == "Darwin":
        args += ["--osx-bundle-identifier", "com.questpact.sync"]
    run(args, env=tcl_env())
    return name


def find_iscc():
    found = shutil.which("ISCC") or shutil.which("iscc")
    if found:
        return found
    for base in (os.environ.get("LOCALAPPDATA", ""), os.environ.get("ProgramFiles(x86)", ""), os.environ.get("ProgramFiles", "")):
        for sub in ("Programs/Inno Setup 6/ISCC.exe", "Inno Setup 6/ISCC.exe"):
            p = Path(base) / sub
            if base and p.exists():
                return str(p)
    return None


def windows_installer(icon):
    iscc = find_iscc()
    if not iscc:
        print("\nInno Setup 6 not found, so no installer was built. Install it with:\n"
              "  winget install JRSoftware.InnoSetup --scope user\nthen run build.py again.")
        return
    run([iscc, f"/DAppVersion={VERSION}", f"/DAppIcon={icon}", str(HERE / "installer" / "QuestPactSync.iss")])


def mac_dmg():
    stage = BUILD / "dmg"
    shutil.rmtree(stage, ignore_errors=True)
    stage.mkdir(parents=True)
    shutil.copytree(DIST / "QuestPact Sync.app", stage / "QuestPact Sync.app", symlinks=True)
    os.symlink("/Applications", stage / "Applications")  # drag-to-install
    addon = HERE.parent / "addon" / "QuestPact"
    if addon.is_dir():
        shutil.copytree(addon, stage / "WoW Addon - QuestPact")
    out = DIST / f"QuestPact-Sync-{VERSION}.dmg"
    out.unlink(missing_ok=True)
    run(["hdiutil", "create", "-volname", "QuestPact Sync", "-srcfolder", str(stage), "-ov", "-format", "UDZO", str(out)])


LINUX_INSTALL = """#!/bin/sh
# Installs QuestPact Sync for the current user (no root needed).
set -e
here="$(cd "$(dirname "$0")" && pwd)"
mkdir -p "$HOME/.local/bin" "$HOME/.local/share/applications" "$HOME/.local/share/icons/hicolor/256x256/apps"
install -m 755 "$here/questpact-sync" "$HOME/.local/bin/questpact-sync"
install -m 644 "$here/questpact.png" "$HOME/.local/share/icons/hicolor/256x256/apps/questpact-sync.png"
cat > "$HOME/.local/share/applications/questpact-sync.desktop" <<EOF
[Desktop Entry]
Type=Application
Name=QuestPact Sync
Comment=Sync WoW quest progress with your partner
Exec=$HOME/.local/bin/questpact-sync
Icon=questpact-sync
Categories=Game;Utility;
Terminal=false
EOF
echo "Installed. Start \\"QuestPact Sync\\" from your app menu, or run ~/.local/bin/questpact-sync"
echo "The WoW addon is in $here/addon/QuestPact - copy it to <WoW>/_forever_/Interface/AddOns/"
"""

LINUX_UNINSTALL = """#!/bin/sh
rm -f "$HOME/.local/bin/questpact-sync" "$HOME/.local/share/applications/questpact-sync.desktop" \\
      "$HOME/.local/share/icons/hicolor/256x256/apps/questpact-sync.png" \\
      "${XDG_CONFIG_HOME:-$HOME/.config}/autostart/questpact-sync.desktop"
echo "QuestPact Sync removed. Settings are kept in ${XDG_CONFIG_HOME:-$HOME/.config}/questpact"
"""


def linux_tarball(png):
    out = DIST / f"questpact-sync-{VERSION}-linux.tar.gz"
    root = f"questpact-sync-{VERSION}"

    def add_text(tar, name, text, mode):
        data = text.encode()
        info = tarfile.TarInfo(f"{root}/{name}")
        info.size, info.mode = len(data), mode
        import io
        tar.addfile(info, io.BytesIO(data))

    with tarfile.open(out, "w:gz") as tar:
        tar.add(DIST / "questpact-sync", f"{root}/questpact-sync")
        tar.add(png, f"{root}/questpact.png")
        addon = HERE.parent / "addon" / "QuestPact"
        if addon.is_dir():
            tar.add(addon, f"{root}/addon/QuestPact")
        add_text(tar, "install.sh", LINUX_INSTALL, 0o755)
        add_text(tar, "uninstall.sh", LINUX_UNINSTALL, 0o755)


def run(args, **kw):
    print("> " + " ".join(f'"{a}"' if " " in str(a) else str(a) for a in args), flush=True)
    subprocess.run([str(a) for a in args], check=True, cwd=HERE, **kw)


def main():
    ico, png = make_icons()
    pyinstaller(ico)
    if SYSTEM == "Windows":
        windows_installer(ico)
    elif SYSTEM == "Darwin":
        mac_dmg()
    else:
        linux_tarball(png)
    print(f"\nDone - see {DIST}")
    for f in sorted(DIST.iterdir()):
        print("  " + f.name)


if __name__ == "__main__":
    main()
