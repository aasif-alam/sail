"""Tests for lib/subs.py — all network calls are mocked."""

import os
import sys
import unittest
from unittest import mock

sys.path.insert(0, os.path.join(os.path.dirname(__file__), "..", "lib"))
import subs  # noqa: E402


class CleanQueryTest(unittest.TestCase):
    def test_tv_episode_extracts_title_and_tags(self):
        title, season, episode = subs.clean_query(
            "Some.Show.S02E07.1080p.WEB-DL.x264-GROUP.mkv")
        self.assertEqual(title, "Some Show")
        self.assertEqual(season, 2)
        self.assertEqual(episode, 7)

    def test_movie_cuts_at_year(self):
        title, season, episode = subs.clean_query(
            "Some.Movie.2019.1080p.BluRay.x265-GROUP.mkv")
        self.assertEqual(title, "Some Movie")
        self.assertIsNone(season)
        self.assertIsNone(episode)

    def test_cuts_at_quality_tag_when_no_year_or_episode(self):
        title, _, _ = subs.clean_query("Random Title 720p HDTV.mp4")
        self.assertEqual(title, "Random Title")

    def test_plain_filename_with_no_tags(self):
        title, season, episode = subs.clean_query("home_video.mov")
        self.assertEqual(title, "home video")
        self.assertIsNone(season)
        self.assertIsNone(episode)

    def test_lowercase_episode_tag(self):
        _, season, episode = subs.clean_query("show.s1e3.mkv")
        self.assertEqual(season, 1)
        self.assertEqual(episode, 3)


class FindFileIdTest(unittest.TestCase):
    @mock.patch("subs.api_request")
    def test_picks_highest_download_count(self, mock_req):
        mock_req.return_value = {"data": [
            {"attributes": {"download_count": 5, "files": [{"file_id": 111}]}},
            {"attributes": {"download_count": 500, "files": [{"file_id": 222}]}},
        ]}
        file_id = subs.find_file_id("Some Show", 1, 2, "en", "key")
        self.assertEqual(file_id, 222)

    @mock.patch("subs.api_request")
    def test_no_results_returns_none(self, mock_req):
        mock_req.return_value = {"data": []}
        self.assertIsNone(subs.find_file_id("Nothing", None, None, "en", "key"))

    @mock.patch("subs.api_request")
    def test_result_with_no_files_returns_none(self, mock_req):
        mock_req.return_value = {"data": [{"attributes": {"download_count": 1, "files": []}}]}
        self.assertIsNone(subs.find_file_id("Nothing", None, None, "en", "key"))


class DownloadLinkTest(unittest.TestCase):
    @mock.patch("subs.api_request")
    def test_returns_link_field(self, mock_req):
        mock_req.return_value = {"link": "https://example.com/sub.srt"}
        self.assertEqual(subs.download_link(123, "key"), "https://example.com/sub.srt")


class MainIntegrationTest(unittest.TestCase):
    def test_missing_api_key_exits_nonzero_without_network(self):
        with mock.patch.dict(os.environ, {}, clear=True), \
             mock.patch("sys.argv", ["subs.py", "some.movie.mkv", "/tmp/out.srt"]), \
             mock.patch("subs.find_file_id") as mock_find:
            with self.assertRaises(SystemExit) as cm:
                subs.main()
            self.assertNotEqual(cm.exception.code, 0)
            mock_find.assert_not_called()


if __name__ == "__main__":
    unittest.main()
