# Double-click to start QuestPact Sync (.pyw runs without a console window on Windows).
# From a terminal: python run.pyw [--once | --headless | --minimized]
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

from questpact_sync.app import main  # noqa: E402

sys.exit(main())
