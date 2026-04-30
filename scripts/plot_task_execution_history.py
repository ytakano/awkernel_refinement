#!/usr/bin/env python3

from __future__ import annotations

import argparse
import csv
from dataclasses import dataclass
import pathlib
import sys


TASK_TRACE_BEGIN = "BEGIN_TASK_TRACE"
TASK_TRACE_END = "END_TASK_TRACE"
SCHED_TRACE_BEGIN = "BEGIN_SCHED_TRACE"
SCHED_TRACE_END = "END_SCHED_TRACE"


@dataclass(frozen=True)
class SchedTraceRow:
    row_index: int
    event_id: int
    cpu_id: int
    event: str
    event_a: str
    event_b: str
    current: int | None
    worker_current: tuple[int | None, ...]
    timestamp_us: int


@dataclass(frozen=True)
class PeriodicWindow:
    task_id: int
    loop_index: int
    wake_time_us: int
    absolute_deadline_us: int


@dataclass(frozen=True)
class ExecutionInterval:
    lane: str
    cpu_id: int
    task_id: int
    group: str
    loop_index: int | None
    start_event_id: int
    end_event_id: int
    start_us: int
    end_us: int

    @property
    def duration_us(self) -> int:
        return self.end_us - self.start_us


def load_lines(path: pathlib.Path) -> list[str]:
    return path.read_text(encoding="utf-8").splitlines()


def extract_block(lines: list[str], begin: str, end: str) -> list[str]:
    begin_indices = [i for i, line in enumerate(lines) if line.strip() == begin]
    end_indices = [i for i, line in enumerate(lines) if line.strip() == end]

    if len(begin_indices) != 1:
        raise ValueError(f"expected exactly one {begin} marker, found {len(begin_indices)}")
    if len(end_indices) != 1:
        raise ValueError(f"expected exactly one {end} marker, found {len(end_indices)}")

    begin_idx = begin_indices[0]
    end_idx = end_indices[0]
    if not begin_idx < end_idx:
        raise ValueError(f"{begin}/{end} markers are out of order")

    return [line.rstrip() for line in lines[begin_idx + 1 : end_idx]]


def option_int_from_field(value: str) -> int | None:
    if value == "-":
        return None
    if not value.isdigit():
        raise ValueError(f"expected optional natural number, got {value!r}")
    return int(value)


def option_int_list_from_csv(value: str) -> tuple[int | None, ...]:
    if value == "":
        return ()
    return tuple(option_int_from_field(field) for field in value.split(","))


def trace_lines_from_input(args: argparse.Namespace) -> tuple[list[str], list[str]]:
    if args.log is not None:
        lines = load_lines(args.log)
        return (
            extract_block(lines, args.sched_begin, args.sched_end),
            extract_block(lines, args.task_begin, args.task_end),
        )
    if args.sched_trace is None:
        raise ValueError("one of --log or --sched-trace is required")
    task_lines = load_lines(args.task_trace) if args.task_trace is not None else []
    return load_lines(args.sched_trace), task_lines


def parse_sched_trace_rows(lines: list[str]) -> list[SchedTraceRow]:
    rows: list[SchedTraceRow] = []
    for index, line in enumerate(lines, start=1):
        if not line.strip():
            continue
        fields = line.rstrip("\n").split("\t")
        if len(fields) != 13:
            raise ValueError(
                f"sched_trace row {index}: timestamped sched_trace row must have 13 TSV fields, got {len(fields)}"
            )
        try:
            event_id = int(fields[0])
            cpu_id = int(fields[1])
            current = option_int_from_field(fields[5])
            worker_current = option_int_list_from_csv(fields[9])
            timestamp_us = int(fields[12])
        except ValueError as exc:
            raise ValueError(f"sched_trace row {index}: invalid integer field: {line!r}") from exc
        rows.append(
            SchedTraceRow(
                row_index=index,
                event_id=event_id,
                cpu_id=cpu_id,
                event=fields[2],
                event_a=fields[3],
                event_b=fields[4],
                current=current,
                worker_current=worker_current,
                timestamp_us=timestamp_us,
            )
        )
    if not rows:
        raise ValueError("sched_trace block is empty")
    return rows


def parse_periodic_windows(lines: list[str]) -> dict[int, list[PeriodicWindow]]:
    windows: dict[int, list[PeriodicWindow]] = {}
    for index, line in enumerate(lines, start=1):
        if not line.strip():
            continue
        fields = line.rstrip("\n").split("\t")
        if len(fields) < 2 or fields[1] != "RunnableDeadline":
            continue
        if len(fields) != 11:
            continue
        try:
            task_id = int(fields[2])
            wake_time_us = int(fields[8])
            absolute_deadline_us = int(fields[9])
            loop_index = int(fields[10])
        except ValueError as exc:
            raise ValueError(f"task_trace row {index}: invalid RunnableDeadline metadata: {line!r}") from exc
        windows.setdefault(task_id, []).append(
            PeriodicWindow(
                task_id=task_id,
                loop_index=loop_index,
                wake_time_us=wake_time_us,
                absolute_deadline_us=absolute_deadline_us,
            )
        )
    for task_windows in windows.values():
        task_windows.sort(key=lambda window: (window.wake_time_us, window.loop_index))
    return windows


