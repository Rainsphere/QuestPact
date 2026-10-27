"""python -m unittest discover -s tests   (run from the sync folder)"""

import json
import os
import sys
import tempfile
import time
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent.parent))

from questpact_sync import core  # noqa: E402
from questpact_sync.luadata import parse_saved_variables, to_lua  # noqa: E402

# Written the way the WoW client writes SavedVariables
SV = r'''
QuestPactDB = {
["version"] = 1,
["minimapAngle"] = -2.356194490192345,
["chars"] = {
["Wifey-Dawnfall"] = {
["level"] = 15,
["class"] = "PRIEST",
["updated"] = 1800000060,
["completed"] = {
[50] = true,
[100] = true,
},
["history"] = {
{
["id"] = 100,
["title"] = "The \"Lost\" Letter \\ Part 2",
["zone"] = "Elwynn Forest",
["t"] = 1800000000,
}, -- [1]
{
["id"] = 101,
["title"] = "Kobold Candles\nof Fargodeep",
["zone"] = "Elwynn Forest",
["t"] = 1800000060,
}, -- [2]
},
["log"] = {
[200] = {
["title"] = "Murloc Fins",
["header"] = "Westfall",
["ready"] = false,
["obj"] = {
{
["text"] = "Murloc Fin: 2/8",
["have"] = 2,
["need"] = 8,
["done"] = false,
}, -- [1]
},
},
},
},
},
["skip"] = {
},
}
QuestPactOther = nil
'''


class LuaData(unittest.TestCase):
    def setUp(self):
        self.g = parse_saved_variables(SV)
        self.wife = self.g["QuestPactDB"]["chars"]["Wifey-Dawnfall"]

    def test_numbers_and_nesting(self):
        self.assertEqual(self.g["QuestPactDB"]["version"], 1)
        self.assertIsInstance(self.wife["level"], int)
        self.assertAlmostEqual(self.g["QuestPactDB"]["minimapAngle"], -2.356194490192345)

    def test_numeric_keys(self):
        self.assertEqual(list(self.wife["completed"]), ["50", "100"])

    def test_positional_entries_become_lists(self):
        self.assertIsInstance(self.wife["history"], list)
        self.assertEqual(self.wife["history"][1]["id"], 101)

    def test_escapes(self):
        self.assertEqual(self.wife["history"][0]["title"], 'The "Lost" Letter \\ Part 2')
        self.assertEqual(self.wife["history"][1]["title"], "Kobold Candles\nof Fargodeep")

    def test_empty_table_and_nil(self):
        self.assertEqual(self.g["QuestPactDB"]["skip"], {})
        self.assertIsNone(self.g["QuestPactOther"])

    def test_round_trip(self):
        lua = "X = " + to_lua(self.g["QuestPactDB"])
        self.assertEqual(parse_saved_variables(lua)["X"], json.loads(json.dumps(self.g["QuestPactDB"])))
        self.assertIn("[50] = true", lua)

    def test_strings_cannot_break_out(self):
        evil = 'x"] = 1 } os.exit() --\n]] \\'
        back = parse_saved_variables("X = " + to_lua({"title": evil, 'k"]': 1}))["X"]
        self.assertEqual(back["title"], evil)
        self.assertEqual(back['k"]'], 1)

    def test_non_ascii(self):
        back = parse_saved_variables("X = " + to_lua({"zone": "Zul'Farrak – Ébène"}))["X"]
        self.assertEqual(back["zone"], "Zul'Farrak – Ébène")


