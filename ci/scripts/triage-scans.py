#!/usr/bin/env python3
"""
triage-scans.py — AI triage of security scan findings.

Consumed by: .github/workflows/sign-and-publish.yaml (ppd gate)

What it does
------------
1. Parses SARIF reports produced by Trivy (image CVEs) and Checkov (IaC).
2. Normalizes findings into a compact, deduplicated list.
3. Asks Claude to triage them: what is actually exploitable in THIS context
   (a CPU inference service on EKS), what is noise, and what to fix first.
4. Writes a Markdown summary that the workflow posts as a PR comment.

Design notes
------------
- Fails safe. If the API key is missing or the API errors, it still writes a
  deterministic, non-AI summary so the PR comment is never empty and the
  pipeline is never blocked by a triage outage.
- Never prints secrets. The API key is read from the environment only.
- The raw scan data is the source of truth; the AI layer only adds prioritized
  human-readable context on top of it.
"""

from __future__ import annotations

import argparse
import json
import os
import sys
from pathlib import Path
from typing import Any


# Claude model + limits.
# Pinned intentionally for reproducible triage output — bump this DELIBERATELY
# (and review the change) rather than tracking "latest", so a model swap can
# never silently change what the security gate reports.
CLAUDE_MODEL = "claude-sonnet-5"
MAX_FINDINGS_TO_SEND = 60  # keep the prompt bounded/cheap
MAX_TOKENS = 1500


def _load_sarif(path: str | None) -> dict[str, Any] | None:
    """Load a SARIF file if it exists and is valid JSON; else return None."""
    if not path:
        return None
    p = Path(path)
    if not p.is_file():
        print(f"[triage] SARIF not found, skipping: {path}", file=sys.stderr)
        return None
    try:
        return json.loads(p.read_text(encoding="utf-8"))
    except (json.JSONDecodeError, OSError) as exc:
        print(f"[triage] Could not parse SARIF {path}: {exc}", file=sys.stderr)
        return None


def _extract_findings(sarif: dict[str, Any] | None, tool: str) -> list[dict[str, str]]:
    """Flatten a SARIF document into simple finding dicts."""
    findings: list[dict[str, str]] = []
    if not sarif:
        return findings

    for run in sarif.get("runs", []):
        # Build a rule-id -> severity lookup from the tool driver metadata.
        rule_severity: dict[str, str] = {}
        driver = run.get("tool", {}).get("driver", {})
        for rule in driver.get("rules", []):
            rid = rule.get("id", "")
            sev = (
                rule.get("properties", {}).get("security-severity")
                or rule.get("defaultConfiguration", {}).get("level")
                or "unknown"
            )
            rule_severity[rid] = str(sev)

        for result in run.get("results", []):
            rule_id = result.get("ruleId", "unknown")
            message = result.get("message", {}).get("text", "").strip()
            level = result.get("level") or rule_severity.get(rule_id, "unknown")

            location = ""
            locs = result.get("locations", [])
            if locs:
                phys = locs[0].get("physicalLocation", {})
                location = phys.get("artifactLocation", {}).get("uri", "")

            findings.append(
                {
                    "tool": tool,
                    "id": rule_id,
                    "severity": str(level),
                    "message": message[:300],
                    "location": location,
                }
            )
    return findings


def _dedup(findings: list[dict[str, str]]) -> list[dict[str, str]]:
    """Deduplicate by (tool, id, location)."""
    seen: set[tuple[str, str, str]] = set()
    out: list[dict[str, str]] = []
    for f in findings:
        key = (f["tool"], f["id"], f["location"])
        if key not in seen:
            seen.add(key)
            out.append(f)
    return out


