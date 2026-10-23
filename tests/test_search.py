"""Tests for lib/search.py — all network calls are mocked, nothing hits
the real internet."""

import json
import os
import shutil
import sys
import tempfile
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

    @mock.patch("search.http_json")
    def test_age_comes_from_upload_time(self, mock_json):
        when = int(time.time() - 3 * 86400)
        mock_json.return_value = {"data": {"movies": [{
            "title": "Example", "year": 2024, "title_long": "Example (2024)",
            "date_uploaded_unix": when,
            "torrents": [{"quality": "1080p", "type": "web", "seeds": 5,
                          "size": "2.1 GB", "hash": "H1"}],
        }]}}
        results = search.search_yts("example")
        self.assertEqual(results[0]["age"], "3d ago")

    @mock.patch("search.http_json")
    def test_age_falls_back_to_torrent_upload_time(self, mock_json):
        when = int(time.time() - 2 * 86400)
        mock_json.return_value = {"data": {"movies": [{
            "title": "Example", "year": 2024, "title_long": "Example (2024)",
            "torrents": [{"quality": "1080p", "type": "web", "seeds": 5,
                          "size": "2.1 GB", "hash": "H1",
                          "date_uploaded_unix": when}],
        }]}}
        results = search.search_yts("example")
        self.assertEqual(results[0]["age"], "2d ago")


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


class IntHelperTest(unittest.TestCase):
    def test_parses_commas_and_junk(self):
        self.assertEqual(search._int("1,234"), 1234)
        self.assertEqual(search._int(" 7 "), 7)
        self.assertEqual(search._int(None), 0)
        self.assertEqual(search._int("n/a", -1), -1)


class SearchEztvTest(unittest.TestCase):
    @mock.patch("search.http_json")
    def test_uses_date_released_unix(self, mock_json):
        mock_json.return_value = {"torrents": [{
            "title": "Show S01E01\n1080p",
            "magnet_url": "magnet:?xt=urn:btih:H1",
            "seeds": "5",
            "size_bytes": "1234",
            "date_released_unix": str(int(time.time() - 3 * 86400)),
        }]}
        results = search.search_eztv("show")
        self.assertEqual(len(results), 1)
        self.assertEqual(results[0]["age"], "3d ago")
        self.assertEqual(results[0]["seeders"], 5)
        self.assertNotIn("\n", results[0]["title"])


class SearchNyaaTest(unittest.TestCase):
    ROW = (
        '<tr class="default">'
        '<td class="text-center"><a href="/?c=1_2">Anime</a></td>'
        '<td><a href="/view/123" title="[Subs] Show - 01 (1080p)">'
        '[Subs] Show - 01 (1080p)</a></td>'
        '<td class="text-center"><a href="magnet:?xt=urn:btih:'
        'AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA&amp;dn=show">M</a></td>'
        '<td class="text-center">1.4 GiB</td>'
        '<td class="text-center" data-timestamp="1700000000">2023-11-14</td>'
        '<td class="text-center text-success">42</td>'
        '<td class="text-center text-danger">3</td>'
        '<td class="text-center">100</td>'
        '</tr>'
    )

    @mock.patch("search.http_get")
    def test_reads_seeders_from_success_cell(self, mock_get):
        mock_get.return_value = self.ROW
        results = search.search_nyaa("show")
        self.assertEqual(len(results), 1)
        self.assertEqual(results[0]["seeders"], 42)
        self.assertEqual(results[0]["size"], "1.4 GB")
        self.assertEqual(results[0]["title"], "[Subs] Show - 01 (1080p)")
        self.assertTrue(results[0]["magnet"].startswith("magnet:?xt=urn:btih:A"))


class Search1337xTest(unittest.TestCase):
    PAGE = """
    <table><tbody>
    <tr>
      <td class="coll-1 name">
        <a href="/torrent/123/some-show-s01e01/" class="icon"><span></span></a>
        <a href="/torrent/123/some-show-s01e01/">Some Show <b>S01E01</b></a>
      </td>
      <td class="coll-2 seeds">1,234</td>
      <td class="coll-3 leeches">2</td>
      <td class="coll-4 size mob-avatar-warning">1.4 GB<span>1,234</span></td>
    </tr>
    </tbody></table>
    """

    @mock.patch("search.http_get")
    def test_parses_seeders_and_size(self, mock_get):
        mock_get.return_value = self.PAGE
        results = search.search_1337x("some show")
        self.assertEqual(len(results), 1)
        self.assertEqual(results[0]["title"], "Some Show S01E01")
        self.assertEqual(results[0]["seeders"], 1234)
        self.assertEqual(results[0]["size"], "1.4GB")
        self.assertTrue(results[0]["magnet"].startswith("FETCH:https://"))


