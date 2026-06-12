#!/usr/bin/env python3
"""Assemble the GitHub Pages build of the IRIS user manual.

The manual (docs/manual/manuel.html) references images via ../../assets/ and
sibling docs via ../*.md — paths that resolve only inside the repo tree. For a
flat Pages site served at the repo root this rewrites the image paths to
assets/ and the cross-doc links to absolute github.com/blob URLs (only the
manual is published, not the linked docs), writing the result as the site
index.

Replacements are exact-string, and a missing fragment is a hard error: if the
manual's structure drifts the build fails loudly rather than shipping broken
links or images.

Usage: build-pages.py <repo-slug> <src-html> <out-html>
"""
import sys
from pathlib import Path


def main(repo: str, src_path: str, out_path: str) -> int:
    base = f"https://github.com/{repo}/blob/main"
    html = Path(src_path).read_text(encoding="utf-8")
    replacements = {
        # Flatten ../../assets/foo.png (img src) to assets/foo.png at the root.
        '"../../assets/': '"assets/',
        # Cross-doc links → absolute blob URLs (targets live in the repo root or docs/).
        'href="../SPECS.md"': f'href="{base}/SPECS.md"',
        'href="../README.md"': f'href="{base}/README.md"',
        'href="../user-guide.md"': f'href="{base}/docs/user-guide.md"',
        'href="../security-audit-2026-05-25.md"': f'href="{base}/docs/security-audit-2026-05-25.md"',
        'href="../phase-9-notarization-prep.md"': f'href="{base}/docs/phase-9-notarization-prep.md"',
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
    if len(sys.argv) != 4:
        sys.exit("usage: build-pages.py <repo-slug> <src-html> <out-html>")
    raise SystemExit(main(sys.argv[1], sys.argv[2], sys.argv[3]))
