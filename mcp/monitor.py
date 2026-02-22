"""Prompt detection, risk classification, and lifecycle
event detection for tmux-pilot agent monitoring.

All functions are pure — they operate on captured pane
text strings. No tmux interaction happens here.
"""

from __future__ import annotations

import re
from dataclasses import dataclass, field


# -----------------------------------------------------------
# Prompt detection
# -----------------------------------------------------------

@dataclass
class DetectedPrompt:
    """A permission prompt found in pane output."""

    raw: str
    tool: str
    action: str
    risk: str  # "safe" | "low" | "high"
    suggestion: str  # "approve" | "review" | "escalate"


# Bash prompt: "Allow Bash" header followed by a
# "$ command" line (possibly with lines in between).
_BASH_PROMPT_RE = re.compile(
    r"Allow Bash[^\n]*\n(?:[^\n]*\n)*?"
    r"\s*\$\s+(.+)",
)

# Non-Bash tool prompts: "Allow <Tool> to <path>?"
_TOOL_PROMPT_RE = re.compile(
    r"Allow (Edit|Write|Read|Glob|Grep"
    r"|NotebookEdit|WebFetch|WebSearch)"
    r"(?:\s+to)?\s+(.+?)(?:\?|$)"
)

# Generic yes/no fallback
_GENERIC_PROMPT_RE = re.compile(
    r"Do you want to (?:allow|proceed|continue)"
)


def detect_prompts(text: str) -> list[DetectedPrompt]:
    """Scan pane text for permission prompts.

    Returns a list of detected prompts with risk
    classification.
    """
    prompts: list[DetectedPrompt] = []

    # 1. Bash prompts — extract the actual command
    for m in _BASH_PROMPT_RE.finditer(text):
        cmd = m.group(1).strip()
        risk, suggestion = classify_risk("Bash", cmd)
        prompts.append(DetectedPrompt(
            raw=m.group(0).strip(),
            tool="Bash",
            action=cmd,
            risk=risk,
            suggestion=suggestion,
        ))

    # 2. Non-Bash tool prompts
    for m in _TOOL_PROMPT_RE.finditer(text):
        tool = m.group(1)
        action = m.group(2).strip()
        risk, suggestion = classify_risk(tool, action)
        prompts.append(DetectedPrompt(
            raw=m.group(0).strip(),
            tool=tool,
            action=action,
            risk=risk,
            suggestion=suggestion,
        ))

    # 3. Generic fallback (only if nothing else found)
    if not prompts:
        for m in _GENERIC_PROMPT_RE.finditer(text):
            prompts.append(DetectedPrompt(
                raw=m.group(0).strip(),
                tool="unknown",
                action=m.group(0),
                risk="high",
                suggestion="escalate",
            ))

    return prompts


# -----------------------------------------------------------
# Risk classification
# -----------------------------------------------------------

_SAFE_TOOLS = frozenset(
    {"Read", "Glob", "Grep", "WebSearch", "WebFetch"}
)

_SAFE_BASH_PATTERNS = [
    re.compile(p)
    for p in [
        r"^git\s+(status|diff|log|branch|show)",
        r"^git\s+(fetch|rev-parse|rev-list|remote)",
        r"^(cat|head|tail|less|wc|file|ls)\b",
        r"^(find|fd)\b",
        r"^(grep|rg|ag|ack)\b",
        r"^(bazel|bazelw|\.\/bazelw)\s+"
        r"(build|test|query|info)",
        r"^(gradle|gradlew|\.\/gradlew)\s+"
        r"(build|test|check)\b",
        r"^(buildifier|ktfmt)\b",
        r"^(python3?|node)\s+.+\.(py|js|ts|bzl)$",
        r"^(npm|yarn|pnpm)\s+(run\s+)?"
        r"(build|test|lint)\b",
        r"^(cargo|go|make)\s+(build|test|check)\b",
        r"^gh\s+(issue|pr)\s+(view|list|diff)\b",
        r"^(pwd|whoami|date|uname|which|type"
        r"|printenv|env)\b",
    ]
]

_LOW_RISK_TOOLS = frozenset(
    {"Edit", "Write", "NotebookEdit"}
)

_LOW_RISK_BASH_PATTERNS = [
    re.compile(p)
    for p in [
        r"^git\s+(add|commit|stash|checkout"
        r"|switch|branch)\b",
        r"^git\s+worktree\s+(add|remove)\b",
        r"^(bazel|bazelw|\.\/bazelw)\s+run\b",
        r"^(gradle|gradlew|\.\/gradlew)\b",
        r"^(mkdir|cp|mv|touch|chmod)\b",
        r"^(npm|yarn|pnpm)\s+install\b",
        r"^(pip|uv)\s+install\b",
        r"^(cargo|go)\s+(install|get)\b",
    ]
]

_HIGH_RISK_BASH_PATTERNS = [
    re.compile(p)
    for p in [
        r"^git\s+push\b",
        r"^git\s+(reset|rebase|merge|cherry-pick)\b",
        r"git\s+.*--force",
        r"git\s+.*--no-verify",
        r"^gh\s+pr\s+(create|merge|close|edit)\b",
        r"^gh\s+issue\s+(close|delete|edit)\b",
        r"^(rm|rmdir|unlink)\b",
        r"^(sudo|doas)\b",
        r"^(curl|wget)\s+.+"
        r"(POST|PUT|DELETE|PATCH)",
        r"^docker\s+(rm|rmi|system\s+prune)\b",
    ]
]


