#!/usr/bin/env python3
"""Repeatable Android performance baseline for a debug Veer installation.

The runner uses only debug-only broadcast hooks, adb, curl, and Python's
standard library. It never reads app configuration or credential files.
"""

from __future__ import annotations

import argparse
import csv
import json
import re
import statistics
import subprocess
import sys
import time
from dataclasses import asdict, dataclass
from datetime import datetime, timezone
from pathlib import Path
from typing import Any


PACKAGE = "com.yamax.veer"
PROCESS_NAMES = {
    "ui": PACKAGE,
    "core": f"{PACKAGE}:veercore",
}
RECEIVER = f"{PACKAGE}/com.yamax.veer.testing.DebugRuntimeReceiver"
ACTION_PREFIX = f"{PACKAGE}.debug"
CONTROLLER_HOST_PORT = 19090
MIXED_HOST_PORT = 17890


class BenchmarkError(RuntimeError):
    pass


@dataclass
class StartupSample:
    iteration: int
    running_ms: float
    controller_ready_ms: float
    internet_ready_ms: float
    internet_http_code: int
    internet_request_ms: float


def run(
    command: list[str],
    *,
    check: bool = True,
    timeout: float = 30,
) -> subprocess.CompletedProcess[str]:
    result = subprocess.run(
        command,
        capture_output=True,
        text=True,
        timeout=timeout,
        check=False,
    )
    if check and result.returncode != 0:
        raise BenchmarkError(
            f"command failed ({result.returncode}): {' '.join(command)}\n"
            f"{result.stderr.strip() or result.stdout.strip()}"
        )
    return result


class Device:
    def __init__(self, adb: str, serial: str):
        self.adb = adb
        self.serial = serial

    def command(self, *args: str, check: bool = True, timeout: float = 30) -> str:
        result = run(
            [self.adb, "-s", self.serial, *args],
            check=check,
            timeout=timeout,
        )
        return result.stdout.strip()

    def shell(self, *args: str, check: bool = True, timeout: float = 30) -> str:
        return self.command("shell", *args, check=check, timeout=timeout)

    def broadcast(self, action: str) -> None:
        output = self.shell(
            "am",
            "broadcast",
            "-a",
            f"{ACTION_PREFIX}.{action}",
            "-n",
            RECEIVER,
        )
        if "result=0" not in output:
            raise BenchmarkError(f"broadcast {action} was not accepted: {output}")

    def engine_state(self) -> str:
        self.broadcast("DUMP_ENGINE_STATE")
        return self.shell(
            "run-as",
            PACKAGE,
            "cat",
            "files/debug_engine_state.txt",
        )

    def property(self, name: str) -> str:
        return self.shell("getprop", name, check=False)


def percentile(values: list[float], fraction: float) -> float:
    if not values:
        raise BenchmarkError("cannot calculate a percentile from no samples")
    ordered = sorted(values)
    index = max(0, min(len(ordered) - 1, round((len(ordered) - 1) * fraction)))
    return ordered[index]


def wait_for(
    predicate: Any,
    *,
    timeout_seconds: float,
    interval_seconds: float = 0.1,
    description: str,
) -> float:
    started = time.perf_counter()
    deadline = started + timeout_seconds
    last_error: Exception | None = None
    while time.perf_counter() < deadline:
        try:
            if predicate():
                return (time.perf_counter() - started) * 1000
        except Exception as error:  # transient process/controller restart
            last_error = error
        time.sleep(interval_seconds)
    suffix = f"; last error: {last_error}" if last_error else ""
    raise BenchmarkError(f"timed out waiting for {description}{suffix}")


def controller_request(path: str, *, timeout: float = 2) -> tuple[int, bytes, float]:
    url = f"http://127.0.0.1:{CONTROLLER_HOST_PORT}{path}"
    started = time.perf_counter()
    result = run(
        [
            "curl",
            "--noproxy",
            "*",
            "--silent",
            "--show-error",
            "--max-time",
            str(timeout),
            "--output",
            "-",
            "--write-out",
            "\n%{http_code}",
            url,
        ],
        check=False,
        timeout=timeout + 2,
    )
    elapsed_ms = (time.perf_counter() - started) * 1000
    if result.returncode != 0:
        return 0, b"", elapsed_ms
    body, _, code_text = result.stdout.rpartition("\n")
    return int(code_text or 0), body.encode(), elapsed_ms


