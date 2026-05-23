#!/usr/bin/env python3
"""PreToolUse hook : refuse une ecriture Swift touchant une API Apple
si aucun appel mcp__sosumi__* n'apparait dans le transcript de session."""
import json
import re
import sys
from pathlib import Path

APPLE_RE = re.compile(
    r"\b(?:Sec[A-Z]\w+|SMAppService|kSec[A-Z]\w+)\b"
    r"|import\s+(?:Security|ServiceManagement)"
)


def written_text(tool_name: str, tool_input: dict) -> str:
    if tool_name == "Write":
        return tool_input.get("content", "") or ""
    if tool_name == "Edit":
        return tool_input.get("new_string", "") or ""
    if tool_name == "MultiEdit":
        return "\n".join(
            (e.get("new_string") or "") for e in tool_input.get("edits", [])
        )
    return ""


def main() -> int:
    payload = json.load(sys.stdin)
    tool = payload.get("tool_name", "")
    if tool not in ("Edit", "Write", "MultiEdit"):
        return 0

    tool_input = payload.get("tool_input", {})
    file_path = tool_input.get("file_path", "")
    if not file_path.endswith(".swift"):
        return 0

    matches = APPLE_RE.findall(written_text(tool, tool_input))
    if not matches:
        return 0

    transcript = payload.get("transcript_path", "")
    if transcript and Path(transcript).exists():
        if "mcp__sosumi__" in Path(transcript).read_text(errors="ignore"):
            return 0

    symbols = ", ".join(sorted(set(matches))[:5])
    print(
        f"BLOCKED — fichier Swift introduit des symboles Apple ({symbols}) "
        "sans consultation prealable de la doc Apple via sosumi dans cette "
        "session. Appelle mcp__sosumi__searchAppleDocumentation ou "
        "mcp__sosumi__fetchAppleDocumentation avant cet Edit (CLAUDE.md §4).",
        file=sys.stderr,
    )
    return 2


if __name__ == "__main__":
    sys.exit(main())