def _deterministic_summary(findings: list[dict[str, str]]) -> str:
    """Non-AI fallback summary. Always works, never blocks the pipeline."""
    total = len(findings)
    by_tool: dict[str, int] = {}
    for f in findings:
        by_tool[f["tool"]] = by_tool.get(f["tool"], 0) + 1

    lines = [
        "## Security scan triage (automated)",
        "",
        f"**Total findings:** {total}",
        "",
    ]
    for tool, count in sorted(by_tool.items()):
        lines.append(f"- **{tool}:** {count}")
    lines.append("")

    if total:
        lines.append("### Findings")
        lines.append("")
        lines.append("| Tool | ID | Severity | Location |")
        lines.append("|------|----|----------|----------|")
        for f in findings[:MAX_FINDINGS_TO_SEND]:
            loc = f["location"] or "-"
            lines.append(
                f"| {f['tool']} | `{f['id']}` | {f['severity']} | {loc} |"
            )
        if total > MAX_FINDINGS_TO_SEND:
            lines.append("")
            lines.append(f"_...and {total - MAX_FINDINGS_TO_SEND} more._")
    else:
        lines.append("No CRITICAL/HIGH findings reported. ✅")

    lines.append("")
    lines.append("_AI triage was not available for this run — showing raw findings._")
    return "\n".join(lines)


def _ai_summary(findings: list[dict[str, str]], api_key: str) -> str | None:
    """Ask Claude to prioritize findings. Returns None on any failure."""
    try:
        import anthropic
    except ImportError:
        print("[triage] anthropic package not installed", file=sys.stderr)
        return None

    payload = json.dumps(findings[:MAX_FINDINGS_TO_SEND], indent=2)
    prompt = (
        "You are a security engineer triaging scan findings for a self-hosted "
        "LLM inference service (vLLM, CPU, running on Amazon EKS behind an "
        "internal service). Given the JSON findings below, produce a concise "
        "Markdown report with these sections:\n"
        "1. **Verdict** — one line: safe to promote to ppd, or block.\n"
        "2. **Fix first** — the findings that are realistically exploitable in "
        "this context, with a one-line reason each.\n"
        "3. **Likely noise** — findings that are low real-world risk here "
        "(e.g. unreachable code paths, dev-only tools), with a one-line reason.\n"
        "4. **Notes** — anything the reviewer should know.\n"
        "Be specific and do not invent findings that are not in the data.\n\n"
        f"Findings JSON:\n{payload}\n"
    )

    try:
        client = anthropic.Anthropic(api_key=api_key)
        resp = client.messages.create(
            model=CLAUDE_MODEL,
            max_tokens=MAX_TOKENS,
            messages=[{"role": "user", "content": prompt}],
        )
        text = "".join(
            block.text for block in resp.content if getattr(block, "type", "") == "text"
        ).strip()
        if not text:
            return None
        header = "## Security scan triage (AI-assisted)\n\n"
        footer = (
            f"\n\n---\n_Triaged by {CLAUDE_MODEL}. "
            f"Based on {min(len(findings), MAX_FINDINGS_TO_SEND)} finding(s)._"
        )
        return header + text + footer
    except Exception as exc:  # noqa: BLE001 — never let triage crash the gate
        print(f"[triage] Claude API call failed: {exc}", file=sys.stderr)
        return None


def main() -> int:
    parser = argparse.ArgumentParser(description="AI triage of security scans")
    parser.add_argument("--trivy", help="Path to Trivy SARIF report")
    parser.add_argument("--checkov", help="Path to Checkov SARIF report")
    parser.add_argument(
        "--output", default="triage-summary.md", help="Markdown output path"
    )
    args = parser.parse_args()

    findings: list[dict[str, str]] = []
    findings += _extract_findings(_load_sarif(args.trivy), "Trivy")
    findings += _extract_findings(_load_sarif(args.checkov), "Checkov")
    findings = _dedup(findings)

    api_key = os.environ.get("ANTHROPIC_API_KEY", "").strip()
    summary: str | None = None
    if api_key:
        summary = _ai_summary(findings, api_key)
    else:
        print("[triage] ANTHROPIC_API_KEY not set — using deterministic summary",
              file=sys.stderr)

    if summary is None:
        summary = _deterministic_summary(findings)

    Path(args.output).write_text(summary, encoding="utf-8")
    print(f"[triage] Wrote summary to {args.output} ({len(findings)} findings)")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