def internet_probe(timeout: float = 8) -> tuple[int, float]:
    result = run(
        [
            "curl",
            "--silent",
            "--show-error",
            "--max-time",
            str(timeout),
            "--proxy",
            f"http://127.0.0.1:{MIXED_HOST_PORT}",
            "--output",
            "/dev/null",
            "--write-out",
            "%{http_code},%{time_total}",
            "https://www.gstatic.com/generate_204",
        ],
        check=False,
        timeout=timeout + 2,
    )
    if result.returncode != 0:
        return 0, timeout * 1000
    code, elapsed = result.stdout.strip().split(",", maxsplit=1)
    return int(code), float(elapsed) * 1000


def wait_controller(expected_up: bool, timeout_seconds: float = 15) -> float:
    return wait_for(
        lambda: (controller_request("/version")[0] == 200) is expected_up,
        timeout_seconds=timeout_seconds,
        description=f"controller {'up' if expected_up else 'down'}",
    )


def process_stat(device: Device, pid: str) -> tuple[int, int]:
    raw = device.shell("cat", f"/proc/{pid}/stat")
    tail = raw[raw.rfind(")") + 2 :].split()
    return int(tail[11]), int(tail[12])


def process_pids(device: Device) -> dict[str, str]:
    rows = device.shell("ps", "-A", "-o", "PID,NAME").splitlines()
    by_name: dict[str, str] = {}
    for row in rows:
        fields = row.split()
        if len(fields) >= 2:
            by_name[fields[1]] = fields[0]
    missing = [name for name in PROCESS_NAMES.values() if name not in by_name]
    if missing:
        raise BenchmarkError(f"missing Veer process(es): {', '.join(missing)}")
    return {role: by_name[name] for role, name in PROCESS_NAMES.items()}


def memory_snapshot(device: Device, pid: str) -> dict[str, int]:
    text = device.shell("dumpsys", "meminfo", pid, timeout=60)
    patterns = {
        "total_pss_kb": r"TOTAL PSS:\s+(\d+)",
        "total_rss_kb": r"TOTAL RSS:\s+(\d+)",
        "java_heap_pss_kb": r"Java Heap:\s+(\d+)",
        "native_heap_pss_kb": r"Native Heap:\s+(\d+)",
        "code_pss_kb": r"Code:\s+(\d+)",
        "private_other_pss_kb": r"Private Other:\s+(\d+)",
    }
    values: dict[str, int] = {}
    for name, pattern in patterns.items():
        match = re.search(pattern, text)
        if not match:
            raise BenchmarkError(f"dumpsys meminfo did not contain {name}")
        values[name] = int(match.group(1))
    return values


def aggregate_metrics(processes: dict[str, dict[str, int]]) -> dict[str, int]:
    keys = next(iter(processes.values())).keys()
    return {
        key: sum(process[key] for process in processes.values())
        for key in keys
    }


def median_memory_snapshot(
    device: Device,
    *,
    samples: int,
    interval_seconds: float,
) -> tuple[dict[str, Any], list[dict[str, Any]]]:
    raw_samples: list[dict[str, Any]] = []
    for index in range(samples):
        pids = process_pids(device)
        processes = {
            role: memory_snapshot(device, pid)
            for role, pid in pids.items()
        }
        raw_samples.append(
            {
                "pids": pids,
                "processes": processes,
                "aggregate": aggregate_metrics(processes),
            }
        )
        if index + 1 < samples:
            time.sleep(interval_seconds)
    process_medians = {
        role: {
            key: round(
                statistics.median(
                    sample["processes"][role][key] for sample in raw_samples
                )
            )
            for key in raw_samples[0]["processes"][role]
        }
        for role in PROCESS_NAMES
    }
    aggregate_medians = {
        key: round(
            statistics.median(sample["aggregate"][key] for sample in raw_samples)
        )
        for key in raw_samples[0]["aggregate"]
    }
    return {
        "processes": process_medians,
        "aggregate": aggregate_medians,
    }, raw_samples


