#!/usr/bin/env python3
"""Read existing sampler JSONL only; never attach to or control a process."""
import argparse
from collections import Counter
import json
import math
from pathlib import Path
import statistics

NS = 1_000_000_000
MIB = 1024 ** 2


def number(value, name):
    if isinstance(value, bool) or not isinstance(value, (float, int)) or not math.isfinite(value) or value < 0:
        raise ValueError("Invalid nonnegative numeric field: " + name)
    return value


def describe(values):
    if not values:
        return None
    ordered = sorted(values)
    return {"mean": statistics.mean(values), "median": statistics.median(values),
            "p95": ordered[max(0, math.ceil(len(ordered) * .95) - 1)], "max": ordered[-1]}


def analyze(rows, skip=0, duration=None):
    metadata = [r for r in rows if r.get("type") == "metadata"]
    summaries = [r for r in rows if r.get("type") == "summary"]
    if len(metadata) != 1 or metadata[0].get("schema") != 1 or len(summaries) > 1:
        raise ValueError("Expected one schema 1 metadata record and at most one summary.")
    samples = [r for r in rows if r.get("type") == "sample"]
    start = skip * NS
    end = math.inf if duration is None else start + duration * NS
    selected, usable = [], []
    previous = -1
    excluded = Counter()
    for sample in samples:
        elapsed = number(sample.get("elapsed_ns"), "elapsed_ns")
        interval = number(sample.get("interval_ns"), "interval_ns")
        if elapsed <= previous:
            raise ValueError("Sample elapsed times must strictly increase.")
        previous = elapsed
        # Keep whole intervals only; never assign mixed warm-up/workload time
        # to a selected phase or splice a recovered multi-interval CPU delta.
        if interval <= 0 or elapsed - interval < start or elapsed > end:
            excluded["outside_requested_whole_intervals"] += 1
            continue
        selected.append(sample)
        if sample.get("observed_interval_complete") is not True or sample.get("cpu_percent_one_core") is None:
            excluded["known_gap_or_baseline"] += 1
            continue
        delta = number(sample.get("cpu_delta_ns_observed"), "cpu_delta_ns_observed")
        rate = number(sample["cpu_percent_one_core"], "cpu_percent_one_core")
        if not math.isclose(rate, 100 * delta / interval, rel_tol=1e-6, abs_tol=1e-6):
            raise ValueError("Reported CPU rate disagrees with observed CPU/interval.")
        usable.append(sample)
    covered = sum(s["interval_ns"] for s in usable)
    selected_span = (selected[-1]["elapsed_ns"] - (selected[0]["elapsed_ns"] - selected[0]["interval_ns"])) if selected else 0
    observed_cpu = sum(s["cpu_delta_ns_observed"] for s in usable)
    result = {
        "root_pid": metadata[0].get("root_pid"),
        "completed_report": bool(summaries),
        "requested_window_seconds": {"skip": skip, "duration": duration},
        "whole_intervals_in_window": len(selected), "usable_complete_intervals": len(usable),
        "excluded_intervals": dict(excluded),
        "selected_span_seconds": selected_span / NS,
        "complete_observed_seconds": covered / NS,
        "known_coverage_fraction": covered / selected_span if selected_span else None,
        "cpu_seconds_complete_intervals": observed_cpu / NS,
        "cpu_percent_one_core_time_weighted": 100 * observed_cpu / covered if covered else None,
        "cpu_percent_one_core_interval_distribution": describe([s["cpu_percent_one_core"] for s in usable]),
        "physical_footprint_mib_sample_distribution": describe([number(s.get("physical_footprint_bytes"), "physical_footprint_bytes") / MIB for s in usable]),
        "rss_mib_sample_distribution": describe([number(s.get("rss_bytes"), "rss_bytes") / MIB for s in usable]),
        "collection_ms_distribution": describe([number(s.get("collection_duration_ns"), "collection_duration_ns") / 1e6 for s in selected]),
        "system_cpu_busy_percent_distribution": describe([number(s["system_cpu_busy_percent"], "system_cpu_busy_percent") for s in selected if s.get("system_cpu_busy_percent") is not None]),
        "system_load_1m_distribution": describe([number(s["system_load_average"][0], "system_load_average") for s in selected if s.get("system_load_average")]),
        "events_whole_report": dict(Counter(r.get("event", "unknown") for r in rows if r.get("type") == "event")),
        "sampler_summary": summaries[0] if summaries else None,
    }
    for key in ["disk_read_delta_bytes", "disk_write_delta_bytes", "interrupt_wakeups_delta", "package_idle_wakeups_delta"]:
        total = sum(number(s.get(key), key) for s in usable)
        result[key + "_complete_intervals"] = total
        result[key + "_per_second"] = total * NS / covered if covered else None
    return result


