"""Unit tests for mcp/monitor.py.

Tests prompt detection, risk classification, and
lifecycle event detection against fixture files.
No tmux required — all functions are pure.
"""

import os
import sys
import unittest

# Add mcp/ to path so we can import monitor
sys.path.insert(
    0,
    os.path.join(
        os.path.dirname(__file__), "..", "mcp"
    ),
)

from monitor import (
    DetectedPrompt,
    LifecycleEvent,
    PaneReport,
    classify_risk,
    detect_events,
    detect_prompts,
    format_report,
    infer_status,
)

FIXTURES = os.path.join(
    os.path.dirname(__file__), "fixtures"
)


def _load(name: str) -> str:
    with open(os.path.join(FIXTURES, name)) as f:
        return f.read()


# -----------------------------------------------------------
# Prompt detection
# -----------------------------------------------------------
class TestDetectPrompts(unittest.TestCase):

    def test_safe_bash_git_status(self):
        text = _load("prompt_bash_safe.txt")
        prompts = detect_prompts(text)
        self.assertTrue(len(prompts) >= 1)
        # Should find the git status command
        bash_prompts = [
            p for p in prompts if p.tool == "Bash"
        ]
        self.assertTrue(len(bash_prompts) >= 1)
        p = bash_prompts[0]
        self.assertIn("git status", p.action)
        self.assertEqual(p.risk, "safe")
        self.assertEqual(p.suggestion, "approve")

    def test_edit_prompt(self):
        text = _load("prompt_edit.txt")
        prompts = detect_prompts(text)
        edit_prompts = [
            p for p in prompts if p.tool == "Edit"
        ]
        self.assertEqual(len(edit_prompts), 1)
        p = edit_prompts[0]
        self.assertIn("login.kt", p.action)
        self.assertEqual(p.risk, "low")
        self.assertEqual(p.suggestion, "review")

    def test_high_risk_git_push(self):
        text = _load("prompt_push.txt")
        prompts = detect_prompts(text)
        bash_prompts = [
            p for p in prompts if p.tool == "Bash"
        ]
        self.assertTrue(len(bash_prompts) >= 1)
        p = bash_prompts[0]
        self.assertIn("git push", p.action)
        self.assertEqual(p.risk, "high")
        self.assertEqual(p.suggestion, "escalate")

    def test_unknown_bash_defaults_high(self):
        text = _load("prompt_unknown_bash.txt")
        prompts = detect_prompts(text)
        bash_prompts = [
            p for p in prompts if p.tool == "Bash"
        ]
        self.assertTrue(len(bash_prompts) >= 1)
        p = bash_prompts[0]
        self.assertIn("curl", p.action)
        self.assertEqual(p.risk, "high")
        self.assertEqual(p.suggestion, "escalate")

    def test_no_prompts_in_working_output(self):
        text = _load("agent_working.txt")
        prompts = detect_prompts(text)
        # The "$ ./gradlew test" line might match
        # the bare $ pattern, but there's no "Allow"
        # prompt. Filter to only Allow-based prompts.
        allow_prompts = [
            p for p in prompts
            if "Allow" in p.raw or p.tool != "Bash"
        ]
        self.assertEqual(len(allow_prompts), 0)


