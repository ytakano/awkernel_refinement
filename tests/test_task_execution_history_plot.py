from __future__ import annotations

import csv
import pathlib
import subprocess
import sys
import tempfile
import unittest


class TaskExecutionHistoryPlotTest(unittest.TestCase):
    @classmethod
    def setUpClass(cls) -> None:
        cls.repo_root = pathlib.Path(__file__).resolve().parents[1]
        cls.script = cls.repo_root / "scripts" / "plot_task_execution_history.py"

    def make_file(self, name: str, contents: str) -> pathlib.Path:
        tmpdir = tempfile.TemporaryDirectory(prefix="task-execution-history-")
        self.addCleanup(tmpdir.cleanup)
        path = pathlib.Path(tmpdir.name) / name
        path.write_text(contents, encoding="utf-8")
        return path

    def run_script(self, *args: str | pathlib.Path) -> subprocess.CompletedProcess[str]:
        return subprocess.run(
            [sys.executable, str(self.script), *[str(arg) for arg in args]],
            cwd=self.repo_root,
            text=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            check=False,
        )

    def test_writes_normalized_interval_csv_from_serial_log(self) -> None:
        log = self.make_file(
            "serial.log",
            "\n".join(
                [
                    "boot noise",
                    "BEGIN_SCHED_TRACE",
                    "0\t0\tWakeup\t1\t-\t-\t1\tfalse\t-\t-\tfalse\t-\t1000",
                    "1\t0\tDispatch\t1\t2\t2\t\tfalse\t-\t2\tfalse\t-\t1100",
                    "2\t0\tChoose\t1\t3\t-\t3\tfalse\t3\t-\tfalse\t3\t1200",
                    "3\t0\tDispatch\t1\t3\t3\t\tfalse\t-\t3\tfalse\t-\t1250",
                    "4\t0\tComplete\t3\t-\t-\t\ttrue\t-\t-\ttrue\t-\t1300",
                    "END_SCHED_TRACE",
                    "BEGIN_TASK_TRACE",
                    "0\tSpawn\t1\t-\t-\t-\tPrioritizedFIFO\t31",
                    "1\tRunnableDeadline\t2\t-\t-\t-\tGlobalEDF\t100\t1000\t2000\t0",
                    "END_TASK_TRACE",
                    "",
                ]
            ),
        )
        out = log.parent / "history.csv"

        result = self.run_script("--log", log, "--csv-out", out)

        self.assertEqual(result.returncode, 0, result.stderr)
        with out.open(encoding="utf-8", newline="") as handle:
            rows = list(csv.DictReader(handle))

        self.assertEqual(
            rows,
            [
                {
                    "lane": "task 2",
                    "cpu": "0",
                    "task_id": "2",
                    "group": "periodic",
                    "loop_index": "0",
                    "start_event_id": "1",
                    "end_event_id": "2",
                    "start_us": "0",
                    "end_us": "100",
                    "duration_us": "100",
                    "start_ms": "0.000000",
                    "end_ms": "0.100000",
                    "duration_ms": "0.100000",
                },
                {
                    "lane": "others",
                    "cpu": "0",
                    "task_id": "3",
                    "group": "others",
                    "loop_index": "",
                    "start_event_id": "3",
                    "end_event_id": "4",
                    "start_us": "150",
                    "end_us": "200",
                    "duration_us": "50",
                    "start_ms": "0.150000",
                    "end_ms": "0.200000",
                    "duration_ms": "0.050000",
                },
            ],
        )

    def test_absolute_time_keeps_actual_release_time(self) -> None:
        trace = self.make_file(
            "sched_trace.tsv",
            "\n".join(
                [
                    "0\t0\tDispatch\t1\t2\t2\t\tfalse\t-\t2\tfalse\t-\t1000",
                    "1\t0\tComplete\t2\t-\t-\t\ttrue\t-\t-\ttrue\t-\t1050",
                    "",
                ]
            ),
        )
        out = trace.parent / "history.csv"

        result = self.run_script("--sched-trace", trace, "--csv-out", out, "--absolute-time")

        self.assertEqual(result.returncode, 0, result.stderr)
        with out.open(encoding="utf-8", newline="") as handle:
            rows = list(csv.DictReader(handle))
        self.assertEqual(rows[0]["start_us"], "1000")
        self.assertEqual(rows[0]["end_us"], "1050")

    def test_x_min_ms_does_not_change_csv_normalization(self) -> None:
        trace = self.make_file(
            "sched_trace.tsv",
            "\n".join(
                [
                    "0\t0\tDispatch\t1\t2\t2\t\tfalse\t-\t2\tfalse\t-\t2000000",
                    "1\t0\tComplete\t2\t-\t-\t\ttrue\t-\t-\ttrue\t-\t2050000",
                    "",
                ]
            ),
        )
        out = trace.parent / "history.csv"
        image = trace.parent / "history.png"

        result = self.run_script("--sched-trace", trace, "--csv-out", out, "--out", image, "--x-min-ms", "2000")

        self.assertEqual(result.returncode, 0, result.stderr)
        with out.open(encoding="utf-8", newline="") as handle:
            rows = list(csv.DictReader(handle))
        self.assertEqual(rows[0]["start_us"], "0")
        self.assertEqual(rows[0]["end_us"], "50000")
        self.assertEqual(rows[0]["start_ms"], "0.000000")
        self.assertEqual(rows[0]["end_ms"], "50.000000")
        self.assertTrue(image.exists())

    def test_rejects_multiple_running_tasks_in_single_worker_snapshot(self) -> None:
        log = self.make_file(
            "serial.log",
            "\n".join(
                [
                    "BEGIN_SCHED_TRACE",
                    "0\t0\tDispatch\t1\t2\t2\t\tfalse\t-\t2,3\tfalse,false\t-,-\t1000",
                    "1\t0\tChoose\t1\t2\t2\t\tfalse\t-\t2,-\tfalse,false\t-,-\t1100",
                    "2\t0\tComplete\t2\t-\t-\t\ttrue\t-\t-,-\ttrue,true\t-,-\t1200",
                    "END_SCHED_TRACE",
                    "BEGIN_TASK_TRACE",
                    "0\tRunnableDeadline\t2\t-\t-\t-\tGlobalEDF\t100\t1000\t2000\t0",
                    "1\tRunnableDeadline\t3\t-\t-\t-\tGlobalEDF\t100\t1000\t2000\t0",
                    "END_TASK_TRACE",
                    "",
                ]
            ),
        )
        out = log.parent / "history.csv"

        result = self.run_script("--log", log, "--csv-out", out)

        self.assertEqual(result.returncode, 2)
        self.assertIn("single-worker trace has multiple running worker tasks", result.stderr)

    def test_single_worker_snapshot_uses_one_execution_lane(self) -> None:
        log = self.make_file(
            "serial.log",
            "\n".join(
                [
                    "BEGIN_SCHED_TRACE",
                    "0\t0\tDispatch\t1\t2\t2\t\tfalse\t-\t2\tfalse\t-\t1000",
                    "1\t1\tChoose\t1\t3\t-\t3\tfalse\t3\t2\tfalse\t-\t1100",
                    "2\t0\tComplete\t2\t-\t-\t\ttrue\t-\t-\ttrue\t-\t1200",
                    "END_SCHED_TRACE",
                    "BEGIN_TASK_TRACE",
                    "0\tRunnableDeadline\t2\t-\t-\t-\tGlobalEDF\t100\t1000\t2000\t0",
                    "END_TASK_TRACE",
                    "",
                ]
            ),
        )
        out = log.parent / "history.csv"

        result = self.run_script("--log", log, "--csv-out", out)

        self.assertEqual(result.returncode, 0, result.stderr)
        with out.open(encoding="utf-8", newline="") as handle:
            rows = list(csv.DictReader(handle))
        self.assertEqual(len(rows), 1)
        self.assertEqual(rows[0]["cpu"], "0")
        self.assertEqual(rows[0]["task_id"], "2")
        self.assertEqual(rows[0]["start_us"], "0")
        self.assertEqual(rows[0]["end_us"], "200")

    def test_rejects_missing_sched_trace_marker(self) -> None:
        log = self.make_file("serial.log", "BEGIN_TASK_TRACE\nEND_TASK_TRACE\n")
        out = log.parent / "history.csv"

        result = self.run_script("--log", log, "--csv-out", out)

        self.assertEqual(result.returncode, 2)
        self.assertIn("expected exactly one BEGIN_SCHED_TRACE", result.stderr)

    def test_rejects_logs_without_execution_intervals(self) -> None:
        log = self.make_file(
            "serial.log",
            "\n".join(
                [
                    "BEGIN_SCHED_TRACE",
                    "0\t0\tWakeup\t1\t-\t-\t1\tfalse\t-\t-\tfalse\t-\t1000",
                    "END_SCHED_TRACE",
                    "BEGIN_TASK_TRACE",
                    "0\tSpawn\t1\t-\t-\t-\tPrioritizedFIFO\t31",
                    "END_TASK_TRACE",
                    "",
                ]
            ),
        )
        out = log.parent / "history.csv"

        result = self.run_script("--log", log, "--csv-out", out)

        self.assertEqual(result.returncode, 2)
        self.assertIn("no execution intervals", result.stderr)


if __name__ == "__main__":
    unittest.main()