def self_test():
    def sample(elapsed, interval, cpu, complete=True):
        return dict(type="sample", elapsed_ns=elapsed * NS, interval_ns=interval * NS,
                    cpu_delta_ns_observed=cpu * NS, cpu_percent_one_core=100 * cpu / interval if complete else None,
                    observed_interval_complete=complete, physical_footprint_bytes=MIB, rss_bytes=2*MIB,
                    collection_duration_ns=1000, disk_read_delta_bytes=0, disk_write_delta_bytes=0,
                    interrupt_wakeups_delta=0, package_idle_wakeups_delta=0,
                    system_cpu_busy_percent=10, system_load_average=[1, 1, 1])
    rows = [dict(type="metadata", schema=1, root_pid=123), sample(1, 1, 1),
            sample(3, 2, 1), sample(4, 1, 9, False), sample(5, 1, .25), dict(type="summary")]
    result = analyze(rows)
    assert result["cpu_percent_one_core_time_weighted"] == 56.25
    assert result["known_coverage_fraction"] == .8
    assert result["excluded_intervals"]["known_gap_or_baseline"] == 1
    assert analyze(rows, skip=2)["usable_complete_intervals"] == 1  # Don't split 1–3s.
    assert analyze(rows, skip=1, duration=2)["cpu_percent_one_core_time_weighted"] == 50
    assert not analyze(rows[:-1])["completed_report"]
    assert analyze(rows, skip=10)["cpu_percent_one_core_time_weighted"] is None
    bad = [dict(r) for r in rows]; bad[1]["cpu_percent_one_core"] = 999
    try:
        analyze(bad)
    except ValueError:
        pass
    else:
        raise AssertionError("Inconsistent rate was accepted")
    print("Offline analyzer self-test passed (synthetic records only).")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--run", action="append", default=[], metavar="LABEL=JSONL")
    parser.add_argument("--skip-seconds", type=float, default=0)
    parser.add_argument("--duration", type=float)
    parser.add_argument("--self-test", action="store_true")
    args = parser.parse_args()
    if args.self_test:
        self_test(); return
    if not args.run or not math.isfinite(args.skip_seconds) or args.skip_seconds < 0 or (args.duration is not None and (not math.isfinite(args.duration) or args.duration <= 0)):
        parser.error("Provide --run LABEL=JSONL and finite nonnegative skip / positive duration.")
    output = {"analysis_schema": 1, "runs": [], "limits": [
        "Workload, versions, accessibility, power, viewport, caches and extensions must be matched separately.",
        "Known missing CPU intervals are excluded, not zero. Polling can still miss short-lived processes.",
        "CPU 100% is one logical core; footprint/RSS are summed process accounting, not unique memory.",
        "Per-sample distributions are unweighted; the reported CPU mean is time weighted.",
        "No measurement of GPU utilization, energy, fans, input latency or visual smoothness; no automatic performance verdict.",
    ]}
    labels = set()
    try:
        for item in args.run:
            label, separator, filename = item.partition("=")
            if not separator or not label or not filename or label in labels:
                raise ValueError("Runs need unique LABEL=JSONL values.")
            labels.add(label)
            path = Path(filename)
            rows = [json.loads(line) for line in path.read_text().splitlines() if line.strip()]
            result = analyze(rows, args.skip_seconds, args.duration)
            output["runs"].append(dict(label=label, file=str(path), **result))
    except (OSError, ValueError, TypeError) as error:
        parser.error(str(error))
    print(json.dumps(output, indent=2, allow_nan=False))


if __name__ == "__main__":
    main()