def running_task_for_row(row: SchedTraceRow) -> tuple[int, int] | None:
    if row.worker_current:
        non_empty = [task_id for task_id in row.worker_current if task_id is not None]
        if len(non_empty) > 1:
            raise ValueError(
                f"sched_trace row {row.row_index}: single-worker trace has multiple running worker tasks"
            )
        if not non_empty:
            return None
        return (0, non_empty[0])
    if row.current is None:
        return None
    return (row.cpu_id, row.current)


def periodic_loop_for_slice(
    task_id: int,
    start_us: int,
    windows_by_task: dict[int, list[PeriodicWindow]],
) -> int | None:
    for window in windows_by_task.get(task_id, []):
        if window.wake_time_us <= start_us < window.absolute_deadline_us:
            return window.loop_index
    return None


def build_execution_intervals(
    rows: list[SchedTraceRow],
    windows_by_task: dict[int, list[PeriodicWindow]],
) -> list[ExecutionInterval]:
    intervals: list[ExecutionInterval] = []
    sorted_rows = sorted(rows, key=lambda row: (row.event_id, row.row_index))

    for previous, current in zip(sorted_rows, sorted_rows[1:]):
        if current.timestamp_us < previous.timestamp_us:
            raise ValueError(f"sched_trace row {current.row_index}: timestamp_us decreases")
        if current.timestamp_us == previous.timestamp_us:
            continue
        running_task = running_task_for_row(previous)
        if running_task is None:
            continue
        cpu_id, task_id = running_task
        loop_index = periodic_loop_for_slice(task_id, previous.timestamp_us, windows_by_task)
        if task_id in windows_by_task:
            group = "periodic"
            lane = f"task {task_id}"
        else:
            group = "others"
            lane = "others"
        intervals.append(
            ExecutionInterval(
                lane=lane,
                cpu_id=cpu_id,
                task_id=task_id,
                group=group,
                loop_index=loop_index,
                start_event_id=previous.event_id,
                end_event_id=current.event_id,
                start_us=previous.timestamp_us,
                end_us=current.timestamp_us,
            )
        )

    if not intervals:
        raise ValueError("no execution intervals found in timestamped sched_trace")
    return coalesce_intervals(intervals)


def coalesce_intervals(intervals: list[ExecutionInterval]) -> list[ExecutionInterval]:
    merged: list[ExecutionInterval] = []
    for interval in sorted(
        intervals,
        key=lambda item: (item.cpu_id, item.start_us, item.end_us, item.task_id),
    ):
        if (
            merged
            and merged[-1].cpu_id == interval.cpu_id
            and merged[-1].lane == interval.lane
            and merged[-1].task_id == interval.task_id
            and merged[-1].group == interval.group
            and merged[-1].loop_index == interval.loop_index
            and merged[-1].end_us == interval.start_us
        ):
            previous = merged[-1]
            merged[-1] = ExecutionInterval(
                lane=previous.lane,
                cpu_id=previous.cpu_id,
                task_id=previous.task_id,
                group=previous.group,
                loop_index=previous.loop_index,
                start_event_id=previous.start_event_id,
                end_event_id=interval.end_event_id,
                start_us=previous.start_us,
                end_us=interval.end_us,
            )
        else:
            merged.append(interval)
    return sorted(merged, key=lambda item: (item.start_us, item.cpu_id, item.task_id))


def normalize_execution_origin_us(
    intervals: list[ExecutionInterval],
    *,
    absolute_time: bool,
) -> int:
    if absolute_time:
        return 0
    return min(interval.start_us for interval in intervals)


def write_execution_csv(
    intervals: list[ExecutionInterval],
    output: pathlib.Path,
    *,
    absolute_time: bool,
) -> None:
    output.parent.mkdir(parents=True, exist_ok=True)
    normalized_origin_us = normalize_execution_origin_us(
        intervals,
        absolute_time=absolute_time,
    )
    with output.open("w", encoding="utf-8", newline="") as handle:
        writer = csv.writer(handle)
        writer.writerow(
            [
                "lane",
                "cpu",
                "task_id",
                "group",
                "loop_index",
                "start_event_id",
                "end_event_id",
                "start_us",
                "end_us",
                "duration_us",
                "start_ms",
                "end_ms",
                "duration_ms",
            ]
        )
        for interval in sorted(intervals, key=lambda item: (item.start_us, item.cpu_id, item.task_id)):
            start_us = interval.start_us - normalized_origin_us
            end_us = interval.end_us - normalized_origin_us
            writer.writerow(
                [
                    interval.lane,
                    interval.cpu_id,
                    interval.task_id,
                    interval.group,
                    "" if interval.loop_index is None else interval.loop_index,
                    interval.start_event_id,
                    interval.end_event_id,
                    start_us,
                    end_us,
                    interval.duration_us,
                    f"{start_us / 1000:.6f}",
                    f"{end_us / 1000:.6f}",
                    f"{interval.duration_us / 1000:.6f}",
                ]
            )