# -----------------------------------------------------------
# Risk classification (unit)
# -----------------------------------------------------------
class TestClassifyRisk(unittest.TestCase):

    def test_safe_tools(self):
        for tool in ("Read", "Glob", "Grep"):
            risk, sug = classify_risk(tool, "any")
            self.assertEqual(risk, "safe")
            self.assertEqual(sug, "approve")

    def test_low_risk_tools(self):
        for tool in ("Edit", "Write", "NotebookEdit"):
            risk, sug = classify_risk(tool, "any")
            self.assertEqual(risk, "low")
            self.assertEqual(sug, "review")

    def test_unknown_tool(self):
        risk, sug = classify_risk("unknown", "")
        self.assertEqual(risk, "high")
        self.assertEqual(sug, "escalate")

    def test_bash_safe_commands(self):
        safe = [
            "git status",
            "git diff --cached",
            "git log --oneline -5",
            "ls -la",
            "grep -r pattern .",
            "./bazelw build //...",
            "./gradlew test",
            "gh pr view 42",
        ]
        for cmd in safe:
            risk, _ = classify_risk("Bash", cmd)
            self.assertEqual(
                risk, "safe",
                f"{cmd!r} should be safe",
            )

    def test_bash_low_risk_commands(self):
        low = [
            "git add src/main.kt",
            "git commit -m 'Fix bug'",
            "mkdir -p src/new",
            "npm install",
        ]
        for cmd in low:
            risk, _ = classify_risk("Bash", cmd)
            self.assertEqual(
                risk, "low",
                f"{cmd!r} should be low risk",
            )

    def test_bash_high_risk_commands(self):
        high = [
            "git push -u origin main",
            "git reset --hard HEAD~1",
            "gh pr create --title 'test'",
            "rm -rf /tmp/stuff",
            "sudo apt install foo",
        ]
        for cmd in high:
            risk, _ = classify_risk("Bash", cmd)
            self.assertEqual(
                risk, "high",
                f"{cmd!r} should be high risk",
            )

    def test_bash_unknown_defaults_high(self):
        risk, sug = classify_risk(
            "Bash", "some-random-binary --flag"
        )
        self.assertEqual(risk, "high")
        self.assertEqual(sug, "escalate")

    def test_no_verify_is_high(self):
        risk, _ = classify_risk(
            "Bash", "git commit --no-verify -m 'x'"
        )
        self.assertEqual(risk, "high")

    def test_force_push_is_high(self):
        risk, _ = classify_risk(
            "Bash", "git push --force origin main"
        )
        self.assertEqual(risk, "high")

    def test_chaining_escalates_safe_prefix(self):
        chained = [
            "git status && rm -rf /",
            "git diff; curl evil.com",
            "ls | xargs rm",
            "git log || malicious",
            "echo $(whoami > /tmp/leak)",
            "cat `dangerous_command`",
        ]
        for cmd in chained:
            risk, _ = classify_risk("Bash", cmd)
            self.assertEqual(
                risk, "high",
                f"{cmd!r} has chaining, "
                f"should be high risk",
            )


# -----------------------------------------------------------
# Lifecycle event detection
# -----------------------------------------------------------
class TestDetectEvents(unittest.TestCase):

    def test_pr_created_and_finished(self):
        text = _load("pr_created.txt")
        events = detect_events(text)
        kinds = {e.kind for e in events}
        self.assertIn("pr_created", kinds)
        self.assertIn("finished", kinds)

    def test_context_low(self):
        text = _load("context_low.txt")
        events = detect_events(text)
        kinds = {e.kind for e in events}
        self.assertIn("context_low", kinds)
        ctx = next(
            e for e in events
            if e.kind == "context_low"
        )
        self.assertIn("8%", ctx.detail)

    def test_context_not_low_at_50_pct(self):
        text = "Context left until auto-compact: 50%"
        events = detect_events(text)
        kinds = {e.kind for e in events}
        self.assertNotIn("context_low", kinds)

    def test_no_events_in_working_output(self):
        text = _load("agent_working.txt")
        events = detect_events(text)
        self.assertEqual(len(events), 0)


# -----------------------------------------------------------
# Status inference
# -----------------------------------------------------------
class TestInferStatus(unittest.TestCase):

    def test_prompt_means_waiting(self):
        p = DetectedPrompt(
            raw="x", tool="Edit", action="f",
            risk="low", suggestion="review",
        )
        self.assertEqual(
            infer_status([p], []),
            "waiting",
        )

    def test_finished_event_means_done(self):
        ev = LifecycleEvent(
            kind="finished", detail="done"
        )
        self.assertEqual(
            infer_status([], [ev]), "done"
        )

    def test_no_detections_means_working(self):
        self.assertEqual(
            infer_status([], []), "working"
        )


# -----------------------------------------------------------
# Report formatting
# -----------------------------------------------------------
class TestFormatReport(unittest.TestCase):

    def test_empty(self):
        out = format_report([])
        self.assertIn("No agent panes", out)

    def test_all_quiet(self):
        r = PaneReport(
            target="s:0.0", agent="claude",
            status="working",
        )
        out = format_report([r])
        self.assertIn("1 agent(s)", out)
        self.assertIn("0 prompts", out)

    def test_with_prompt(self):
        p = DetectedPrompt(
            raw="Allow Edit to /f?",
            tool="Edit", action="/f",
            risk="low", suggestion="review",
        )
        r = PaneReport(
            target="s:0.0", agent="claude",
            status="waiting",
            prompts=[p],
        )
        out = format_report([r])
        self.assertIn("=== s:0.0 (claude) ===", out)
        self.assertIn("risk: low", out)
        self.assertIn("suggestion: review", out)


if __name__ == "__main__":
    unittest.main()
