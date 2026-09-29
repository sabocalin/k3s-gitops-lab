"""Unit tests for ai_review.py (stdlib unittest; run: python3 -m unittest discover .github/scripts)."""
import io
import json
import unittest
import urllib.error
from unittest import mock

import ai_review

DIFF = """diff --git a/app/main.py b/app/main.py
index 1111111..2222222 100644
--- a/app/main.py
+++ b/app/main.py
@@ -1,3 +1,4 @@
 import os
-x = 1
+x = 2
+y = 3
 print(x)
@@ -10,2 +11,3 @@ def f():
     return 1
+    # added

diff --git a/old.txt b/old.txt
deleted file mode 100644
--- a/old.txt
+++ /dev/null
@@ -1 +0,0 @@
-gone
diff --git a/new.txt b/new.txt
new file mode 100644
--- /dev/null
+++ b/new.txt
@@ -0,0 +1,2 @@
+one
+two
"""


class AddedLines(unittest.TestCase):
    def test_added_line_numbers(self):
        m = ai_review.added_lines(DIFF)
        self.assertEqual(m["app/main.py"], {2, 3, 12})
        self.assertEqual(m["new.txt"], {1, 2})

    def test_deleted_file_has_no_commentable_lines(self):
        self.assertNotIn("old.txt", ai_review.added_lines(DIFF))


class ExtractJson(unittest.TestCase):
    def test_plain(self):
        self.assertEqual(ai_review.extract_json('{"a": 1}'), {"a": 1})

    def test_fenced_with_prose(self):
        self.assertEqual(ai_review.extract_json('Sure:\n```json\n{"a": 1}\n```\nDone.'), {"a": 1})

    def test_no_json(self):
        with self.assertRaises(ValueError):
            ai_review.extract_json("no json here")


class Partition(unittest.TestCase):
    def test_splits_on_commentable_lines(self):
        m = ai_review.added_lines(DIFF)
        findings = [
            {"path": "app/main.py", "line": 3, "comment": "ok"},      # added line
            {"path": "app/main.py", "line": 1, "comment": "context"},  # unchanged line
            {"path": "nope.py", "line": 1, "comment": "unknown file"},
            {"path": "app/main.py", "line": "x", "comment": "bad line"},
        ]
        inline, rest = ai_review.partition(findings, m)
        self.assertEqual([f["comment"] for f in inline], ["ok"])
        self.assertEqual(len(rest), 3)


class RetryDelay(unittest.TestCase):
    def test_google_retry_info(self):
        body = json.dumps([{"error": {"details": [
            {"@type": "type.googleapis.com/google.rpc.RetryInfo", "retryDelay": "35s"}]}}])
        self.assertEqual(ai_review.retry_delay(body, 1), 36.0)

    def test_quota_ids_names_the_violated_quota(self):
        body = json.dumps([{"error": {"details": [
            {"@type": "type.googleapis.com/google.rpc.QuotaFailure", "violations": [
                {"quotaId": "GenerateRequestsPerDayPerProjectPerModel-FreeTier", "quotaValue": "20"}]}]}}])
        self.assertEqual(ai_review.quota_ids(body), "GenerateRequestsPerDayPerProjectPerModel-FreeTier=20")
        self.assertEqual(ai_review.quota_ids("garbage"), "unparseable body")

    def test_backoff_without_retry_info(self):
        self.assertTrue(30 <= ai_review.retry_delay("not json", 1) <= 33)


def http_error(code, body):
    return urllib.error.HTTPError("u", code, "err", {}, io.BytesIO(json.dumps(body).encode()))