class TwoPCs(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        t = Path(self.tmp.name)
        os.environ["QUESTPACT_HOME"] = str(t / "home")
        self.shared = t / "shared"
        self.shared.mkdir()
        self.her = t / "her" / "_forever_"
        self.me = t / "me" / "_forever_"
        sv = self.her / "WTF" / "Account" / "WIFE123" / "SavedVariables" / "QuestPact.lua"
        sv.parent.mkdir(parents=True)
        sv.write_text(SV, encoding="utf-8")
        old = time.time() - 60
        os.utime(sv, (old, old))
        (self.her / "Interface" / "AddOns" / "QuestPact").mkdir(parents=True)
        (self.me / "WTF").mkdir(parents=True)
        (self.me / "Interface" / "AddOns" / "QuestPact").mkdir(parents=True)

    def tearDown(self):
        os.environ.pop("QUESTPACT_HOME", None)
        self.tmp.cleanup()

    def cfg(self, wow, name):
        # each "PC" gets its own state file
        os.environ["QUESTPACT_HOME"] = str(Path(self.tmp.name) / f"home-{name}")
        return core.Config(wow_dir=str(wow), shared_dir=str(self.shared), machine_name=name)

    def test_export_then_import(self):
        r1 = core.sync_once(self.cfg(self.her, "her-pc"))
        self.assertTrue(r1["ok"] and r1["exported"])
        self.assertEqual([p.name for p in self.shared.iterdir()], ["WIFE123@her-pc.json"])

        r2 = core.sync_once(self.cfg(self.me, "my-pc"))
        self.assertTrue(r2["imported"])
        lua = (self.me / "Interface" / "AddOns" / "QuestPact" / "PartnerData.lua").read_text(encoding="utf-8")
        pd = parse_saved_variables(lua)["QuestPact_PartnerData"]
        self.assertEqual(pd["chars"]["Wifey-Dawnfall"]["history"][0]["title"], 'The "Lost" Letter \\ Part 2')
        self.assertEqual(pd["chars"]["Wifey-Dawnfall"]["log"]["200"]["obj"][0]["need"], 8)

        r3 = core.sync_once(self.cfg(self.me, "my-pc"))
        self.assertFalse(r3["imported"], "unchanged data is not rewritten")
        partners = core.load_state()["partners"]
        self.assertEqual(partners[0]["key"], "Wifey-Dawnfall")
        self.assertEqual(partners[0]["from"], "WIFE123@her-pc")

    def test_newer_export_wins(self):
        core.sync_once(self.cfg(self.her, "her-pc"))
        newer = json.loads((self.shared / "WIFE123@her-pc.json").read_text(encoding="utf-8"))
        newer["machine"] = "her-laptop"
        newer["chars"]["Wifey-Dawnfall"]["level"] = 16
        newer["chars"]["Wifey-Dawnfall"]["updated"] += 100
        (self.shared / "WIFE123@her-laptop.json").write_text(json.dumps(newer), encoding="utf-8")
        chars, sources = core.collect_partners(self.shared)
        self.assertEqual(chars["Wifey-Dawnfall"]["level"], 16)
        self.assertEqual(sources["Wifey-Dawnfall"], "WIFE123@her-laptop")

    def test_missing_shared_folder_reported(self):
        cfg = self.cfg(self.me, "my-pc")
        cfg.shared_dir = str(Path(self.tmp.name) / "nope")
        r = core.sync_once(cfg)
        self.assertFalse(r["ok"])
        self.assertIn("Shared folder not found", r["problems"][0])

    def test_missing_addon_still_exports(self):
        import shutil
        shutil.rmtree(self.her / "Interface")
        r = core.sync_once(self.cfg(self.her, "her-pc"))
        self.assertTrue(r["ok"] and r["exported"])
        self.assertTrue(any("addon isn't installed" in p for p in r["problems"]))

    def test_config_round_trip_and_node_keys(self):
        os.environ["QUESTPACT_HOME"] = str(Path(self.tmp.name) / "home-cfg")
        core.config_path().parent.mkdir(parents=True, exist_ok=True)
        core.config_path().write_text(json.dumps({"wowDir": str(self.me), "sharedDir": str(self.shared), "pollSeconds": 1}))
        cfg = core.Config.load()
        self.assertEqual(cfg.wow_dir, str(self.me))
        self.assertEqual(cfg.poll_seconds, 3, "poll interval clamped")
        self.assertFalse(cfg.start_minimized, "opens the window by default")
        cfg.start_minimized = True
        cfg.save()
        self.assertEqual(core.Config.load(), cfg)


class Autostart(unittest.TestCase):
    def test_launch_command_points_at_this_app(self):
        from questpact_sync import autostart
        argv = autostart.launch_command()
        self.assertEqual(argv[-1], "--minimized")
        self.assertTrue(Path(argv[0]).exists())
        if not core.frozen():
            self.assertTrue(argv[1].endswith("run.pyw") and Path(argv[1]).exists())


if __name__ == "__main__":
    unittest.main()
