import importlib.util
from pathlib import Path
import subprocess
import unittest
from unittest.mock import patch

spec = importlib.util.spec_from_file_location("publisher", Path(__file__).parents[1] / "publish-context.py")
publisher = importlib.util.module_from_spec(spec)
spec.loader.exec_module(publisher)


class ContextTests(unittest.TestCase):
    def test_only_allowlisted_metadata_is_published(self):
        terminal = {"cwd": "/tmp/repo", "created_ms": 42, "status": {"app": "codex"},
                    "foreground": {"cwd": "/tmp/worktree", "pid": 12},
                    "labels": {"where": "Demo / Codex", "private-token": "not-a-real-token"}}
        with patch.object(publisher, "branch_for", return_value="feature/ui"), patch.object(publisher, "account_for", return_value="Work"):
            labels = publisher.context_for(terminal)
        self.assertEqual(labels["context.directory"], "/tmp/worktree")
        self.assertEqual(labels["context.branch"], "feature/ui")
        self.assertEqual(labels["context.project"], "Demo")
        self.assertEqual(labels["context.created_ms"], "42")
        self.assertNotIn("not-a-real-token", str(labels))

    def test_branch_paths_are_arguments_not_shell_commands(self):
        directory = "/tmp/repo $(do-not-run)"
        with patch.object(publisher, "run", return_value=subprocess.CompletedProcess([], 0, "main\n")) as run:
            self.assertEqual(publisher.branch_for(directory), "main")
        self.assertEqual(run.call_args.args[0], ["git", "-C", directory, "symbolic-ref", "--quiet", "--short", "HEAD"])

    def test_non_git_directory_has_no_branch(self):
        with patch.object(publisher, "run", return_value=subprocess.CompletedProcess([], 128, "")):
            self.assertEqual(publisher.branch_for("/tmp"), "")

    def test_profile_displays_only_an_alias(self):
        self.assertEqual(publisher.profile_name("/home/user/.claude-work"), "work")
        self.assertEqual(publisher.profile_name("/home/user/.codex"), "Personal")

    def test_account_uses_only_the_matching_provider_profile(self):
        environment = "claude CODEX_HOME=/home/user/.codex-other CLAUDE_CONFIG_DIR=/home/user/.claude-work"
        with patch.object(Path, "is_file", return_value=False), patch.object(publisher, "run", return_value=subprocess.CompletedProcess([], 0, environment)):
            self.assertEqual(publisher.account_for(12, "claude"), "work")
            self.assertEqual(publisher.account_for(12, "codex"), "other")
            self.assertEqual(publisher.account_for(12, "grok"), "")

    def test_remote_address_is_not_accidentally_read_locally(self):
        with self.assertRaises(ValueError):
            publisher.publish("server/t7")


if __name__ == "__main__":
    unittest.main()
