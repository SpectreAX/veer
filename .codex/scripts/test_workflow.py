"""Check patch path confinement and the shared Hook handoff without touching app files."""
import importlib.util
import json
from pathlib import Path
import subprocess
import tempfile
import unittest
from unittest.mock import patch

spec = importlib.util.spec_from_file_location("workflow", Path(__file__).with_name("workflow.py"))
workflow = importlib.util.module_from_spec(spec)
spec.loader.exec_module(workflow)


class WorkflowTests(unittest.TestCase):
    def test_patch_only_selects_existing_swift_sources_inside_macos(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory).resolve()
            source = root / "macos/Sources/VeerApp/A file.swift"
            source.parent.mkdir(parents=True)
            source.write_text("// sample\n")
            outside = root / "Outside.swift"
            outside.write_text("// leave alone\n")
            (source.parent / "Outside.swift").symlink_to(outside)
            event = {"cwd": str(root), "tool_input": {"command": "\n".join([
                "*** Update File: macos/Sources/VeerApp/A file.swift",
                "*** Update File: Outside.swift",
                "*** Update File: macos/Sources/VeerApp/Outside.swift",
                "*** Add File: macos/Sources/VeerApp/missing.swift",
                "*** Delete File: macos/Sources/VeerApp/A file.swift",
            ])}}
            with patch.object(workflow, "MACOS", root / "macos"):
                self.assertEqual(workflow.edited_files(event), [source])
                event = {"cwd": str(source.parent), "tool_input": {"file_path": source.name}}
                self.assertEqual(workflow.edited_files(event), [source])

    def test_stop_forwards_blocking_feedback_and_retry_state(self):
        event = {"stop_hook_active": True, "cwd": "/example"}
        with patch("sys.argv", ["workflow.py", "stop"]), \
             patch("sys.stdin") as stdin, patch.object(workflow.subprocess, "run") as run:
            stdin.read.return_value = json.dumps(event)
            run.return_value = subprocess.CompletedProcess([], 2)
            self.assertEqual(workflow.main(), 2)
            self.assertEqual(json.loads(run.call_args.kwargs["input"]), event)
            self.assertEqual(run.call_args.kwargs["cwd"], workflow.MACOS)
            self.assertEqual(run.call_args.args[0][-1], str(workflow.MACOS / ".claude/scripts/stop-check.sh"))

    def test_post_translates_every_file_and_propagates_failure(self):
        files = [Path("/sample/First.swift"), Path("/sample/Second.swift")]
        with patch("sys.argv", ["workflow.py", "post"]), \
             patch("sys.stdin") as stdin, patch.object(workflow, "edited_files", return_value=files), \
             patch.object(workflow.subprocess, "run") as run:
            stdin.read.return_value = "{}"
            run.side_effect = [subprocess.CompletedProcess([], 0), subprocess.CompletedProcess([], 2)]
            self.assertEqual(workflow.main(), 2)
            sent = [json.loads(call.kwargs["input"])["tool_input"]["file_path"] for call in run.call_args_list]
            self.assertEqual(sent, list(map(str, files)))


if __name__ == "__main__":
    unittest.main()
