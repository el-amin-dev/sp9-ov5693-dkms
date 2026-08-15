"""Tests for the WirePlumber re-enumeration guards.

Every one of these covers a guard that existed in the bash implementation, was
silently dropped in the Python port, and was caught in review rather than by a
test. Restarting WirePlumber drops every audio stream on the machine, so "how
often may this happen" is a correctness question, not a tuning one.
"""

from __future__ import annotations

import pathlib
import sys
import tempfile
import unittest

sys.path.insert(0, str(pathlib.Path(__file__).resolve().parent.parent))

from surfacecam.nudge import Nudger, sensors_bound  # noqa: E402


class FakeClock:
    def __init__(self, now: float = 1000.0):
        self.now = now

    def __call__(self) -> float:
        return self.now

    def advance(self, seconds: float) -> None:
        self.now += seconds


class NudgerTest(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        root = pathlib.Path(self.tmp.name)
        self.lock = root / "lock"
        self.stamp = root / "stamp"
        self.calls: list[str] = []
        self.clock = FakeClock()

    def tearDown(self):
        self.tmp.cleanup()

    def make(self, **kw) -> Nudger:
        return Nudger(
            action=lambda: self.calls.append("restart"),
            lock=self.lock,
            stamp=self.stamp,
            require_sensors=False,
            _clock=self.clock,
            **kw,
        )

    def test_first_nudge_runs(self):
        assert self.make().nudge("first") is True
        assert self.calls == ["restart"]

    def test_second_nudge_is_rate_limited(self):
        """A broken camera restarts every few seconds under Restart=always.

        Without this, each of those cycles would tear down the user's audio.
        """
        nudger = self.make(min_interval=120.0)
        assert nudger.nudge("first") is True
        self.clock.advance(10)
        assert nudger.nudge("again") is False
        assert self.calls == ["restart"]

    def test_nudging_resumes_once_the_interval_passes(self):
        nudger = self.make(min_interval=120.0)
        nudger.nudge("first")
        self.clock.advance(121)
        assert nudger.nudge("later") is True
        assert len(self.calls) == 2

    def test_only_one_instance_nudges_at_a_time(self):
        """Both camera services start together and both find no node.

        They must not restart WirePlumber simultaneously: the second restart
        aborts the enumeration the first one just triggered.
        """
        self.lock.mkdir()  # another instance holds it
        assert self.make().nudge("contended") is False
        assert self.calls == []

    def test_a_lock_left_by_a_dead_process_is_broken(self):
        """Lock staleness is judged in real time, since other processes set it."""
        import os
        import time

        self.lock.mkdir()
        old = time.time() - 10_000
        os.utime(self.lock, (old, old))
        assert self.make().nudge("stale lock") is True

    def test_the_lock_is_released_afterwards(self):
        self.make().nudge("first")
        assert not self.lock.exists(), "a held lock would block every later nudge"

    def test_the_lock_is_released_even_if_the_restart_raises(self):
        def boom():
            raise RuntimeError("systemctl failed")

        nudger = Nudger(
            action=boom, lock=self.lock, stamp=self.stamp,
            require_sensors=False, _clock=self.clock,
        )
        with self.assertRaises(RuntimeError):
            nudger.nudge("failing")
        assert not self.lock.exists()

    def test_does_not_nudge_when_no_sensor_is_bound(self):
        """No sensor bound means the drivers are not up, which a restart cannot fix."""
        nudger = Nudger(
            action=lambda: self.calls.append("restart"),
            lock=self.lock, stamp=self.stamp,
            require_sensors=True, _clock=self.clock,
        )
        # No real ov* driver dir is guaranteed in the test environment; assert on
        # the observable rule instead of the machine's state.
        if sensors_bound():
            self.skipTest("this machine has a bound sensor")
        assert nudger.nudge("drivers down") is False
        assert self.calls == []


class SensorsBoundTest(unittest.TestCase):
    def test_reports_false_for_a_missing_sysfs_tree(self):
        assert sensors_bound(pathlib.Path("/nonexistent/i2c/drivers")) is False

    def test_finds_a_bound_sensor(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = pathlib.Path(tmp)
            (root / "ov5693" / "i2c-OVTI5693:00").mkdir(parents=True)
            assert sensors_bound(root) is True

    def test_a_driver_with_nothing_bound_does_not_count(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = pathlib.Path(tmp)
            (root / "ov5693").mkdir()
            assert sensors_bound(root) is False


if __name__ == "__main__":
    unittest.main(verbosity=2)
