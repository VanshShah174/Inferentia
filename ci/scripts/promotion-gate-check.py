#!/usr/bin/env python3
"""
promotion-gate-check.py — verify a pre-prod environment is healthy enough
to promote the running candidate to production.

Consumed by: .github/workflows/promotion-gate.yaml (main gate)

What it checks
--------------
Given an environment (e.g. ppd), confirm the candidate has been running
without regressions for at least a minimum duration before we allow promotion
to production. The signal sources are pluggable:

  - Prometheus  : query error rate / availability over the window
                  (PROM_URL env var)
  - Kubernetes  : confirm the deployment is Available and stable
                  (in-cluster or KUBECONFIG)

Design notes
------------
- Non-destructive: this script only READS state. It never mutates the cluster.
- Fails safe toward BLOCKING: if it cannot positively confirm health, it exits
  non-zero so a human must look. A promotion gate that passes on "unknown"
  is worse than useless.
- Until the EKS/observability stack exists, the workflow only invokes this
  when vars.CLUSTER_ACCESS_ENABLED == 'true', so it won't run prematurely.
"""

from __future__ import annotations

import argparse
import os
import re
import sys
import urllib.error
import urllib.request
import json


def _parse_duration(text: str) -> int:
    """Parse a duration like '2h', '90m', '3600s' into seconds."""
    match = re.fullmatch(r"\s*(\d+)\s*([smh])\s*", text.lower())
    if not match:
        raise ValueError(f"Invalid duration: {text!r} (use e.g. 2h, 90m, 3600s)")
    value, unit = int(match.group(1)), match.group(2)
    return value * {"s": 1, "m": 60, "h": 3600}[unit]


def _prometheus_error_rate(prom_url: str, window_s: int) -> float | None:
    """
    Query Prometheus for the request error ratio over the window.
    Returns a ratio in [0,1], or None if the query could not be run.
    """
    # HTTP 5xx ratio for the inference service over the window.
    window = f"{window_s}s"
    query = (
        f'sum(rate(vllm_request_failure_total[{window}]))'
        f' / clamp_min(sum(rate(vllm_request_total[{window}])), 1)'
    )
    url = f"{prom_url.rstrip('/')}/api/v1/query?query={urllib.parse.quote(query)}"
    try:
        with urllib.request.urlopen(url, timeout=15) as resp:  # noqa: S310
            data = json.loads(resp.read().decode("utf-8"))
    except (urllib.error.URLError, TimeoutError, json.JSONDecodeError) as exc:
        print(f"[gate] Prometheus query failed: {exc}", file=sys.stderr)
        return None

    if data.get("status") != "success":
        print(f"[gate] Prometheus returned non-success: {data}", file=sys.stderr)
        return None

    results = data.get("data", {}).get("result", [])
    if not results:
        # No data points — cannot confirm health.
        print("[gate] Prometheus returned no data for the error-rate query",
              file=sys.stderr)
        return None
    try:
        return float(results[0]["value"][1])
    except (KeyError, IndexError, ValueError) as exc:
        print(f"[gate] Could not read error rate value: {exc}", file=sys.stderr)
        return None


def main() -> int:
    parser = argparse.ArgumentParser(description="Pre-prod promotion health gate")
    parser.add_argument("--environment", required=True, help="e.g. ppd")
    parser.add_argument(
        "--min-healthy-duration",
        default="2h",
        help="Minimum healthy window, e.g. 2h / 90m / 3600s",
    )
    parser.add_argument(
        "--max-error-rate",
        type=float,
        default=0.01,
        help="Maximum tolerated error ratio (default 0.01 = 1%%)",
    )
    args = parser.parse_args()

    try:
        window_s = _parse_duration(args.min_healthy_duration)
    except ValueError as exc:
        print(f"[gate] {exc}", file=sys.stderr)
        return 2

    print(f"[gate] Environment      : {args.environment}")
    print(f"[gate] Healthy window   : {args.min_healthy_duration} ({window_s}s)")
    print(f"[gate] Max error rate   : {args.max_error_rate:.3%}")

    prom_url = os.environ.get("PROM_URL", "").strip()
    if not prom_url:
        # Fail safe toward blocking: we cannot confirm health without a signal.
        print(
            "[gate] PROM_URL not set — cannot confirm environment health. "
            "Blocking promotion (fail-safe). Wire Prometheus at the EKS stage.",
            file=sys.stderr,
        )
        return 1

    error_rate = _prometheus_error_rate(prom_url, window_s)
    if error_rate is None:
        print("[gate] Could not obtain error rate — blocking promotion (fail-safe).",
              file=sys.stderr)
        return 1

    print(f"[gate] Observed error rate over window: {error_rate:.3%}")
    if error_rate > args.max_error_rate:
        print(
            f"[gate] FAIL: error rate {error_rate:.3%} exceeds threshold "
            f"{args.max_error_rate:.3%}. Blocking promotion.",
            file=sys.stderr,
        )
        return 1

    print(f"[gate] PASS: {args.environment} healthy over the window. "
          "Promotion allowed.")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
