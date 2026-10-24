#!/usr/bin/env python3
"""Print the free OpenCode models that are live right now, best first, one per line.

A model qualifies when OpenCode's live endpoint lists it, models.dev prices it at
zero, and it supports tool calls. With --private, a model also needs an entry in
the "Free models" section of the OpenCode docs saying its provider does not use
your data for training. Undocumented models are skipped, so a docs change makes
the private list shorter, never leakier.

Ordering comes from .github/opencode/models.json: the "prefer" list first, then
the remaining models from newest to oldest. Models in "exclude" never qualify.
"""

import argparse
import html
import json
import re
import sys
import urllib.request
from pathlib import Path

LIVE_URL = "https://opencode.ai/inference/v1/models"
CATALOG_URL = "https://models.dev/api.json"
DOCS_URL = "https://opencode.ai/docs/zen/"
NO_TRAINING = "does not use your data for model training"
CONFIG = Path(__file__).resolve().parents[2] / "opencode" / "models.json"


def fetch(url: str) -> str:
    request = urllib.request.Request(url, headers={"User-Agent": "repo-template-model-picker"})
    with urllib.request.urlopen(request, timeout=90) as response:
        return response.read().decode("utf-8")


def free_models() -> dict[str, dict]:
    live = {model["id"] for model in json.loads(fetch(LIVE_URL))["data"]}
    catalog = json.loads(fetch(CATALOG_URL))["opencode"]["models"]
    return {
        model_id: info
        for model_id, info in catalog.items()
        if model_id in live
        and info.get("tool_call")
        and info.get("cost", {}).get("input") == 0
        and info.get("cost", {}).get("output") == 0
    }


def no_training_names() -> set[str]:
    page = fetch(DOCS_URL)
    section = re.search(r'id="free-models".*?</h[23]>(.*?)<h2', page, re.S)
    if not section:
        return set()
    names = set()
    for item in re.findall(r"<li>(.*?)</li>", section.group(1), re.S):
        text = re.sub(r"\s+", " ", re.sub(r"<[^>]+>", "", html.unescape(item)))
        if NO_TRAINING in text:
            names.add(re.split(r" is (?:a |free|available)", text, maxsplit=1)[0].strip())
    return names


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--private", action="store_true", help="only models whose provider does not train on your data")
    args = parser.parse_args()

    config = json.loads(CONFIG.read_text())
    candidates = {k: v for k, v in free_models().items() if k not in config.get("exclude", [])}

    if args.private:
        allowed = no_training_names()
        candidates = {k: v for k, v in candidates.items() if v.get("name") in allowed}

    prefer = [m for m in config.get("prefer", []) if m in candidates]
    rest = sorted(
        (m for m in candidates if m not in prefer),
        key=lambda m: candidates[m].get("release_date", ""),
        reverse=True,
    )
    for model_id in prefer + rest:
        print(f"opencode/{model_id}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