def plot_execution_intervals(
    intervals: list[ExecutionInterval],
    output: pathlib.Path,
    *,
    absolute_time: bool,
    title: str | None,
    width: float,
    height: float,
    x_min_ms: float | None,
) -> None:
    import matplotlib

    matplotlib.use("Agg")
    import matplotlib.pyplot as plt

    output.parent.mkdir(parents=True, exist_ok=True)
    normalized_origin_us = normalize_execution_origin_us(
        intervals,
        absolute_time=absolute_time,
    )
    periodic_lanes = sorted(
        {interval.lane for interval in intervals if interval.group == "periodic"},
        key=lambda lane: int(lane.split()[1]),
    )
    lanes = periodic_lanes + (["others"] if any(interval.group == "others" for interval in intervals) else [])
    y_by_lane = {lane: row for row, lane in enumerate(lanes)}
    colors = plt.get_cmap("tab10")

    fig, ax = plt.subplots(figsize=(width, height))
    for interval in sorted(intervals, key=lambda item: (item.start_us, item.cpu_id, item.task_id)):
        y = y_by_lane[interval.lane]
        start_ms = (interval.start_us - normalized_origin_us) / 1000.0
        duration_ms = interval.duration_us / 1000.0
        color = "0.45" if interval.group == "others" else colors(y_by_lane[interval.lane] % 10)
        ax.barh(
            y,
            duration_ms,
            left=start_ms,
            height=0.65,
            color=color,
            edgecolor="black",
            linewidth=0.3,
        )
        if interval.group == "periodic" and interval.loop_index is not None and duration_ms >= 1.0:
            ax.text(
                start_ms + duration_ms / 2.0,
                y,
                str(interval.loop_index),
                ha="center",
                va="center",
                fontsize=6,
                color="white",
            )

    ax.set_yticks([y_by_lane[lane] for lane in lanes])
    ax.set_yticklabels(lanes)
    ax.set_xlabel("time (ms)" if not absolute_time else "timestamp_us (ms)")
    ax.set_ylabel("task")
    ax.grid(axis="x", linestyle=":", linewidth=0.6, alpha=0.7)
    ax.set_axisbelow(True)
    ax.set_title(title or "Awkernel sched_trace execution history")
    if x_min_ms is not None:
        ax.set_xlim(left=x_min_ms)
    fig.tight_layout()
    fig.savefig(output, dpi=160)
    plt.close(fig)


def parse_args(argv: list[str]) -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description="Plot Awkernel task execution history from timestamped sched_trace rows."
    )
    input_group = parser.add_mutually_exclusive_group(required=True)
    input_group.add_argument(
        "--log",
        type=pathlib.Path,
        help="captured serial log containing BEGIN_SCHED_TRACE and BEGIN_TASK_TRACE",
    )
    input_group.add_argument(
        "--sched-trace",
        type=pathlib.Path,
        help="extracted timestamped sched_trace TSV file",
    )
    parser.add_argument("--task-trace", type=pathlib.Path, help="optional extracted task_trace TSV metadata file")
    parser.add_argument("--out", type=pathlib.Path, help="PNG output path")
    parser.add_argument("--csv-out", type=pathlib.Path, help="optional normalized interval CSV output path")
    parser.add_argument("--sched-begin", default=SCHED_TRACE_BEGIN)
    parser.add_argument("--sched-end", default=SCHED_TRACE_END)
    parser.add_argument("--task-begin", default=TASK_TRACE_BEGIN)
    parser.add_argument("--task-end", default=TASK_TRACE_END)
    parser.add_argument("--absolute-time", action="store_true", help="do not normalize the first slice start to zero")
    parser.add_argument("--x-min-ms", type=float, help="set the left edge of the plotted x axis in ms")
    parser.add_argument("--title", help="plot title")
    parser.add_argument("--width", type=float, default=12.0)
    parser.add_argument("--height", type=float, default=4.5)
    args = parser.parse_args(argv)

    if args.out is None and args.csv_out is None:
        parser.error("at least one of --out or --csv-out is required")
    if args.width <= 0 or args.height <= 0:
        parser.error("--width and --height must be positive")

    return args


def main(argv: list[str] | None = None) -> int:
    args = parse_args(sys.argv[1:] if argv is None else argv)

    try:
        sched_lines, task_lines = trace_lines_from_input(args)
        intervals = build_execution_intervals(
            parse_sched_trace_rows(sched_lines),
            parse_periodic_windows(task_lines),
        )
        if args.csv_out is not None:
            write_execution_csv(
                intervals,
                args.csv_out,
                absolute_time=args.absolute_time,
            )
        if args.out is not None:
            plot_execution_intervals(
                intervals,
                args.out,
                absolute_time=args.absolute_time,
                title=args.title,
                width=args.width,
                height=args.height,
                x_min_ms=args.x_min_ms,
            )
    except ValueError as exc:
        print(f"error: {exc}", file=sys.stderr)
        return 2

    return 0


if __name__ == "__main__":
    raise SystemExit(main())