def classify_risk(
    tool: str, action: str
) -> tuple[str, str]:
    """Classify a prompt by risk level.

    Returns:
        (risk_level, suggestion) where risk_level is
        one of "safe", "low", "high" and suggestion is
        one of "approve", "review", "escalate".
    """
    if tool in _SAFE_TOOLS:
        return ("safe", "approve")

    if tool in _LOW_RISK_TOOLS:
        return ("low", "review")

    if tool == "Bash":
        return _classify_bash(action)

    if tool == "unknown":
        return ("high", "escalate")

    # Unknown tool — conservative
    return ("high", "escalate")


# Shell chaining/substitution operators that turn a
# single "safe" command into a multi-command pipeline.
# If any of these appear, the command is high-risk
# regardless of the leading token.
_CHAINING_RE = re.compile(
    r"&&|\|\||[;|]|\$\(|`"
)


def _classify_bash(command: str) -> tuple[str, str]:
    """Classify a Bash command by risk."""
    cmd = command.strip()

    # Check high-risk patterns first
    for pat in _HIGH_RISK_BASH_PATTERNS:
        if pat.search(cmd):
            return ("high", "escalate")

    # Chaining/substitution → always high risk.
    # A "safe" prefix like "git status" becomes
    # dangerous with: git status && rm -rf /
    if _CHAINING_RE.search(cmd):
        return ("high", "escalate")

    for pat in _SAFE_BASH_PATTERNS:
        if pat.search(cmd):
            return ("safe", "approve")

    for pat in _LOW_RISK_BASH_PATTERNS:
        if pat.search(cmd):
            return ("low", "review")

    # Unknown bash command → high risk
    return ("high", "escalate")


# -----------------------------------------------------------
# Lifecycle event detection
# -----------------------------------------------------------

@dataclass
class LifecycleEvent:
    """A lifecycle event detected in pane output."""

    kind: str  # See _EVENT_PATTERNS keys
    detail: str


_EVENT_PATTERNS: list[
    tuple[str, re.Pattern[str]]
] = [
    (
        "pr_created",
        re.compile(
            r"https?://github\.com/[^\s]+/pull/\d+"
        ),
    ),
    (
        "finished",
        re.compile(r"═+\s*Work Complete\s*═+"),
    ),
    (
        "context_low",
        re.compile(
            r"Context left until auto-compact:\s*"
            r"(\d+)%"
        ),
    ),
    (
        "context_exhausted",
        re.compile(r"auto-compact", re.IGNORECASE),
    ),
]


def detect_events(text: str) -> list[LifecycleEvent]:
    """Scan pane text for lifecycle events."""
    events: list[LifecycleEvent] = []
    seen: set[str] = set()

    for kind, pattern in _EVENT_PATTERNS:
        m = pattern.search(text)
        if m and kind not in seen:
            seen.add(kind)
            detail = m.group(0)
            # For context_low, only fire if < 15%
            if kind == "context_low":
                try:
                    pct = int(m.group(1))
                    if pct >= 15:
                        continue
                    detail = f"{pct}% remaining"
                except (IndexError, ValueError):
                    continue
            events.append(
                LifecycleEvent(kind=kind, detail=detail)
            )

    return events


# -----------------------------------------------------------
# Pane status inference
# -----------------------------------------------------------

def infer_status(
    prompts: list[DetectedPrompt],
    events: list[LifecycleEvent],
) -> str:
    """Infer overall pane status from detections.

    Returns one of the @pilot-status enum values:
    working, watching, waiting, paused, done.
    """
    if prompts:
        return "waiting"
    for ev in events:
        if ev.kind == "finished":
            return "done"
    return "working"


# -----------------------------------------------------------
# Report formatting
# -----------------------------------------------------------

@dataclass
class PaneReport:
    """Monitoring report for a single pane."""

    target: str
    agent: str
    status: str
    prompts: list[DetectedPrompt] = field(
        default_factory=list
    )
    events: list[LifecycleEvent] = field(
        default_factory=list
    )


def format_report(
    reports: list[PaneReport],
) -> str:
    """Format pane reports into a human-readable string.

    Returns a compact summary when there's nothing
    actionable, or detailed blocks per pane otherwise.
    """
    if not reports:
        return "No agent panes found."

    actionable = [
        r for r in reports
        if r.prompts or r.events
    ]

    if not actionable:
        working = sum(
            1 for r in reports
            if r.status == "working"
        )
        done = sum(
            1 for r in reports
            if r.status == "done"
        )
        parts = []
        if working:
            parts.append(f"{working} working")
        if done:
            parts.append(f"{done} done")
        return (
            f"{len(reports)} agent(s): "
            + ", ".join(parts or ["all idle"])
            + ". 0 prompts, 0 events."
        )

    lines: list[str] = []
    for r in reports:
        lines.append(
            f"=== {r.target} ({r.agent or '?'}) ==="
        )
        lines.append(f"status: {r.status}")

        for ev in r.events:
            lines.append(
                f"event: {ev.kind} — {ev.detail}"
            )

        for p in r.prompts:
            lines.append("prompt:")
            lines.append(f"  raw: {p.raw!r}")
            lines.append(f"  tool: {p.tool}")
            lines.append(f"  action: {p.action}")
            lines.append(f"  risk: {p.risk}")
            lines.append(
                f"  suggestion: {p.suggestion}"
            )

        lines.append("")

    # Append summary of non-actionable panes
    quiet = len(reports) - len(actionable)
    if quiet:
        lines.append(
            f"({quiet} other agent(s) working "
            f"quietly)"
        )

    return "\n".join(lines)
