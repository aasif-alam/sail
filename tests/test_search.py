"""Tests for lib/search.py — all network calls are mocked, nothing hits
the real internet."""

import json
import os
import sys
import time
import unittest
from unittest import mock

sys.path.insert(0, os.path.join(os.path.dirname(__file__), "..", "lib"))
import search  # noqa: E402


class HumanSizeTest(unittest.TestCase):
    def test_bytes_and_units(self):
        self.assertEqual(search.human_size(0), "0.0B")
        self.assertEqual(search.human_size(1536), "1.5KB")
        self.assertEqual(search.human_size(1024 ** 3), "1.0GB")

    def test_non_numeric_is_unknown(self):
        self.assertEqual(search.human_size(None), "?")
        self.assertEqual(search.human_size("not a number"), "?")


class AgoTest(unittest.TestCase):
    def test_recent_is_just_now(self):
        self.assertEqual(search.ago(time.time()), "just now")

    def test_days_ago(self):
        self.assertEqual(search.ago(time.time() - 3 * 86400), "3d ago")

    def test_future_or_missing_is_unknown(self):
        self.assertEqual(search.ago(time.time() + 1000), "?")
        self.assertEqual(search.ago(None), "?")


class MagnetFromHashTest(unittest.TestCase):
    def test_includes_hash_name_and_trackers(self):
        m = search.magnet_from_hash("ABC123", "My Movie")
        self.assertTrue(m.startswith("magnet:?xt=urn:btih:ABC123"))
        self.assertIn("dn=My%20Movie", m)
        import urllib.parse
        for tr in search.TRACKERS:
            self.assertIn("tr=" + urllib.parse.quote(tr), m)


class FirstSuccessTest(unittest.TestCase):
    def test_returns_first_truthy_result(self):
        result = search.first_success([lambda: None, lambda: [], lambda: ["ok"]])
        self.assertEqual(result, ["ok"])

    def test_ignores_exceptions(self):
        def boom():
            raise RuntimeError("dead host")

        result = search.first_success([boom, lambda: ["ok"]])
        self.assertEqual(result, ["ok"])

    def test_all_fail_returns_empty_list(self):
        def boom():
            raise RuntimeError("dead host")

        self.assertEqual(search.first_success([boom, lambda: None]), [])

    def test_empty_input_returns_empty_list(self):
        self.assertEqual(search.first_success([]), [])


class SearchApibayTest(unittest.TestCase):
    @mock.patch("search.http_json")
    def test_parses_and_filters_zero_seeders(self, mock_json):
        mock_json.return_value = [
            {"id": "1", "name": "Ubuntu 24.04", "seeders": "12",
             "size": "4000000000", "info_hash": "H1", "added": str(int(time.time()))},
            {"id": "2", "name": "Dead Torrent", "seeders": "0",
             "size": "100", "info_hash": "H2", "added": "0"},
            {"id": "0", "name": "No results sentinel", "seeders": "0",
             "size": "0", "info_hash": "H3", "added": "0"},
        ]
        results = search.search_apibay("ubuntu")
        self.assertEqual(len(results), 1)
        self.assertEqual(results[0]["title"], "Ubuntu 24.04")
        self.assertEqual(results[0]["seeders"], 12)
        self.assertEqual(results[0]["source"], "tpb")


class SearchYtsTest(unittest.TestCase):
    @mock.patch("search.http_json")
    def test_flattens_one_row_per_torrent(self, mock_json):
        mock_json.return_value = {
            "data": {
                "movies": [{
                    "title": "Example",
                    "year": 2024,
                    "title_long": "Example (2024)",
                    "torrents": [
                        {"quality": "1080p", "type": "web", "seeds": 50,
                         "size": "2.1 GB", "hash": "H1"},
                        {"quality": "720p", "type": "web", "seeds": 20,
                         "size": "1.1 GB", "hash": "H2"},
                    ],
                }]
            }
        }
        results = search.search_yts("example")
        self.assertEqual(len(results), 2)
        self.assertEqual(results[0]["title"], "Example (2024) 1080p web")
        self.assertEqual(results[0]["seeders"], 50)

    @mock.patch("search.http_json")
    def test_no_matches_returns_empty(self, mock_json):
        mock_json.return_value = {"data": {}}
        self.assertEqual(search.search_yts("nothing"), [])


class SearchTorrentsCsvTest(unittest.TestCase):
    @mock.patch("search.http_json")
    def test_parses_rows(self, mock_json):
        mock_json.return_value = {"torrents": [
            {"name": "Some Show S01E01", "seeders": "7",
             "size_bytes": "500000000", "infohash": "H1",
             "created_unix": str(int(time.time()))},
        ]}
        results = search.search_torrentscsv("some show")
        self.assertEqual(len(results), 1)
        self.assertEqual(results[0]["source"], "tcsv")
        self.assertEqual(results[0]["seeders"], 7)


class LoadEnabledTest(unittest.TestCase):
    def test_missing_config_returns_defaults(self):
        with mock.patch.dict(os.environ, {"SAIL_SOURCES": "/nonexistent/path"}):
            self.assertEqual(search.load_enabled(), search.DEFAULT_ENABLED)

    def test_reads_config_file(self):
        import tempfile
        with tempfile.NamedTemporaryFile("w", suffix=".conf", delete=False) as f:
            f.write("tpb\nnyaa\n# a comment\n\nbogus_source\n")
            path = f.name
        try:
            with mock.patch.dict(os.environ, {"SAIL_SOURCES": path}):
                self.assertEqual(search.load_enabled(), ["tpb", "nyaa"])
        finally:
            os.unlink(path)

    def test_config_with_only_bogus_sources_falls_back_to_defaults(self):
        import tempfile
        with tempfile.NamedTemporaryFile("w", suffix=".conf", delete=False) as f:
            f.write("not_a_real_source\n")
            path = f.name
        try:
            with mock.patch.dict(os.environ, {"SAIL_SOURCES": path}):
                self.assertEqual(search.load_enabled(), search.DEFAULT_ENABLED)
        finally:
            os.unlink(path)


class SourceInfoConsistencyTest(unittest.TestCase):
    """Guards against the README/registry drift this test suite was added
    to catch: every registered source needs a description, and vice versa."""

    def test_every_source_has_info_and_info_has_no_orphans(self):
        self.assertEqual(set(search.ALL_SOURCES), set(search.SOURCE_INFO))

    def test_default_enabled_are_all_registered(self):
        for name in search.DEFAULT_ENABLED:
            self.assertIn(name, search.ALL_SOURCES)


if __name__ == "__main__":
    unittest.main()
