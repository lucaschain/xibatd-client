#!/usr/bin/env python3

import argparse
import json
import re
from pathlib import Path


REQUIRED_FILES = ("otclient.html", "otclient.js", "otclient.wasm", "otclient.data")
REVISION_MARKER = "__XIBAT_BROWSER_REVISION__"


def prepare_bundle(bundle: Path, revision: str) -> None:
    if not re.fullmatch(r"[0-9a-f]{40}", revision):
        raise ValueError("revision must be a lowercase 40-character Git SHA")

    for name in REQUIRED_FILES:
        path = bundle / name
        if not path.is_file() or path.stat().st_size == 0:
            raise ValueError(f"browser bundle is missing {name}")

    html_path = bundle / "otclient.html"
    html = html_path.read_text(encoding="utf-8")
    if html.count(REVISION_MARKER) != 1:
        raise ValueError("browser HTML must contain exactly one revision marker")

    html_path.write_text(html.replace(REVISION_MARKER, revision), encoding="utf-8")
    (bundle / "revision.json").write_text(
        json.dumps({"revision": revision}, separators=(",", ":")) + "\n",
        encoding="utf-8",
    )


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("bundle", type=Path)
    parser.add_argument("revision")
    args = parser.parse_args()
    prepare_bundle(args.bundle, args.revision)


if __name__ == "__main__":
    main()
