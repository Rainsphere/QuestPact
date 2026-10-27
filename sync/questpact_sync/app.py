"""Entry point.

  questpact-sync               open the window (keeps syncing when closed)
  questpact-sync --minimized   start hidden in the tray/taskbar (used at login)
  questpact-sync --once        sync once, print what happened, exit (no window)
  questpact-sync --headless    sync forever without a window (servers, NAS, ssh)
"""

import argparse
import os
import socket
import sys
import threading
import time
import zlib

from . import core
from .core import Config, log

# One running copy per settings folder: a second launch just asks the first to show itself
def instance_port():
    home = os.environ.get("QUESTPACT_HOME")
    if not home:
        return 47811
    return 48000 + zlib.crc32(os.path.abspath(home).lower().encode()) % 1000


class InstanceServer(threading.Thread):
    def __init__(self, sock):
        super().__init__(daemon=True)
        self.sock = sock
        self.on_show = None

    def run(self):
        while True:
            try:
                conn, _ = self.sock.accept()
            except OSError:
                return
            with conn:
                if conn.recv(16) == b"show" and self.on_show:
                    self.on_show()


def claim_instance():
    """Returns an InstanceServer if we're the first copy, None if another copy is running."""
    # No SO_REUSEADDR: a plain bind fails while another copy holds the port, on every OS
    sock = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    try:
        sock.bind(("127.0.0.1", instance_port()))
        sock.listen(2)
    except OSError:
        sock.close()
        try:
            with socket.create_connection(("127.0.0.1", instance_port()), timeout=2) as c:
                c.sendall(b"show")
        except OSError:
            pass
        return None
    server = InstanceServer(sock)
    server.start()
    return server


def run_once():
    cfg = Config.load()
    r = core.sync_once(cfg)
    for p in r["problems"]:
        log(f"Problem: {p}")
    return 0 if r["ok"] else 1


def run_headless():
    cfg = Config.load()
    for p in cfg.problems():
        log(f"Problem: {p}")
    log(f"Watching {cfg.wow_dir} <-> {cfg.shared_dir} every {cfg.poll_seconds}s")
    worker = core.SyncWorker(cfg)
    worker.start()
    try:
        while worker.is_alive():
            time.sleep(1)
    except KeyboardInterrupt:
        worker.stop()
    return 0


def main(argv=None):
    ap = argparse.ArgumentParser(prog="questpact-sync", description="Sync QuestPact quest progress through a shared folder.")
    ap.add_argument("--minimized", action="store_true", help="start hidden (used when launched at login)")
    ap.add_argument("--once", action="store_true", help="sync once without a window and exit")
    ap.add_argument("--headless", action="store_true", help="sync continuously without a window")
    args = ap.parse_args(argv)

    if args.once:
        return run_once()
    if args.headless:
        return run_headless()

    server = claim_instance()
    if server is None:
        return 0  # the running copy has been asked to show its window
    from .gui import App
    App(start_minimized=args.minimized, instance_server=server).run()
    return 0


if __name__ == "__main__":
    sys.exit(main())
