#!/usr/bin/env python3

from __future__ import annotations

import argparse
from datetime import datetime, timezone
import pathlib
import subprocess
import sys
import time


REPO_ROOT = pathlib.Path(__file__).resolve().parents[1]
AWKERNEL_DIR = REPO_ROOT / "awkernel"
CHECKER_BIN = REPO_ROOT / "target" / "adapter" / "haskell" / "workload_acceptance"


def run_command(
    command: list[str],
    *,
    cwd: pathlib.Path = REPO_ROOT,
    capture: bool = False,
    check: bool = True,
) -> subprocess.CompletedProcess[str]:
    result = subprocess.run(
        command,
        cwd=cwd,
        text=True,
        stdout=subprocess.PIPE if capture else None,
        stderr=subprocess.PIPE if capture else None,
        check=False,
    )
    if check and result.returncode != 0:
        if capture:
            if result.stdout:
                print(result.stdout, end="")
            if result.stderr:
                print(result.stderr, end="", file=sys.stderr)
        raise subprocess.CalledProcessError(result.returncode, command)
    return result


def virsh(args: list[str], *, capture: bool = True, check: bool = True) -> subprocess.CompletedProcess[str]:
    return run_command(["virsh", "-c", "qemu:///system", *args], capture=capture, check=check)


def domain_state(domain: str) -> str:
    result = virsh(["domstate", domain])
    return result.stdout.strip()


def wait_for_shutdown(domain: str, timeout_s: float, poll_s: float) -> None:
    deadline = time.monotonic() + timeout_s
    while time.monotonic() < deadline:
        if domain_state(domain) == "shut off":
            return
        time.sleep(poll_s)
    raise TimeoutError(f"domain {domain} did not shut off within {timeout_s:.1f}s")


def build_inputs(args: argparse.Namespace) -> None:
    if args.skip_build:
        return
    print("building periodic Awkernel image")
    run_command(
        [
            "make",
            "-C",
            str(AWKERNEL_DIR),
            "build-workload-trace-x86_64",
            "WORKLOAD_SCENARIO=periodic",
        ]
    )
    print("building Haskell workload checker")
    run_command(["make", "-C", str(REPO_ROOT), str(CHECKER_BIN)])


def download_log(args: argparse.Namespace, log_path: pathlib.Path) -> None:
    log_path.parent.mkdir(parents=True, exist_ok=True)
    virsh(
        [
            "vol-download",
            "--pool",
            args.pool,
            args.volume,
            str(log_path),
        ],
        capture=True,
    )


def run_checker(args: argparse.Namespace, log_path: pathlib.Path, run_index: int) -> subprocess.CompletedProcess[str]:
    return run_command(
        [
            "python3",
            str(REPO_ROOT / "scripts" / "check_workload_acceptance.py"),
            "--backend",
            args.backend,
            "--scenario",
            f"{args.scenario}-run-{run_index:04d}",
            "--log",
            str(log_path),
            "--checker-bin",
            str(args.checker_bin),
        ],
        capture=True,
        check=False,
    )


def run_once(args: argparse.Namespace, run_index: int) -> bool:
    state = domain_state(args.domain)
    if state != "shut off":
        raise RuntimeError(f"domain {args.domain} must be shut off before run {run_index}; current state: {state}")

    stamp = datetime.now(timezone.utc).strftime("%Y%m%dT%H%M%SZ")
    log_path = args.log_dir / f"periodic-run-{run_index:04d}-{stamp}.log"

    print(f"[{run_index}/{args.repeats}] starting {args.domain}")
    virsh(["start", args.domain], capture=True)
    try:
        wait_for_shutdown(args.domain, args.timeout_s, args.poll_s)
    except Exception:
        print(f"[{run_index}/{args.repeats}] VM did not complete cleanly")
        try:
            download_log(args, log_path)
            print(f"log saved: {log_path}")
        except Exception as exc:
            print(f"failed to download log after VM failure: {exc}", file=sys.stderr)
        raise

    download_log(args, log_path)
    result = run_checker(args, log_path, run_index)
    if result.stdout:
        print(result.stdout, end="")
    if result.stderr:
        print(result.stderr, end="", file=sys.stderr)

    if result.returncode != 0:
        print(f"[{run_index}/{args.repeats}] checker rejected trace")
        print(f"rejected log: {log_path}")
        return False

    print(f"[{run_index}/{args.repeats}] accepted log: {log_path}")
    return True


def parse_args(argv: list[str]) -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description="Repeatedly run the Awkernel periodic_trace_vm KVM workload and check each emitted trace."
    )
    parser.add_argument("repeats", type=int, help="number of periodic KVM runs to execute")
    parser.add_argument("--domain", default="awkernel-periodic-2cpu")
    parser.add_argument("--pool", default="default")
    parser.add_argument("--volume", default="awkernel-periodic-2cpu.log")
    parser.add_argument("--log-dir", type=pathlib.Path, default=pathlib.Path("/tmp/awkernel_periodic_kvm_runs"))
    parser.add_argument("--checker-bin", type=pathlib.Path, default=CHECKER_BIN)
    parser.add_argument("--backend", default="kvm-workload")
    parser.add_argument("--scenario", default="periodic")
    parser.add_argument("--timeout-s", type=float, default=60.0)
    parser.add_argument("--poll-s", type=float, default=1.0)
    parser.add_argument("--skip-build", action="store_true", help="reuse the existing Awkernel image and checker")
    args = parser.parse_args(argv)

    if args.repeats <= 0:
        parser.error("repeats must be positive")
    if args.timeout_s <= 0:
        parser.error("--timeout-s must be positive")
    if args.poll_s <= 0:
        parser.error("--poll-s must be positive")
    return args


def main(argv: list[str] | None = None) -> int:
    args = parse_args(sys.argv[1:] if argv is None else argv)

    try:
        build_inputs(args)
        for run_index in range(1, args.repeats + 1):
            if not run_once(args, run_index):
                return 1
    except subprocess.CalledProcessError as exc:
        print(f"command failed with exit code {exc.returncode}: {' '.join(exc.cmd)}", file=sys.stderr)
        return exc.returncode or 1
    except Exception as exc:
        print(f"error: {exc}", file=sys.stderr)
        return 1

    print(f"all {args.repeats} periodic KVM runs accepted")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