def _row(title="Result", seeders=10, magnet="magnet:?xt=urn:btih:H"):
    return {"title": title, "seeders": seeders, "size": "1.0GB",
            "source": "tpb", "age": "1d ago", "magnet": magnet}


class SourceErrorOutputTest(unittest.TestCase):
    def test_all_sources_failing_exits_2_with_summary(self):
        import io

        def boom(_query):
            raise RuntimeError("kABOOM")

        with mock.patch.object(search, "ALL_SOURCES", {"boom": boom}), \
             mock.patch.object(sys, "argv",
                               ["search.py", "--sources=boom", "x"]), \
             mock.patch.object(sys, "stderr", new_callable=io.StringIO) as err:
            with self.assertRaises(SystemExit) as cm:
                search.main()
        self.assertEqual(cm.exception.code, 2)
        out = err.getvalue()
        self.assertIn("[source error] boom: kABOOM", out)
        self.assertIn("[sources] 1 of 1 unavailable", out)

    def test_partial_failure_prints_summary_but_succeeds(self):
        import io

        def boom(_query):
            raise RuntimeError("timed out")

        def good(_query):
            return [_row()]

        with mock.patch.object(search, "ALL_SOURCES",
                               {"boom": boom, "good": good}), \
             tempfile.TemporaryDirectory() as cd, \
             mock.patch.dict(os.environ, {"SAIL_CACHE_DIR": cd}), \
             mock.patch.object(sys, "argv",
                               ["search.py", "--sources=boom,good", "x"]), \
             mock.patch.object(sys, "stdout", new_callable=io.StringIO) as out, \
             mock.patch.object(sys, "stderr", new_callable=io.StringIO) as err:
            search.main()  # no SystemExit: at least one source worked
        self.assertIn("Result", out.getvalue())
        self.assertIn("[sources] 1 of 2 unavailable", err.getvalue())

    def test_no_enabled_sources_exits_3(self):
        import io
        import tempfile
        with tempfile.NamedTemporaryFile("w", suffix=".conf") as f:
            path = f.name
            with mock.patch.dict(os.environ, {"SAIL_SOURCES": path}), \
                 mock.patch.object(sys, "argv", ["search.py", "x"]), \
                 mock.patch.object(sys, "stderr",
                                   new_callable=io.StringIO) as err:
                with self.assertRaises(SystemExit) as cm:
                    search.main()
        self.assertEqual(cm.exception.code, 3)
        self.assertIn("no sources enabled", err.getvalue())


class ResultPipelineTest(unittest.TestCase):
    def test_filter_relevant_requires_every_significant_word(self):
        results = [_row("Ubuntu Server 24.04"), _row("Ubuntu Desktop"),
                   _row("Debian Server")]
        out = search.filter_relevant(results, "ubuntu server")
        self.assertEqual([r["title"] for r in out], ["Ubuntu Server 24.04"])

    def test_filter_relevant_ignores_short_words(self):
        self.assertEqual(len(search.filter_relevant([_row()], "a b c")), 1)

    def test_dedupe_keeps_best_seeded_copy_and_sorts(self):
        results = [_row("Same Title", 5), _row("same title", 50),
                   _row("Other", 20)]
        out = search.dedupe_sorted(results)
        self.assertEqual([r["title"] for r in out], ["same title", "Other"])
        self.assertEqual(out[0]["seeders"], 50)

    def test_tsv_rows_have_exactly_seven_fields(self):
        rows = search.to_rows([_row("Bad\tTitle\nHere",
                                    magnet="magnet:?xt=urn:btih:H\tx")])
        tsv = search.to_tsv(rows)
        lines = tsv.splitlines()
        self.assertEqual(len(lines), 1)
        self.assertEqual(len(lines[0].split("\t")), 7)
        self.assertEqual(rows[0]["title"], "Bad Title Here")

    def test_json_has_all_columns(self):
        rows = search.to_rows([_row()])
        parsed = json.loads(search.to_json(rows))
        self.assertEqual(set(parsed[0]),
                         {"id", "seeders", "size", "source", "title",
                          "age", "magnet"})


