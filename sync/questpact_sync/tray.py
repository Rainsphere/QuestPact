"""Optional system tray icon. Needs `pip install pystray pillow`; returns None without them.

Not used on macOS: pystray needs the main thread there, which Tk already owns.
The window's minimize button does the same job.
"""

from .core import SYSTEM


def make_image(size=64):
    from PIL import Image, ImageDraw
    img = Image.new("RGBA", (size, size), (0, 0, 0, 0))
    d = ImageDraw.Draw(img)
    s = size / 32
    d.ellipse((0, 0, size - 1, size - 1), fill=(255, 205, 40, 255))
    d.ellipse((2 * s, 2 * s, size - 1 - 2 * s, size - 1 - 2 * s), fill=(30, 40, 70, 255))
    d.rectangle((14 * s, 6 * s, 18 * s - 1, 20 * s - 1), fill=(255, 205, 40, 255))
    d.rectangle((14 * s, 22 * s, 18 * s - 1, 26 * s - 1), fill=(255, 205, 40, 255))
    return img


def start_tray(on_show, on_sync, on_quit):
    if SYSTEM == "Darwin":
        return None
    try:
        import pystray
    except ImportError:
        return None
    try:
        menu = pystray.Menu(
            pystray.MenuItem("Show QuestPact Sync", lambda: on_show(), default=True),
            pystray.MenuItem("Sync now", lambda: on_sync()),
            pystray.Menu.SEPARATOR,
            pystray.MenuItem("Quit", lambda: on_quit()),
        )
        icon = pystray.Icon("questpact-sync", make_image(), "QuestPact Sync", menu)
        icon.run_detached()
        return icon
    except Exception:
        return None
