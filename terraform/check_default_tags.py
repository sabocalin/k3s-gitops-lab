#!/usr/bin/env python3
"""Fail if any taggable resource in a stack's state lacks the project's default tags.

Usage (from a stack directory):
    AWS_PROFILE=personal terraform show -json | python3 ../check_default_tags.py
Exit code 1 when a taggable resource is missing a tag. Resources that cannot carry tags
(e.g. route table associations) are listed and skipped.
"""
import json, sys
st = json.load(sys.stdin)
need = {"Project", "Stack", "ManagedBy", "Repo"}
bad = 0
for r in st["values"]["root_module"]["resources"]:
    if r["mode"] != "managed":
        continue
    addr, tags = r["address"], r["values"].get("tags_all")
    if tags is None:
        print("  (not taggable)", addr)
        continue
    missing = sorted(need - set(tags))
    print("  MISSING" if missing else "  OK     ", addr, missing or tags["Stack"])
    bad += bool(missing)
print("untagged taggable resources:", bad)
sys.exit(1 if bad else 0)