class MagnetFromDetailTest(unittest.TestCase):
    @mock.patch("search.http_get")
    def test_extracts_and_unescapes_magnet(self, mock_get):
        mock_get.return_value = (
            '<a href="magnet:?xt=urn:btih:ABC&amp;dn=Show">m</a>')
        self.assertEqual(search.magnet_from_detail("https://example/x"),
                         "magnet:?xt=urn:btih:ABC&dn=Show")

    @mock.patch("search.http_get")
    def test_missing_magnet_raises(self, mock_get):
        mock_get.return_value = "<html>gone</html>"
        with self.assertRaises(RuntimeError):
            search.magnet_from_detail("https://example/x")


class JsonModeTest(unittest.TestCase):
    def test_json_mode_prints_a_parseable_array(self):
        import io

        def good(_query):
            return [_row()]

        with mock.patch.object(search, "ALL_SOURCES", {"good": good}), \
             tempfile.TemporaryDirectory() as cd, \
             mock.patch.dict(os.environ, {"SAIL_CACHE_DIR": cd}), \
             mock.patch.object(sys, "argv",
                               ["search.py", "--json", "--sources=good", "x"]), \
             mock.patch.object(sys, "stdout", new_callable=io.StringIO) as out, \
             mock.patch.object(sys, "stderr", new_callable=io.StringIO):
            search.main()
        parsed = json.loads(out.getvalue())
        self.assertEqual(len(parsed), 1)
        self.assertEqual(parsed[0]["title"], "Result")


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

    def test_empty_config_means_no_sources(self):
        import tempfile
        with tempfile.NamedTemporaryFile("w", suffix=".conf", delete=False) as f:
            path = f.name
        try:
            with mock.patch.dict(os.environ, {"SAIL_SOURCES": path}):
                self.assertEqual(search.load_enabled(), [])
        finally:
            os.unlink(path)

    def test_config_with_only_bogus_sources_is_empty(self):
        import tempfile
        with tempfile.NamedTemporaryFile("w", suffix=".conf", delete=False) as f:
            f.write("not_a_real_source\n")
            path = f.name
        try:
            with mock.patch.dict(os.environ, {"SAIL_SOURCES": path}):
                self.assertEqual(search.load_enabled(), [])
        finally:
            os.unlink(path)

    def test_whitespace_dupes_and_unknowns(self):
        import tempfile
        with tempfile.NamedTemporaryFile("w", suffix=".conf", delete=False) as f:
            f.write(" tpb \nnyaa\ntpb\nbogus_source\n")
            path = f.name
        try:
            with mock.patch.dict(os.environ, {"SAIL_SOURCES": path}):
                enabled, unknown = search.read_config()
                self.assertEqual(enabled, ["tpb", "nyaa"])
                self.assertEqual(unknown, ["bogus_source"])
        finally:
            os.unlink(path)

    def test_enabled_mode_prints_one_name_per_line(self):
        import io
        import tempfile
        with tempfile.NamedTemporaryFile("w", suffix=".conf", delete=False) as f:
            f.write("tpb\nnyaa\n")
            path = f.name
        try:
            with mock.patch.dict(os.environ, {"SAIL_SOURCES": path}), \
                 mock.patch.object(sys, "argv", ["search.py", "--enabled"]), \
                 mock.patch.object(sys, "stdout",
                                   new_callable=io.StringIO) as out:
                search.main()
            self.assertEqual(out.getvalue(), "tpb\nnyaa\n")
        finally:
            os.unlink(path)


class ListSourcesTest(unittest.TestCase):
    def test_third_column_marks_enabled_by_default(self):
        import subprocess
        out = subprocess.run(
            [sys.executable,
             os.path.join(os.path.dirname(__file__), "..", "lib", "search.py"),
             "--list-sources"],
            capture_output=True, text=True, check=True).stdout
        rows = {}
        for line in out.splitlines():
            name, _desc, default = line.split("\t")
            rows[name] = default
        for name in search.DEFAULT_ENABLED:
            self.assertEqual(rows[name], "1", name)
        self.assertEqual(rows["1337x"], "0")
        self.assertEqual(set(rows), set(search.ALL_SOURCES))


class SourceInfoConsistencyTest(unittest.TestCase):
    """Guards against the README/registry drift this test suite was added
    to catch: every registered source needs a description, and vice versa."""

    def test_every_source_has_info_and_info_has_no_orphans(self):
        self.assertEqual(set(search.ALL_SOURCES), set(search.SOURCE_INFO))

    def test_default_enabled_are_all_registered(self):
        for name in search.DEFAULT_ENABLED:
            self.assertIn(name, search.ALL_SOURCES)


