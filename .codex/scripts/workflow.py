#!/usr/bin/env python3
"""Adapt Codex events to Veer's existing Claude rules and checks. No app or network toggles."""
import json
from pathlib import Path
import re
import subprocess
import sys

ROOT = Path(__file__).resolve().parents[2]
MACOS = ROOT / "macos"


def edited_files(event):
    """Codex patches carry paths in command; Claude Edit/Write carries file_path."""
    tool_input = event.get("tool_input", {})
    if isinstance(tool_input, str):
        tool_input = {"command": tool_input}
    names = [tool_input["file_path"]] if tool_input.get("file_path") else []
    names += re.findall(r"^\*\*\* (?:Add File|Update File|Move to): (.+)$",
                        tool_input.get("command", tool_input.get("patch", "")), re.MULTILINE)
    cwd = Path(event.get("cwd") or ROOT)
    result = set()
    for name in names:
        path = (cwd / name).resolve()
        if path.suffix == ".swift" and path.is_file() and any(
            parent in path.parents for parent in (MACOS / "Sources", MACOS / "Tests")
        ):
            result.add(path)
    return sorted(result)


def session_context():
    paths = [ROOT / "AGENTS.md", MACOS / "CLAUDE.md"]
    paths += sorted((MACOS / ".claude/rules").glob("*.md"))
    paths += [ROOT / ".codex/HANDOFF.md"]
    return "\n\n".join(f"# {path.relative_to(ROOT)}\n{path.read_text()}" for path in paths)


def main():
    mode = sys.argv[1]
    event = json.load(sys.stdin)
    if mode == "session":
        print(json.dumps({"hookSpecificOutput": {
            "hookEventName": "SessionStart", "additionalContext": session_context(),
        }}))
        return 0
    if mode == "stop":
        return subprocess.run(
            ["bash", str(MACOS / ".claude/scripts/stop-check.sh")],
            input=json.dumps(event), text=True, cwd=MACOS,
        ).returncode
    if mode == "post":
        status = 0
        for path in edited_files(event):
            result = subprocess.run(
                ["bash", str(MACOS / ".claude/scripts/post-edit.sh")],
                input=json.dumps({"tool_input": {"file_path": str(path)}}), text=True, cwd=MACOS,
            )
            if result.returncode:
                status = 2
        return status
    raise ValueError(f"Unknown workflow mode: {mode}")


if __name__ == "__main__":
    sys.exit(main())
