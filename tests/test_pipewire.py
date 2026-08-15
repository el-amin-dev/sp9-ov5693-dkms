"""Discovery tests.

These run in milliseconds with no camera attached, which is the point: every bug
in this area so far was found by a user running an install on real hardware, and
each one is expressible as a few lines of recorded JSON.
"""

from __future__ import annotations

import json
import pathlib
import sys
import unittest

sys.path.insert(0, str(pathlib.Path(__file__).resolve().parent.parent))

from surfacecam import config  # noqa: E402
from surfacecam.pipewire import Node, find_node, parse_nodes  # noqa: E402

FIXTURES = pathlib.Path(__file__).parent / "fixtures"

FRONT = config.by_key("front")
BACK = config.by_key("back")


def load(name: str):
    return json.loads((FIXTURES / name).read_text())


def node(**kw) -> Node:
    base = dict(serial="1", path="", location=None, model=None, state="running")
    base.update(kw)
    return Node(**base)


class TestParseNodes(unittest.TestCase):
    def test_keeps_only_libcamera_video_sources(self):
        nodes = parse_nodes(load("pw-dump-both-cameras.json"))
        assert len(nodes) == 2, "the raw ipu6 V4L2 node must not be treated as a camera"
        assert {n.model for n in nodes} == {"ov5693", "ov13858"}

    def test_ignores_unrelated_objects(self):
        assert parse_nodes([{"id": 1}, {"info": {}}, {"info": {"props": {}}}]) == []


class TestFindNode(unittest.TestCase):
    def test_matches_real_hardware_dump(self):
        nodes = parse_nodes(load("pw-dump-both-cameras.json"))
        assert find_node(nodes, FRONT).model == "ov5693"
        assert find_node(nodes, BACK).model == "ov13858"

    def test_finds_back_camera_when_location_is_missing(self):
        """The regression that made the back camera vanish after a reboot.

        libcamera reported no location for the rear sensor while reporting one
        for the front. Matching on location alone found nothing, and the bridge
        spent 120s insisting the camera was absent while it sat in the dump.
        """
        nodes = parse_nodes(load("pw-dump-both-cameras.json"))
        assert all(n.location != "back" for n in nodes), "fixture must keep the broken state"
        assert find_node(nodes, BACK) is not None

    def test_path_beats_a_conflicting_location(self):
        """A strong signal must win outright, not merely be tried first."""
        nodes = [
            node(serial="wrong", path="\\_SB_.PC00.I2C3.CAMF", location="back"),
            node(serial="right", path="\\_SB_.PC00.I2C2.CAMR", location="front"),
        ]
        assert find_node(nodes, BACK).serial == "right"
        assert find_node(nodes, FRONT).serial == "wrong"

    def test_falls_back_to_location_then_model(self):
        by_location = [node(serial="loc", path="/unknown", location="back")]
        assert find_node(by_location, BACK).serial == "loc"

        by_model = [node(serial="mod", path="/unknown", model="ov13858")]
        assert find_node(by_model, BACK).serial == "mod"

    def test_returns_none_when_absent(self):
        assert find_node([], BACK) is None
        assert find_node([node(path="/other", model="something-else")], BACK) is None

    def test_does_not_confuse_the_two_cameras(self):
        nodes = parse_nodes(load("pw-dump-both-cameras.json"))
        assert find_node(nodes, FRONT).serial != find_node(nodes, BACK).serial


class TestConfig(unittest.TestCase):
    def test_camera_keys_are_unique(self):
        keys = [c.key for c in config.CAMERAS]
        assert len(keys) == len(set(keys))

    def test_device_numbers_are_unique(self):
        numbers = [c.video_nr for c in config.CAMERAS]
        assert len(numbers) == len(set(numbers))

    def test_modprobe_options_cover_every_camera(self):
        options = config.modprobe_options()
        assert f"devices={len(config.CAMERAS)}" in options
        for camera in config.CAMERAS:
            assert str(camera.video_nr) in options
            assert camera.card_label in options
        assert "exclusive_caps=1" in options

    def test_capture_width_is_above_the_black_frame_threshold(self):
        """Capturing below this returns all-zero buffers and wedges the receiver."""
        assert config.CAPTURE_WIDTH >= config.SOFTISP_MIN_WIDTH

    def test_unknown_camera_is_rejected_clearly(self):
        try:
            config.by_key("sideways")
        except KeyError as exc:
            assert "sideways" in str(exc) and "front" in str(exc)
        else:
            raise AssertionError("expected KeyError")


if __name__ == "__main__":
    unittest.main(verbosity=2)
