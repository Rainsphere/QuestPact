"""QuestPact Sync window (tkinter, ships with Python on Windows/macOS/Linux)."""

import queue
import subprocess
import time
import tkinter as tk
from pathlib import Path
from tkinter import filedialog, messagebox, ttk
from tkinter.scrolledtext import ScrolledText

from . import autostart, core
from .core import SYSTEM, Config, log
from .tray import start_tray

PAD = 8
GOOD, WARN = "#2e7d32", "#c77700"


def ago(t):
    if not t:
        return "never"
    d = time.time() - t
    if d < 90:
        return "just now"
    if d < 5400:
        return f"{int(d // 60)} min ago"
    if d < 129600:
        return f"{int(d // 3600)} hr ago"
    return f"{int(d // 86400)} days ago"


def open_path(path):
    path = str(path)
    if SYSTEM == "Windows":
        import os
        os.startfile(path)  # noqa: S606 - opening a user-chosen folder/file
    elif SYSTEM == "Darwin":
        subprocess.Popen(["open", path])
    else:
        subprocess.Popen(["xdg-open", path])


def window_icon(size=32):
    """Gold "!" on a dark disc, drawn pixel by pixel so no image files are needed."""
    img = tk.PhotoImage(width=size, height=size)
    s = size / 32
    outside = []
    rows = []
    for y in range(size):
        row = []
        for x in range(size):
            gx, gy = (x + 0.5) / s, (y + 0.5) / s
            r = ((gx - 16) ** 2 + (gy - 16) ** 2) ** 0.5
            mark = 14 <= gx < 18 and (6 <= gy < 20 or 22 <= gy < 26)
            if r > 16:
                outside.append((x, y))
                row.append("#000000")
            elif r > 14 or mark:
                row.append("#ffcd28")
            else:
                row.append("#1e2846")
        rows.append("{" + " ".join(row) + "}")
    img.put(" ".join(rows))
    for x, y in outside:
        img.transparency_set(x, y, True)
    return img


