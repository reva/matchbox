#!/usr/bin/env python3
"""Turn a JMeter .jtl into a run summary and append a row to history.csv.

Reports HTTP latency and, separately, the server side validation time matchbox
reports in the OperationOutcome. Against a remote instance those two differ by
network time, and only the second one tells you anything about the server.

Samples whose label starts with "prepare-" (readiness, probe, warmup) or
"metrics-" are excluded from the request statistics.

Usage:
  summarize.py <run.jtl> --out <run-dir> --history <history.csv> [--meta k=v ...]
"""
import argparse
import csv
import json
import math
import re
import sys
from pathlib import Path

REQUEST_PREFIXES_EXCLUDED = ("prepare-", "metrics-")


def percentile(values, p):
    """Nearest-rank percentile. Returns None for an empty series."""
    if not values:
        return None
    s = sorted(values)
    k = max(0, math.ceil(p / 100.0 * len(s)) - 1)
    return s[k]


def to_float(raw):
    try:
        v = float(raw)
    except (TypeError, ValueError):
        return None
    # The JMX writes -1 when an extractor found nothing.
    return None if v < 0 else v


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("jtl")
    ap.add_argument("--out", required=True)
    ap.add_argument("--history", required=True)
    ap.add_argument("--meta", action="append", default=[])
    args = ap.parse_args()

    meta = {}
    for item in args.meta:
        k, _, v = item.partition("=")
        meta[k] = v

    jtl = Path(args.jtl)
    if not jtl.exists():
        print(f"no jtl at {jtl}", file=sys.stderr)
        return 2

    elapsed, validation, memory = [], [], []
    total = failed = 0
    first_ts = last_ts = None
    codes = {}
    versions = set()
    sessions = set()
    readiness = None

    with jtl.open(newline="", encoding="utf-8", errors="replace") as fh:
        for row in csv.DictReader(fh):
            label = (row.get("label") or "").strip()
            if label == "prepare-readiness":
                readiness = row
                continue
            if label.startswith("metrics-"):
                mu = to_float(row.get("memoryused"))
                if mu is not None:
                    memory.append(mu)
                continue
            if label.startswith("prepare-"):
                continue

            total += 1
            ok = (row.get("success") or "").strip().lower() == "true"
            if not ok:
                failed += 1
            code = (row.get("responseCode") or "?").strip()
            codes[code] = codes.get(code, 0) + 1

            e = to_float(row.get("elapsed"))
            if e is not None:
                elapsed.append(e)
            v = to_float(row.get("validationms"))
            if v is not None:
                validation.append(v)

            ts = to_float(row.get("timeStamp"))
            if ts is not None:
                first_ts = ts if first_ts is None else min(first_ts, ts)
                last_ts = ts if last_ts is None else max(last_ts, ts)

            if row.get("matchbox") and row["matchbox"] != "---":
                # The server reports a full banner, e.g. "powered by matchbox
                # 4.1.13, hapi-fhir 8.10.1 and org.hl7.fhir.core 6.10.0". Keep
                # the matchbox version so history.csv stays readable.
                m = re.search(r"matchbox\s+([\w.\-]+)", row["matchbox"])
                versions.add(m.group(1) if m else row["matchbox"])
            if row.get("sessionid") and row["sessionid"] != "---":
                sessions.add(row["sessionid"])

    if total == 0:
        # Almost always the readiness check failed and stopped the test, so say
        # that rather than leaving the caller with an empty-results message.
        if readiness is not None and (readiness.get("success") or "").lower() != "true":
            print(
                "the target did not respond to GET /fhir/metadata, so the test stopped "
                "before sending any load:\n"
                f"  {readiness.get('responseCode', '?')} {readiness.get('responseMessage', '')}\n"
                f"  {readiness.get('failureMessage') or ''}".rstrip(),
                file=sys.stderr,
            )
        else:
            print("no $validate samples in the jtl", file=sys.stderr)
        return 2

    # Wall clock from first to last request start, plus the last request's own
    # duration, so a short run is not reported as infinitely fast.
    span = ((last_ts - first_ts) / 1000.0) if (first_ts and last_ts) else 0.0
    if span <= 0:
        span = (max(elapsed) / 1000.0) if elapsed else 1.0
    throughput = total / span

    summary = {
        "target": meta.get("target", ""),
        "scenario": meta.get("scenario", ""),
        "profile_key": meta.get("profile_key", ""),
        "requested_rate_per_s": meta.get("rate", ""),
        "duration_s": meta.get("duration", ""),
        "threads": meta.get("threads", ""),
        "java_opts": meta.get("java_opts", ""),
        "cpus": meta.get("cpus", ""),
        "ig_version": meta.get("ig_version", ""),
        "matchbox_version": ",".join(sorted(versions)) or "unknown",
        "sessions_seen": len(sessions),
        "samples": total,
        "failed": failed,
        "error_rate": round(failed / total, 5),
        "achieved_rps": round(throughput, 3),
        "http_ms": {
            "p50": percentile(elapsed, 50),
            "p95": percentile(elapsed, 95),
            "p99": percentile(elapsed, 99),
            "max": max(elapsed) if elapsed else None,
        },
        "validation_ms": {
            "p50": percentile(validation, 50),
            "p95": percentile(validation, 95),
            "p99": percentile(validation, 99),
            "max": max(validation) if validation else None,
            "samples": len(validation),
        },
        "heap_bytes_peak": max(memory) if memory else None,
        "response_codes": codes,
    }

    out = Path(args.out)
    out.mkdir(parents=True, exist_ok=True)
    (out / "summary.json").write_text(json.dumps(summary, indent=2) + "\n")

    def fmt(v):
        return "-" if v is None else f"{v:.0f}"

    print()
    print(f"  target            {summary['target']}  ({summary['scenario']})")
    print(f"  matchbox          {summary['matchbox_version']}")
    print(f"  samples           {total}  ({failed} failed, {summary['error_rate'] * 100:.2f}%)")
    print(f"  throughput        {summary['achieved_rps']:.2f} req/s"
          f"   (requested {summary['requested_rate_per_s'] or '-'}/s)")
    print(f"  http ms           p50 {fmt(summary['http_ms']['p50'])}"
          f"   p95 {fmt(summary['http_ms']['p95'])}"
          f"   p99 {fmt(summary['http_ms']['p99'])}")
    if summary["validation_ms"]["samples"]:
        print(f"  validation ms     p50 {fmt(summary['validation_ms']['p50'])}"
              f"   p95 {fmt(summary['validation_ms']['p95'])}"
              f"   p99 {fmt(summary['validation_ms']['p99'])}"
              f"    <- server side")
    else:
        print("  validation ms     not reported by the server")
    if summary["heap_bytes_peak"]:
        print(f"  heap peak         {summary['heap_bytes_peak'] / 1024 ** 3:.2f} GiB")
    if codes:
        print(f"  response codes    {', '.join(f'{k}={v}' for k, v in sorted(codes.items()))}")
    print()

    history = Path(args.history)
    cols = [
        "timestamp", "target", "scenario", "profile_key", "matchbox_version",
        "ig_version", "java_opts", "cpus", "threads", "requested_rate_per_s",
        "duration_s", "samples", "failed", "error_rate", "achieved_rps",
        "http_p50", "http_p95", "http_p99",
        "validation_p50", "validation_p95", "validation_p99",
        "heap_bytes_peak", "run_dir",
    ]
    row = {
        "timestamp": meta.get("timestamp", ""),
        "target": summary["target"],
        "scenario": summary["scenario"],
        "profile_key": summary["profile_key"],
        "matchbox_version": summary["matchbox_version"],
        "ig_version": summary["ig_version"],
        "java_opts": summary["java_opts"],
        "cpus": summary["cpus"],
        "threads": summary["threads"],
        "requested_rate_per_s": summary["requested_rate_per_s"],
        "duration_s": summary["duration_s"],
        "samples": total,
        "failed": failed,
        "error_rate": summary["error_rate"],
        "achieved_rps": summary["achieved_rps"],
        "http_p50": summary["http_ms"]["p50"],
        "http_p95": summary["http_ms"]["p95"],
        "http_p99": summary["http_ms"]["p99"],
        "validation_p50": summary["validation_ms"]["p50"],
        "validation_p95": summary["validation_ms"]["p95"],
        "validation_p99": summary["validation_ms"]["p99"],
        "heap_bytes_peak": summary["heap_bytes_peak"],
        "run_dir": out.name,
    }
    new = not history.exists()
    history.parent.mkdir(parents=True, exist_ok=True)
    with history.open("a", newline="", encoding="utf-8") as fh:
        w = csv.DictWriter(fh, fieldnames=cols)
        if new:
            w.writeheader()
        w.writerow(row)

    return 0


if __name__ == "__main__":
    sys.exit(main())