def cpu_sample(device: Device, seconds: float) -> dict[str, Any]:
    pids = process_pids(device)
    clock_ticks = int(device.shell("getconf", "CLK_TCK"))
    before = {
        role: process_stat(device, pid)
        for role, pid in pids.items()
    }
    started = time.perf_counter()
    time.sleep(seconds)
    current_pids = process_pids(device)
    if current_pids != pids:
        raise BenchmarkError(
            f"Veer process changed during CPU sample: before={pids}, after={current_pids}"
        )
    after = {
        role: process_stat(device, pid)
        for role, pid in pids.items()
    }
    elapsed = time.perf_counter() - started
    processes: dict[str, dict[str, float]] = {}
    for role in PROCESS_NAMES:
        user_percent = (after[role][0] - before[role][0]) / clock_ticks / elapsed * 100
        system_percent = (
            (after[role][1] - before[role][1]) / clock_ticks / elapsed * 100
        )
        processes[role] = {
            "user_cpu_percent": round(user_percent, 3),
            "system_cpu_percent": round(system_percent, 3),
            "total_cpu_percent": round(user_percent + system_percent, 3),
        }
    aggregate = {
        key: round(sum(process[key] for process in processes.values()), 3)
        for key in next(iter(processes.values()))
    }
    return {
        "sample_seconds": round(elapsed, 3),
        "pids": pids,
        "processes": processes,
        "aggregate": aggregate,
    }


def device_metadata(device: Device) -> dict[str, Any]:
    return {
        "serial": device.serial,
        "manufacturer": device.property("ro.product.manufacturer"),
        "model": device.property("ro.product.model"),
        "device": device.property("ro.product.device"),
        "android_release": device.property("ro.build.version.release"),
        "sdk": device.property("ro.build.version.sdk"),
        "abi": device.property("ro.product.cpu.abi"),
        "build_fingerprint": device.property("ro.build.fingerprint"),
    }