class App:
    def __init__(self, start_minimized=False, instance_server=None):
        self.cfg = Config.load()
        # Never start hidden while setup is incomplete; the user has to see what's missing
        start_minimized = (start_minimized or self.cfg.start_minimized) and not self.cfg.problems()
        self.events = queue.Queue()
        self.quitting = False

        self.root = tk.Tk()
        self.root.title("QuestPact Sync")
        self.root.minsize(560, 520)
        self.root.geometry("680x640")
        try:
            self._icon = window_icon()
            self.root.iconphoto(True, self._icon)
        except tk.TclError:
            pass
        self.root.protocol("WM_DELETE_WINDOW", self.on_close)

        self.build()
        self.load_fields()

        log.listeners.append(lambda line: self.events.put(("log", line)))
        self.worker = core.SyncWorker(self.cfg, on_result=lambda r: self.events.put(("result", r)))
        self.worker.start()

        self.tray = start_tray(
            on_show=lambda: self.events.put(("show", None)),
            on_sync=lambda: self.events.put(("sync", None)),
            on_quit=lambda: self.events.put(("quit", None)),
        )
        if instance_server:
            instance_server.on_show = lambda: self.events.put(("show", None))
        self.told_about_tray = start_minimized  # no balloon when starting hidden at login
        self.root.bind("<Unmap>", self.on_unmap)

        if start_minimized:
            if self.tray:
                self.root.withdraw()
            else:
                self.root.iconify()
        self.root.after(150, self.pump)
        if self.cfg.problems() and not start_minimized:
            self.root.after(300, self.first_run_hint)

    # ------------------------------------------------------------------ layout

    def build(self):
        root = self.root
        root.columnconfigure(0, weight=1)
        root.rowconfigure(4, weight=1)
        root.rowconfigure(5, weight=1)

        head = ttk.Frame(root, padding=(PAD * 2, PAD * 2, PAD * 2, PAD))
        head.grid(row=0, column=0, sticky="ew")
        ttk.Label(head, text="QuestPact Sync", font=("TkDefaultFont", 15, "bold")).pack(anchor="w")
        self.status = tk.Label(head, text="Starting...", anchor="w", fg=WARN)
        self.status.pack(anchor="w", fill="x")

        # Folders
        folders = ttk.LabelFrame(root, text="Folders", padding=PAD)
        folders.grid(row=1, column=0, sticky="ew", padx=PAD * 2, pady=(0, PAD))
        folders.columnconfigure(1, weight=1)

        self.wow_var = tk.StringVar()
        self.shared_var = tk.StringVar()
        self.machine_var = tk.StringVar()

        ttk.Label(folders, text="WoW Forever folder").grid(row=0, column=0, sticky="w", padx=(0, PAD))
        ttk.Entry(folders, textvariable=self.wow_var).grid(row=0, column=1, sticky="ew")
        ttk.Button(folders, text="Browse...", command=self.browse_wow).grid(row=0, column=2, padx=(PAD, 0))
        self.wow_hint = ttk.Label(folders, text="", foreground="gray")
        self.wow_hint.grid(row=1, column=1, columnspan=2, sticky="w", pady=(2, PAD))

        ttk.Label(folders, text="Shared quest folder").grid(row=2, column=0, sticky="w", padx=(0, PAD))
        ttk.Entry(folders, textvariable=self.shared_var).grid(row=2, column=1, sticky="ew")
        ttk.Button(folders, text="Browse...", command=self.browse_shared).grid(row=2, column=2, padx=(PAD, 0))
        self.shared_hint = ttk.Label(folders, foreground="gray", wraplength=440, justify="left",
                                     text="A folder both PCs can reach: Google Drive, OneDrive, Dropbox, or a network share.")
        self.shared_hint.grid(row=3, column=1, columnspan=2, sticky="w", pady=(2, PAD))

        ttk.Label(folders, text="This PC's name").grid(row=4, column=0, sticky="w", padx=(0, PAD))
        ttk.Entry(folders, textvariable=self.machine_var, width=24).grid(row=4, column=1, sticky="w")

        for var in (self.wow_var, self.shared_var):
            var.trace_add("write", lambda *_: self.validate_fields())

        # Options
        opts = ttk.LabelFrame(root, text="Options", padding=PAD)
        opts.grid(row=2, column=0, sticky="ew", padx=PAD * 2, pady=(0, PAD))
        self.autostart_var = tk.BooleanVar()
        ttk.Checkbutton(opts, text="Start QuestPact Sync when I log in to this computer",
                        variable=self.autostart_var, command=self.toggle_autostart).grid(row=0, column=0, columnspan=3, sticky="w")
        self.minimized_var = tk.BooleanVar()
        ttk.Checkbutton(opts, text="Start minimized" + ("" if SYSTEM == "Darwin" else " to the system tray"),
                        variable=self.minimized_var, command=self.toggle_minimized).grid(row=1, column=0, columnspan=3, sticky="w")
        ttk.Label(opts, text="Check for changes every").grid(row=2, column=0, sticky="w", pady=(PAD, 0))
        self.poll_var = tk.IntVar()
        ttk.Spinbox(opts, from_=3, to=300, width=5, textvariable=self.poll_var).grid(row=2, column=1, padx=4, pady=(PAD, 0))
        ttk.Label(opts, text="seconds").grid(row=2, column=2, sticky="w", pady=(PAD, 0))

        # Buttons
        bar = ttk.Frame(root, padding=(PAD * 2, 0))
        bar.grid(row=3, column=0, sticky="ew", pady=(0, PAD))
        ttk.Button(bar, text="Save settings", command=self.save).pack(side="left")
        ttk.Button(bar, text="Sync now", command=self.sync_now).pack(side="left", padx=PAD)
        ttk.Button(bar, text="Open shared folder", command=self.open_shared).pack(side="left")
        ttk.Button(bar, text="Quit", command=self.quit).pack(side="right")
        ttk.Button(bar, text="Open log", command=lambda: open_path(core.log_path())).pack(side="right", padx=PAD)

        # Partner characters
        chars = ttk.LabelFrame(root, text="Characters in the shared folder", padding=PAD)
        chars.grid(row=4, column=0, sticky="nsew", padx=PAD * 2, pady=(0, PAD))
        chars.columnconfigure(0, weight=1)
        chars.rowconfigure(0, weight=1)
        cols = ("char", "level", "zone", "updated", "from")
        self.tree = ttk.Treeview(chars, columns=cols, show="headings", height=5)
        for col, title, width in (("char", "Character", 150), ("level", "Level", 50), ("zone", "Zone", 130),
                                  ("updated", "Updated", 90), ("from", "From", 150)):
            self.tree.heading(col, text=title)
            self.tree.column(col, width=width, anchor="w", stretch=col in ("char", "zone", "from"))
        self.tree.grid(row=0, column=0, sticky="nsew")
        sb = ttk.Scrollbar(chars, orient="vertical", command=self.tree.yview)
        sb.grid(row=0, column=1, sticky="ns")
        self.tree.configure(yscrollcommand=sb.set)

        # Activity log
        act = ttk.LabelFrame(root, text="Activity", padding=PAD)
        act.grid(row=5, column=0, sticky="nsew", padx=PAD * 2, pady=(0, PAD * 2))
        act.columnconfigure(0, weight=1)
        act.rowconfigure(0, weight=1)
        self.logbox = ScrolledText(act, height=6, state="disabled", wrap="word", font=("TkFixedFont", 9))
        self.logbox.grid(row=0, column=0, sticky="nsew")
        try:
            lines = core.log_path().read_text(encoding="utf-8").splitlines()[-40:]
            self.append_log(*lines)
        except OSError:
            pass

    def load_fields(self):
        self.wow_var.set(self.cfg.wow_dir)
        self.shared_var.set(self.cfg.shared_dir)
        self.machine_var.set(self.cfg.machine_name)
        self.poll_var.set(self.cfg.poll_seconds)
        self.autostart_var.set(autostart.is_enabled())
        self.minimized_var.set(self.cfg.start_minimized)
        self.validate_fields()
        self.refresh_characters()

    # ----------------------------------------------------------------- actions

    def form_config(self):
        try:
            poll = max(3, min(300, int(self.poll_var.get())))
        except (tk.TclError, ValueError):
            poll = 10
        return Config(wow_dir=self.wow_var.get().strip(), shared_dir=self.shared_var.get().strip(),
                      machine_name=self.machine_var.get().strip() or core.socket.gethostname(), poll_seconds=poll,
                      start_minimized=self.minimized_var.get())

    def validate_fields(self):
        wow = Path(self.wow_var.get().strip()) if self.wow_var.get().strip() else None
        if not wow:
            self.wow_hint.configure(text="Pick the _forever_ folder inside your World of Warcraft install.", foreground=WARN)
        elif not (wow / "WTF").is_dir():
            self.wow_hint.configure(text="No WTF folder here - pick the _forever_ folder.", foreground=WARN)
        elif not (wow / "Interface" / "AddOns" / core.ADDON).is_dir():
            self.wow_hint.configure(text="QuestPact addon not installed here yet (copy it into Interface/AddOns).", foreground=WARN)
        else:
            accounts = [a for a, _ in core.local_accounts(self.form_config())]
            note = f"Accounts with QuestPact data: {', '.join(accounts)}" if accounts else "Addon found. Log a character in and out once to create data."
            self.wow_hint.configure(text=note, foreground=GOOD)

        shared = self.shared_var.get().strip()
        if shared and Path(shared).is_dir():
            n = len([p for p in Path(shared).glob("*.json")])
            self.shared_hint.configure(text=f"OK - {n} export file(s) here.", foreground=GOOD)
        elif shared:
            self.shared_hint.configure(text="Folder doesn't exist yet - it will be created when you save.", foreground=WARN)
        else:
            self.shared_hint.configure(text="A folder both PCs can reach: Google Drive, OneDrive, Dropbox, or a network share.",
                                       foreground="gray")

    def browse_wow(self):
        start = self.wow_var.get() or str(Path.home())
        d = filedialog.askdirectory(title="Select your WoW Forever folder (_forever_)", initialdir=start, mustexist=True)
        if d:
            p = Path(d)
            # Accept the WoW root and step into _forever_ automatically
            if not (p / "WTF").is_dir() and (p / "_forever_" / "WTF").is_dir():
                p = p / "_forever_"
            self.wow_var.set(str(p))

    def browse_shared(self):
        start = self.shared_var.get() or str(Path.home())
        d = filedialog.askdirectory(title="Select the shared quest folder", initialdir=start)
        if d:
            self.shared_var.set(str(Path(d)))

    def save(self):
        cfg = self.form_config()
        if cfg.shared_dir and not Path(cfg.shared_dir).is_dir():
            if not messagebox.askyesno("Create folder?", f"Create the shared folder?\n\n{cfg.shared_dir}", parent=self.root):
                return
            try:
                Path(cfg.shared_dir).mkdir(parents=True)
            except OSError as e:
                messagebox.showerror("QuestPact Sync", f"Couldn't create the folder:\n{e}", parent=self.root)
                return
        cfg.save()
        self.cfg = cfg
        self.worker.update_config(cfg)
        if self.autostart_var.get():
            autostart.enable()  # refresh the command in case the app moved
        log("Settings saved.")
        self.validate_fields()

    def toggle_autostart(self):
        try:
            autostart.set_enabled(self.autostart_var.get())
            log("Will start at login." if self.autostart_var.get() else "Won't start at login.")
        except OSError as e:
            self.autostart_var.set(autostart.is_enabled())
            messagebox.showerror("QuestPact Sync", f"Couldn't change the startup setting:\n{e}", parent=self.root)

    def toggle_minimized(self):
        # Applies immediately, like the login checkbox; other unsaved edits stay unsaved
        self.cfg.start_minimized = self.minimized_var.get()
        self.cfg.save()
        log("Will start minimized." if self.cfg.start_minimized else "Will start with the window open.")

    def sync_now(self):
        self.status.configure(text="Syncing...", fg=WARN)
        self.worker.trigger()

    def open_shared(self):
        d = self.shared_var.get().strip()
        if d and Path(d).is_dir():
            open_path(d)
        else:
            messagebox.showinfo("QuestPact Sync", "Choose and save a shared folder first.", parent=self.root)

    def first_run_hint(self):
        messagebox.showinfo("Welcome to QuestPact Sync",
                            "Pick your WoW Forever folder and a shared folder that your partner's PC can also reach "
                            "(for example a shared Google Drive folder), then click Save settings.\n\n"
                            "Tick \"Start when I log in\" to keep it running in the background.",
                            parent=self.root)

    # ----------------------------------------------------------- live updates

    def pump(self):
        try:
            while True:
                kind, payload = self.events.get_nowait()
                if kind == "log":
                    self.append_log(payload)
                elif kind == "result":
                    self.show_result(payload)
                elif kind == "show":
                    self.show()
                elif kind == "sync":
                    self.sync_now()
                elif kind == "quit":
                    self.quit()
                    return
        except queue.Empty:
            pass
        if not self.quitting:
            self.root.after(200, self.pump)

    def append_log(self, *lines):
        self.logbox.configure(state="normal")
        for line in lines:
            self.logbox.insert("end", line + "\n")
        # keep the box from growing forever
        extra = int(self.logbox.index("end-1c").split(".")[0]) - 300
        if extra > 0:
            self.logbox.delete("1.0", f"{extra}.0")
        self.logbox.see("end")
        self.logbox.configure(state="disabled")

    def show_result(self, r):
        if r.get("ok"):
            text = f"Watching for changes - last sync {time.strftime('%H:%M:%S')}"
            problems = r.get("problems") or []
            if problems:
                text += f"  ({problems[0]})"
            self.status.configure(text=text, fg=GOOD if not problems else WARN)
        else:
            self.status.configure(text=(r.get("problems") or ["Not syncing"])[0], fg=WARN)
        self.refresh_characters()

    def refresh_characters(self):
        state = core.load_state()
        self.tree.delete(*self.tree.get_children())
        for p in state.get("partners", []):
            name = p["key"]
            if p.get("class"):
                name += f"  ({p['class'].title()})"
            self.tree.insert("", "end", values=(name, p.get("level") or "", p.get("zone") or "",
                                                ago(p.get("updated")), p.get("from") or ""))

    # ------------------------------------------------------------- lifecycle

    def show(self):
        self.root.deiconify()
        self.root.lift()
        self.root.focus_force()

    def hide_to_tray(self):
        self.root.withdraw()
        if not self.told_about_tray:
            self.told_about_tray = True
            try:
                self.tray.notify("Still syncing in the background. Click the tray icon to reopen.", "QuestPact Sync")
            except Exception:
                pass  # notifications aren't supported by every tray backend

    def on_unmap(self, event):
        # The minimize button iconifies the window; send it to the tray instead of the taskbar
        if event.widget is self.root and self.tray and self.root.state() == "iconic":
            self.root.after(0, self.hide_to_tray)

    def on_close(self):
        # Closing the window keeps syncing in the background
        if self.tray:
            self.hide_to_tray()
        else:
            self.root.iconify()

    def quit(self):
        self.quitting = True
        self.worker.stop()
        if self.tray:
            try:
                self.tray.stop()
            except Exception:
                pass
        self.root.destroy()

    def run(self):
        self.root.mainloop()