class RunSearchDeadlineTest(unittest.TestCase):
    """run_search must bound the whole search phase: a source hanging past
    the deadline is dropped (and reported unavailable) instead of defining
    the search time, and its still-running thread must not hold up the
    caller afterwards."""

    def setUp(self):
        self.cache_dir = tempfile.mkdtemp()
        self.addCleanup(shutil.rmtree, self.cache_dir, True)
        self.env = {"SAIL_SEARCH_TIMEOUT": "0.5", "SAIL_CACHE_DIR": self.cache_dir}

    def test_slow_source_dropped_fast_source_kept(self):
        def slow(_query):
            time.sleep(3)
            return [_row("Slow")]

        def fast(_query):
            return [_row("Fast")]

        with mock.patch.object(search, "ALL_SOURCES",
                               {"slow": slow, "fast": fast}), \
             mock.patch.dict(os.environ, self.env):
            start = time.monotonic()
            results, errors = search.run_search(["slow", "fast"], "x")
            elapsed = time.monotonic() - start
        self.assertEqual([r["title"] for r in results], ["Fast"])
        self.assertEqual(len(errors), 1)
        self.assertIn("slow", errors[0])
        self.assertIn("deadline", errors[0])
        # fast answers within the budget; the dropped source must not stretch
        # the wait anything like its full sleep
        self.assertLess(elapsed, 3.0)

    def test_all_sources_dropped_exits_2(self):
        import io

        def slow(_query):
            time.sleep(3)
            return [_row("Slow")]

        with mock.patch.object(search, "ALL_SOURCES", {"slow": slow}), \
             mock.patch.dict(os.environ, self.env), \
             mock.patch.object(sys, "argv",
                               ["search.py", "--sources=slow", "x"]), \
             mock.patch.object(sys, "stderr",
                               new_callable=io.StringIO) as err:
            with self.assertRaises(SystemExit) as cm:
                search.main()
        self.assertEqual(cm.exception.code, 2)
        self.assertIn("1 of 1 unavailable", err.getvalue())
        self.assertIn("deadline", err.getvalue())


class RunSearchCacheTest(unittest.TestCase):
    """The per-(source, query) cache must make repeat searches instant,
    without ever pinning a failure or an empty answer in place."""

    def setUp(self):
        self.cache_dir = tempfile.mkdtemp()
        self.addCleanup(shutil.rmtree, self.cache_dir, True)

    def run_twice(self, result_of_call, extra_env=()):
        """Run the same (source, query) twice; count the source's calls."""
        calls = []

        def fake(_query):
            calls.append(1)
            return result_of_call()

        env = {"SAIL_CACHE_DIR": self.cache_dir}
        env.update(dict(extra_env))
        with mock.patch.object(search, "ALL_SOURCES", {"fake": fake}), \
             mock.patch.dict(os.environ, env):
            first = search.run_search(["fake"], "q")
            second = search.run_search(["fake"], "q")
        return calls, first, second

    def test_repeat_search_is_served_from_cache(self):
        calls, (out1, _), (out2, _) = self.run_twice(lambda: [_row("Cached")])
        self.assertEqual(len(calls), 1)
        self.assertEqual([r["title"] for r in out1], ["Cached"])
        self.assertEqual([r["title"] for r in out2], ["Cached"])

    def test_failed_source_is_not_cached(self):
        def boom():
            raise RuntimeError("down")

        calls, (out1, err1), (out2, err2) = self.run_twice(boom)
        self.assertEqual(len(calls), 2)
        self.assertEqual(out1, [])
        self.assertEqual(out2, [])
        self.assertTrue(err1 and err2)

    def test_empty_results_are_not_cached(self):
        calls, _, _ = self.run_twice(lambda: [])
        self.assertEqual(len(calls), 2)

    def test_sail_no_cache_disables_caching(self):
        calls, _, _ = self.run_twice(
            lambda: [_row("Fresh")], {"SAIL_NO_CACHE": "1"})
        self.assertEqual(len(calls), 2)

    def test_zero_ttl_disables_caching(self):
        calls, _, _ = self.run_twice(
            lambda: [_row("Fresh")], {"SAIL_CACHE_TTL": "0"})
        self.assertEqual(len(calls), 2)


if __name__ == "__main__":
    unittest.main()
