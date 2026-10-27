"""Checks build.py's argument and appcast handling without building: uv run python -m unittest discover -s scripts -p 'test_*.py'"""
from pathlib import Path
import contextlib
import io
import tempfile
import unittest
from unittest import mock

import build


class ArgumentTests(unittest.TestCase):
    def test_unknown_argument_fails(self):
        with self.assertRaises(SystemExit), contextlib.redirect_stderr(io.StringIO()):
            build.parse_arguments(["--relase"])

    def test_release_is_recognized(self):
        self.assertTrue(build.parse_arguments(["--release"]).release)
        self.assertFalse(build.parse_arguments([]).release)

    def test_lab_is_opt_in_and_never_part_of_a_release(self):
        self.assertFalse(build.parse_arguments([]).lab)
        self.assertTrue(build.parse_arguments(["--lab"]).lab)
        with self.assertRaises(SystemExit), contextlib.redirect_stderr(io.StringIO()):
            build.parse_arguments(["--release", "--lab"])


class FeedTests(unittest.TestCase):
    def feed_with(self, build_number: str, version: str) -> str:
        return build.EMPTY_FEED.replace(build.FEED_ANCHOR, build.FEED_ANCHOR + build.feed_item(version, build_number, "Snug.zip", 'length="1"'))

    def test_empty_feed_accepts_any_whole_build(self):
        build.check_feed(build.EMPTY_FEED, "1.0.0", "2")

    def test_build_must_be_greater_than_every_listed_one(self):
        feed = self.feed_with("5", "0.9.0")
        for number in ("4", "5"):
            with self.assertRaises(SystemExit):
                build.check_feed(feed, "1.0.0", number)
        build.check_feed(feed, "1.0.0", "6")

    def test_version_must_be_new(self):
        with self.assertRaises(SystemExit):
            build.check_feed(self.feed_with("1", "1.0.0"), "1.0.0", "2")

    def test_build_must_be_a_whole_number(self):
        with self.assertRaises(SystemExit):
            build.check_feed(build.EMPTY_FEED, "1.0.0", "2a")

    def test_feed_needs_exactly_one_anchor(self):
        for feed in (build.EMPTY_FEED.replace(build.FEED_ANCHOR, ""), build.EMPTY_FEED.replace(build.FEED_ANCHOR, build.FEED_ANCHOR * 2)):
            with self.assertRaises(SystemExit):
                build.check_feed(feed, "1.0.0", "2")

    def test_missing_appcast_reads_as_an_empty_channel(self):
        with tempfile.TemporaryDirectory() as folder:
            self.assertEqual(build.read_feed(Path(folder) / "appcast.xml"), build.EMPTY_FEED)

    def test_write_puts_the_item_after_the_anchor_and_leaves_no_temporary_file(self):
        with tempfile.TemporaryDirectory() as folder:
            appcast = Path(folder) / "appcast.xml"
            item = build.feed_item("1.0.0", "2", "Snug-1.0.0.zip", 'sparkle:edSignature="x" length="1"')
            build.write_feed(appcast, build.read_feed(appcast), item)
            text = appcast.read_text()
            self.assertIn(build.FEED_ANCHOR + item, text)
            self.assertEqual(text.count("<item>"), 1)
            self.assertEqual([path.name for path in Path(folder).iterdir()], ["appcast.xml"])
            with self.assertRaises(SystemExit):
                build.check_feed(text, "1.0.1", "2")

    def test_write_refuses_a_feed_without_one_anchor(self):
        with tempfile.TemporaryDirectory() as folder:
            appcast = Path(folder) / "appcast.xml"
            appcast.write_text("<rss/>")
            with self.assertRaises(SystemExit):
                build.write_feed(appcast, "<rss/>", "<item/>")
            self.assertEqual(appcast.read_text(), "<rss/>")



IDENTITIES = """  1) AAAA1111 "Apple Development: Someone (TEAM1)"
  2) BBBB2222 "Developer ID Application: Someone (TEAM2)"
  3) CCCC3333 "Developer ID Application: Someone Else (TEAM3)"
     3 valid identities found
"""


class SigningIdentityTests(unittest.TestCase):
    def test_one_developer_id_by_hash_or_name(self):
        self.assertEqual(build.signing_identity_name(IDENTITIES, "BBBB2222"), "Developer ID Application: Someone (TEAM2)")
        self.assertEqual(build.signing_identity_name(IDENTITIES, "Someone Else"), "Developer ID Application: Someone Else (TEAM3)")

    def test_the_same_identity_listed_twice_counts_once(self):
        self.assertEqual(build.signing_identity_name(IDENTITIES + IDENTITIES, "BBBB2222"), "Developer ID Application: Someone (TEAM2)")

    def test_several_none_or_another_kind_fail(self):
        for identity in ("Developer ID Application", "Someone", "DDDD4444", "AAAA1111"):
            with self.assertRaises(SystemExit, msg=identity):
                build.signing_identity_name(IDENTITIES, identity)


class SparkleToolTests(unittest.TestCase):
    def tool_in(self, folder: Path, package: str) -> Path:
        tool = folder / ".build/artifacts" / package / "Sparkle/bin/sign_update"
        tool.parent.mkdir(parents=True)
        tool.touch()
        return tool

    def test_one_artifact_folder_is_used(self):
        with tempfile.TemporaryDirectory() as folder, mock.patch.object(build, "root", Path(folder)):
            tool = self.tool_in(Path(folder), "snug")
            self.assertEqual(build.sparkle_tool("sign_update"), tool)

    def test_none_or_several_fail(self):
        with tempfile.TemporaryDirectory() as folder, mock.patch.object(build, "root", Path(folder)):
            with self.assertRaises(SystemExit):
                build.sparkle_tool("sign_update")
            self.tool_in(Path(folder), "snug")
            self.tool_in(Path(folder), "old-checkout")
            with self.assertRaises(SystemExit):
                build.sparkle_tool("sign_update")


if __name__ == "__main__":
    unittest.main()
