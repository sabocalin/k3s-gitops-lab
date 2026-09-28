"""Unit tests for ai_review.py (stdlib unittest; run: python3 -m unittest discover .github/scripts)."""
import json
import unittest

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


if __name__ == "__main__":
    unittest.main()
