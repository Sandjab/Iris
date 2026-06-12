#!/usr/bin/env python3
"""Assemble the GitHub Pages build of the IRIS user manual.

The manual (docs/manual/manuel.html) references its images via ../../assets/ —
a path that resolves only inside the repo tree. For a flat Pages site served at
the repo root this flattens the image paths to assets/, writing the result as
the site index.

The replacement is exact-string, and a missing fragment is a hard error: if the
manual's structure drifts the build fails loudly rather than shipping a page
with broken images.

Usage: build-pages.py <src-html> <out-html>
"""
import sys
from pathlib import Path


def main(src_path: str, out_path: str) -> int:
    html = Path(src_path).read_text(encoding="utf-8")
    replacements = {
        # Flatten ../../assets/foo.png (img src) to assets/foo.png at the root.
        '"../../assets/': '"assets/',
    }
    for old, new in replacements.items():
        if old not in html:
            sys.exit(f"build-pages: expected fragment missing, manual structure changed: {old!r}")
        html = html.replace(old, new)
    out = Path(out_path)
    out.parent.mkdir(parents=True, exist_ok=True)
    out.write_text(html, encoding="utf-8")
    print(f"build-pages: wrote {out} ({len(html)} bytes)")
    return 0


if __name__ == "__main__":
    if len(sys.argv) != 3:
        sys.exit("usage: build-pages.py <src-html> <out-html>")
    raise SystemExit(main(sys.argv[1], sys.argv[2]))
