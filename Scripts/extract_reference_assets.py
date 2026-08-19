#!/usr/bin/env python3
"""Extract the four approved visual assets from the final reference preview."""

from __future__ import annotations

import base64
import re
import sys
from pathlib import Path


def main() -> int:
    if len(sys.argv) != 3:
        print("usage: extract_reference_assets.py REFERENCE_HTML OUTPUT_DIR", file=sys.stderr)
        return 2

    reference = Path(sys.argv[1])
    output = Path(sys.argv[2])
    encoded = re.findall(
        r"data:image/png;base64,([A-Za-z0-9+/=]+)",
        reference.read_text(encoding="utf-8"),
    )
    names = ("blocked.png", "running.png", "ready.png", "needs.png")
    if len(encoded) != len(names):
        print(f"expected {len(names)} PNG assets, found {len(encoded)}", file=sys.stderr)
        return 1

    output.mkdir(parents=True, exist_ok=True)
    for name, payload in zip(names, encoded, strict=True):
        (output / name).write_bytes(base64.b64decode(payload))
        print(output / name)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
