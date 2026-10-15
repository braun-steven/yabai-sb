#!/usr/bin/env python3
"""Focused alternating space-switch latency probe for live A/B drift checks."""
import argparse
import hashlib
import json
import os
import pathlib
import platform
import statistics
import time

import perf


def percentile(values, fraction):
    ordered = sorted(values)
    return ordered[max(0, min(len(ordered) - 1,
                              int(len(ordered) * fraction + 0.999999) - 1))]


def switch(target):
    result = perf.cli(["space", "--focus", str(target)])
    if result.returncode:
        raise RuntimeError(result.stderr.strip() or f"CLI exit {result.returncode}")


def run_block(label, count, pause, current, mode):
    failures, values, started_ns = [], [], []
    for index in range(count):
        target = 5 if current[0] == 4 else 4
        started = time.perf_counter_ns()
        started_ns.append(started)
        try:
            switch(target)
            elapsed = (time.perf_counter_ns() - started) / 1e6
            if mode == "confirmed-between-switches":
                observed = perf.active_space()
                if observed != target:
                    raise RuntimeError(f"requested space {target}, observed {observed}")
            current[0] = target
            values.append(elapsed)
        except Exception as error:
            failures.append({"sample": index + 1, "error": str(error)})
        if pause:
            time.sleep(pause)
    intervals_ms = [(right - left) / 1e6 for left, right in zip(started_ns, started_ns[1:])]
    result = {"label": label, "samples": len(values), "failures": failures,
              "pause_ms": pause * 1000, "mode": mode, "values_ms": values,
              "command_start_intervals_ms": intervals_ms,
              "median_ms": statistics.median(values) if values else None,
              "p90_ms": percentile(values, .90) if values else None,
              "p95_ms": percentile(values, .95) if values else None,
              "max_ms": max(values) if values else None,
              "over_250ms": sum(value > 250 for value in values),
              "over_450ms": sum(value > 450 for value in values),
              "interval_over_250ms": sum(value > 250 for value in intervals_ms),
              "interval_over_450ms": sum(value > 450 for value in intervals_ms),
              "interval_median_ms": statistics.median(intervals_ms) if intervals_ms else None,
              "interval_p95_ms": percentile(intervals_ms, .95) if intervals_ms else None,
              "interval_max_ms": max(intervals_ms) if intervals_ms else None}
    print(f"{label}: n={len(values)} failures={len(failures)} "
          f"median={result['median_ms']:.2f}ms p95={result['p95_ms']:.2f}ms "
          f">250ms={result['over_250ms']} >450ms={result['over_450ms']} "
          f"max={result['max_ms']:.2f}ms", flush=True)
    return result


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("label")
    parser.add_argument("--out", required=True)
    parser.add_argument("--fast-samples", type=int, default=200)
    parser.add_argument("--normal-samples", type=int, default=100)
    parser.add_argument("--mode", choices=("confirmed-between-switches", "command-only"),
                        default="confirmed-between-switches")
    args = parser.parse_args()
    if args.fast_samples < 1 or args.normal_samples < 1:
        parser.error("sample counts must be positive")
    perf.require_unlocked_session()

    start_space = perf.active_space()
    if start_space != 4:
        raise SystemExit(f"probe requires space 4 active at start, found {start_space}")
    current = [start_space]
    warmups = []
    for index in range(10):
        target = 5 if current[0] == 4 else 4
        switch(target)
        observed = perf.active_space()
        warmups.append({"target": target, "observed": observed})
        if observed != target:
            raise SystemExit(f"warmup {index + 1} requested {target}, observed {observed}")
        current[0] = target
    if current[0] != 4:
        raise SystemExit("10 warmups should leave the probe on space 4")
    perf.require_unlocked_session()

    executable = os.path.realpath(perf.YABAI)
    payload = {"label": args.label,
               "started_utc": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()),
               "binary": executable,
               "binary_sha256": hashlib.sha256(pathlib.Path(executable).read_bytes()).hexdigest(),
               "binary_uuid": perf.run(["dwarfdump", "--uuid", executable]).stdout.strip(),
               "version": perf.run([executable, "--version"]).stdout.strip(),
               "daemon_pid": perf.daemon_pid(),
               "host": {"macos": perf.run(["sw_vers", "-productVersion"]).stdout.strip(),
                        "architecture": platform.machine()},
               "warmups": warmups,
               "mode": args.mode,
               "blocks": []}
    payload["blocks"].append(run_block("60ms cadence", args.fast_samples, .060, current, args.mode))
    perf.require_unlocked_session()
    payload["blocks"].append(run_block("250ms cadence", args.normal_samples, .250, current, args.mode))
    perf.require_unlocked_session()
    payload["end_active_space"] = perf.active_space()
    payload["end_daemon_pid"] = perf.daemon_pid()
    if payload["end_active_space"] != 4:
        raise SystemExit(f"probe ended on space {payload['end_active_space']}, expected 4")
    if payload["end_daemon_pid"] != payload["daemon_pid"]:
        raise SystemExit("daemon PID changed during probe")
    perf.require_unlocked_session()
    pathlib.Path(args.out).write_text(json.dumps(payload, indent=2) + "\n", encoding="utf-8")
    print(f"wrote {args.out}", flush=True)


if __name__ == "__main__":
    main()