class Fallback(unittest.TestCase):
    def test_skips_exhausted_and_retired_models(self):
        per_day = [{"error": {"details": [{"@type": "type.googleapis.com/google.rpc.QuotaFailure",
                    "violations": [{"quotaId": "GenerateRequestsPerDayPerProjectPerModel-FreeTier",
                                    "quotaValue": "20"}]}]}}]
        replies = {"m1": http_error(429, per_day), "m2": http_error(404, {"error": {"message": "gone"}})}

        def fake(url, payload, headers, method="POST"):
            if payload["model"] in replies:
                raise replies[payload["model"]]
            return {"choices": [{"message": {"content": "{}"}}]}

        with mock.patch.object(ai_review, "http_json", side_effect=fake):
            model, reply = ai_review.call_llm("u", "k", ["m1", "m2", "m3"], "diff")
        self.assertEqual((model, reply), ("m3", "{}"))

    def test_network_errors_retry_then_fall_back(self):
        calls = []

        def fake(url, payload, headers, method="POST"):
            calls.append(payload["model"])
            if payload["model"] == "m1":
                raise TimeoutError("The read operation timed out")
            if len(calls) == 4:  # m2, first try
                raise ConnectionResetError("reset by peer")
            return {"choices": [{"message": {"content": "{}"}}]}

        with mock.patch.object(ai_review, "http_json", side_effect=fake), \
                mock.patch.object(ai_review.time, "sleep"):
            model, _ = ai_review.call_llm("u", "k", ["m1", "m2"], "diff")
        self.assertEqual(model, "m2")
        self.assertEqual(calls, ["m1", "m1", "m1", "m2", "m2"])

    def test_http_error_is_not_swallowed_by_network_branch(self):
        per_day = [{"error": {"details": [{"@type": "type.googleapis.com/google.rpc.QuotaFailure",
                    "violations": [{"quotaId": "GenerateRequestsPerDayPerProjectPerModel-FreeTier",
                                    "quotaValue": "20"}]}]}}]
        calls = []

        def fake(url, payload, headers, method="POST"):
            calls.append(payload["model"])
            if payload["model"] == "m1":
                raise http_error(429, per_day)
            return {"choices": [{"message": {"content": "{}"}}]}

        with mock.patch.object(ai_review, "http_json", side_effect=fake), \
                mock.patch.object(ai_review.time, "sleep"):
            ai_review.call_llm("u", "k", ["m1", "m2"], "diff")
        self.assertEqual(calls, ["m1", "m2"])  # daily quota: skip at once, no retries

    def test_all_models_fail_exits_with_error(self):
        with mock.patch.object(ai_review, "http_json", side_effect=http_error(404, {})):
            with self.assertRaises(SystemExit):
                ai_review.call_llm("u", "k", ["m1", "m2"], "diff")


class LastReviewedCommit(unittest.TestCase):
    BOT, M = ai_review.BOT_LOGIN, ai_review.REVIEW_MARKER

    def review(self, login, body, commit, when):
        return {"user": {"login": login}, "body": body, "commit_id": commit, "submitted_at": when}

    def test_newest_own_review_wins(self):
        reviews = [
            self.review(self.BOT, self.M + " old", "aaa", "2026-09-29T08:00:00Z"),
            self.review(self.BOT, self.M + " new", "bbb", "2026-09-29T09:00:00Z"),
            self.review("sabocalin", "LGTM", "ccc", "2026-09-29T10:00:00Z"),       # human
            self.review(self.BOT, "some other bot review", "ddd", "2026-09-29T11:00:00Z"),
        ]
        self.assertEqual(ai_review.last_reviewed_commit(reviews, "head", lambda a, b: True), "bbb")

    def test_none_without_own_review(self):
        reviews = [self.review("sabocalin", "LGTM", "ccc", "2026-09-29T10:00:00Z")]
        self.assertIsNone(ai_review.last_reviewed_commit(reviews, "head", lambda a, b: True))

    def test_force_push_falls_back_to_full_review(self):
        reviews = [self.review(self.BOT, self.M, "gone", "2026-09-29T09:00:00Z")]
        self.assertIsNone(ai_review.last_reviewed_commit(reviews, "head", lambda a, b: False))


if __name__ == "__main__":
    unittest.main()