def run_startup_sample(device: Device, iteration: int) -> StartupSample:
    device.broadcast("STOP_VPN")
    wait_for(
        lambda: "Stopped" in device.engine_state(),
        timeout_seconds=15,
        description="EngineState.Stopped",
    )
    wait_controller(False)
    time.sleep(0.5)

    started = time.perf_counter()
    device.broadcast("START_VPN")
    wait_for(
        lambda: "Running" in device.engine_state(),
        timeout_seconds=20,
        description="EngineState.Running",
    )
    running_ms = (time.perf_counter() - started) * 1000

    wait_controller(True)
    controller_ready_ms = (time.perf_counter() - started) * 1000
    code, request_ms = internet_probe()
    internet_ready_ms = (time.perf_counter() - started) * 1000
    if code not in (200, 204):
        raise BenchmarkError(f"internet probe failed with HTTP {code}")
    return StartupSample(
        iteration=iteration,
        running_ms=round(running_ms, 3),
        controller_ready_ms=round(controller_ready_ms, 3),
        internet_ready_ms=round(internet_ready_ms, 3),
        internet_http_code=code,
        internet_request_ms=round(request_ms, 3),
    )


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--adb", default="adb")
    parser.add_argument("--serial")
    parser.add_argument("--iterations", type=int, default=5)
    parser.add_argument("--warmup-seconds", type=float, default=30)
    parser.add_argument("--cpu-sample-seconds", type=float, default=10)
    parser.add_argument("--memory-samples", type=int, default=3)
    parser.add_argument("--memory-sample-interval", type=float, default=2)
    parser.add_argument(
        "--steady-ui-state",
        choices=("background", "foreground"),
        default="background",
    )
    parser.add_argument("--output", type=Path)
    args = parser.parse_args()
    if args.iterations < 1:
        parser.error("--iterations must be at least 1")
    if args.memory_samples < 1:
        parser.error("--memory-samples must be at least 1")

    if args.serial:
        serial = args.serial
    else:
        devices = [
            line.split()[0]
            for line in run([args.adb, "devices"]).stdout.splitlines()[1:]
            if line.endswith("\tdevice")
        ]
        if len(devices) != 1:
            raise BenchmarkError(
                f"expected exactly one adb device, found {len(devices)}; pass --serial"
            )
        serial = devices[0]
    device = Device(args.adb, serial)

    installed = device.shell("pm", "path", PACKAGE, check=False)
    if not installed:
        raise BenchmarkError(f"{PACKAGE} is not installed")
    device.shell("run-as", PACKAGE, "id")
    device.command(
        "forward",
        f"tcp:{CONTROLLER_HOST_PORT}",
        "tcp:9090",
    )
    device.command(
        "forward",
        f"tcp:{MIXED_HOST_PORT}",
        "tcp:7890",
    )

    timestamp = datetime.now(timezone.utc).strftime("%Y%m%dT%H%M%SZ")
    output_dir = args.output or Path("build/perf") / timestamp
    output_dir.mkdir(parents=True, exist_ok=True)

    samples: list[StartupSample] = []
    try:
        for iteration in range(1, args.iterations + 1):
            print(f"[{iteration}/{args.iterations}] measuring stop/start...", flush=True)
            sample = run_startup_sample(device, iteration)
            samples.append(sample)
            print(
                f"  Running={sample.running_ms:.1f}ms "
                f"controller={sample.controller_ready_ms:.1f}ms "
                f"internet={sample.internet_ready_ms:.1f}ms",
                flush=True,
            )

        print(f"warming up for {args.warmup_seconds:.1f}s...", flush=True)
        # PSS/RSS changes substantially when the Compose Activity is visible.
        # Make the requested foreground/background state explicit before every
        # steady-state sample instead of inheriting the operator's current UI.
        if args.steady_ui_state == "background":
            device.shell("input", "keyevent", "KEYCODE_HOME")
        else:
            device.shell(
                "am",
                "start",
                "-n",
                f"{PACKAGE}/.MainActivity",
            )
        time.sleep(args.warmup_seconds)
        memory, memory_samples = median_memory_snapshot(
            device,
            samples=args.memory_samples,
            interval_seconds=args.memory_sample_interval,
        )
        cpu = cpu_sample(device, args.cpu_sample_seconds)
        payloads: dict[str, Any] = {}
        for path in ("/version", "/configs", "/proxies", "/connections"):
            code, body, elapsed_ms = controller_request(path, timeout=5)
            payloads[path] = {
                "http_code": code,
                "bytes": len(body),
                "elapsed_ms": round(elapsed_ms, 3),
            }

        running_values = [sample.running_ms for sample in samples]
        controller_values = [sample.controller_ready_ms for sample in samples]
        internet_values = [sample.internet_ready_ms for sample in samples]
        summary = {
            "running_ms": {
                "median": round(statistics.median(running_values), 3),
                "p95": round(percentile(running_values, 0.95), 3),
            },
            "controller_ready_ms": {
                "median": round(statistics.median(controller_values), 3),
                "p95": round(percentile(controller_values, 0.95), 3),
            },
            "internet_ready_ms": {
                "median": round(statistics.median(internet_values), 3),
                "p95": round(percentile(internet_values, 0.95), 3),
            },
        }
        result = {
            "schema_version": 2,
            "captured_at_utc": timestamp,
            "package": PACKAGE,
            "build_type": "debug",
            "device": device_metadata(device),
            "settings": {
                "iterations": args.iterations,
                "warmup_seconds": args.warmup_seconds,
                "cpu_sample_seconds": args.cpu_sample_seconds,
                "memory_samples": args.memory_samples,
                "memory_sample_interval": args.memory_sample_interval,
                "steady_ui_state": args.steady_ui_state,
            },
            "startup_samples": [asdict(sample) for sample in samples],
            "startup_summary": summary,
            "steady_state": {
                "memory": memory,
                "memory_samples": memory_samples,
                "cpu": cpu,
                "controller_payloads": payloads,
            },
        }
        json_path = output_dir / "result.json"
        json_path.write_text(
            json.dumps(result, ensure_ascii=False, indent=2) + "\n",
            encoding="utf-8",
        )
        with (output_dir / "startup.csv").open("w", newline="", encoding="utf-8") as file:
            writer = csv.DictWriter(file, fieldnames=StartupSample.__dataclass_fields__)
            writer.writeheader()
            writer.writerows(asdict(sample) for sample in samples)

        print(json.dumps(summary, ensure_ascii=False, indent=2))
        print(f"results: {output_dir.resolve()}")
        return 0
    finally:
        # Benchmarking must not leave the user's VPN disconnected.
        try:
            if "Running" not in device.engine_state():
                device.broadcast("START_VPN")
                wait_for(
                    lambda: "Running" in device.engine_state(),
                    timeout_seconds=20,
                    description="final EngineState.Running",
                )
        except Exception as error:
            print(f"warning: could not restore running VPN: {error}", file=sys.stderr)


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except (BenchmarkError, subprocess.TimeoutExpired) as error:
        print(f"benchmark failed: {error}", file=sys.stderr)
        raise SystemExit(1)
