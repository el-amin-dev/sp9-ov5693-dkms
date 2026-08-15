"""Tests for the on-demand policy and the pipeline description.

Both were previously buried inside a bash function, where the only way to observe
them was to watch a camera LED and hope.
"""

from __future__ import annotations

import pathlib
import sys
import unittest

sys.path.insert(0, str(pathlib.Path(__file__).resolve().parent.parent))

from surfacecam import config  # noqa: E402
from surfacecam.pipeline import describe, flip_method  # noqa: E402
from surfacecam.supervisor import Mode, decide  # noqa: E402

FRONT = config.by_key("front")
BACK = config.by_key("back")


class TestDecide(unittest.TestCase):
    def test_streams_while_a_consumer_is_present(self):
        d = decide(consumers=1, mode=Mode.IDLE, idle_for=0)
        assert d.mode is Mode.STREAMING

    def test_idle_when_nobody_is_watching(self):
        d = decide(consumers=0, mode=Mode.IDLE, idle_for=99)
        assert d.mode is Mode.IDLE

    def test_lingers_briefly_after_the_last_consumer_leaves(self):
        """Apps close and reopen the device while negotiating.

        Powering the sensor down in that gap makes the stream flap, so a short
        linger is deliberate rather than laziness about shutting down.
        """
        d = decide(consumers=0, mode=Mode.STREAMING, idle_for=1.0, linger=5.0)
        assert d.mode is Mode.STREAMING

    def test_stops_once_the_linger_expires(self):
        d = decide(consumers=0, mode=Mode.STREAMING, idle_for=5.1, linger=5.0)
        assert d.mode is Mode.IDLE

    def test_does_not_linger_when_already_idle(self):
        """Linger must not resurrect a camera that is already off."""
        d = decide(consumers=0, mode=Mode.IDLE, idle_for=0.0, linger=5.0)
        assert d.mode is Mode.IDLE

    def test_a_consumer_always_wins_over_linger(self):
        d = decide(consumers=2, mode=Mode.IDLE, idle_for=0.0)
        assert d.mode is Mode.STREAMING and "2 consumer" in d.reason


class TestFlipMethod(unittest.TestCase):
    def test_known_rotations(self):
        assert flip_method(0) == "none"
        assert flip_method(180) == "rotate-180"
        assert flip_method(90) == "clockwise"
        assert flip_method(270) == "counterclockwise"

    def test_normalises_full_turns(self):
        assert flip_method(360) == "none"

    def test_rejects_unsupported_rotation(self):
        with self.assertRaises(ValueError):
            flip_method(45)


class TestDescribe(unittest.TestCase):
    def test_captures_high_and_outputs_fixed(self):
        """The capture size must not follow the client.

        Below ~1296px wide this sensor returns black frames, and at 1280x720 it
        wedges the IPU6 receiver outright -- so the pipeline always captures
        1920x1080 and scales down.
        """
        desc = describe(FRONT, "123", "/dev/video42")
        assert f"width={config.CAPTURE_WIDTH},height={config.CAPTURE_HEIGHT}" in desc
        assert f"width={config.OUTPUT_WIDTH},height={config.OUTPUT_HEIGHT}" in desc

    def test_targets_the_requested_node_and_device(self):
        desc = describe(BACK, "999", "/dev/video43")
        assert "target-object=999" in desc
        assert "device=/dev/video43" in desc

    def test_applies_each_cameras_own_rotation(self):
        assert "method=none" in describe(FRONT, "1", "/dev/video42")
        assert "method=rotate-180" in describe(BACK, "1", "/dev/video43")

    def test_flips_before_scaling(self):
        """For 90/270 the other order would fix the wrong aspect ratio."""
        desc = describe(BACK, "1", "/dev/video43")
        assert desc.index("videoflip") < desc.index("videoscale")


if __name__ == "__main__":
    unittest.main(verbosity=2)
