#!/usr/bin/env python3
"""Does PAUSED actually stop the sensor?

The bridge holds the camera open permanently so the loopback stays a valid
capture device, which leaves the privacy LED lit and the sensor powered at all
times. The proposed fix keeps v4l2sink attached but parks the pipeline in PAUSED
while nothing is watching. That only works if PAUSED really tears the sensor
stream down, so measure it before building anything on top.

Prints the PipeWire node state and the loopback's own state/format at each step:
a working pause shows the camera node leaving "running" while the loopback keeps
its format, meaning apps still see a usable device.
"""

import json
import pathlib
import subprocess
import sys
import time

import gi

gi.require_version("Gst", "1.0")
from gi.repository import Gst  # noqa: E402


def node_state(serial):
    out = subprocess.run(["pw-dump"], capture_output=True, text=True).stdout
    for obj in json.loads(out):
        info = obj.get("info") or {}
        props = info.get("props") or {}
        if str(props.get("object.serial")) == str(serial):
            return info.get("state")
    return "gone"


def loopback(dev_index):
    base = pathlib.Path(f"/sys/class/video4linux/video{dev_index}")
    try:
        return base.joinpath("state").read_text().strip(), base.joinpath("format").read_text().strip()
    except OSError:
        return "?", "?"


def report(label, serial, dev_index):
    state = node_state(serial)
    lb_state, lb_format = loopback(dev_index)
    print(f"  {label:<22} camera-node={state:<10} loopback={lb_state:<8} format={lb_format or '(none)'}")


def main():
    serial, dev_index = sys.argv[1], sys.argv[2]
    Gst.init(None)

    desc = (
        f"pipewiresrc target-object={serial} always-copy=true "
        "! video/x-raw,width=1920,height=1080 "
        "! videoconvert ! videoscale "
        "! video/x-raw,format=YUY2,width=1280,height=720 "
        f"! v4l2sink device=/dev/video{dev_index} sync=false"
    )
    pipeline = Gst.parse_launch(desc)

    print("PLAYING for 8s (sensor should be on, LED lit)")
    pipeline.set_state(Gst.State.PLAYING)
    pipeline.get_state(Gst.CLOCK_TIME_NONE)
    time.sleep(8)
    report("while PLAYING", serial, dev_index)

    print("PAUSED for 20s (does the sensor stop? does the device stay usable?)")
    pipeline.set_state(Gst.State.PAUSED)
    pipeline.get_state(Gst.CLOCK_TIME_NONE)
    for i in (3, 10, 20):
        time.sleep(3 if i == 3 else 7 if i == 10 else 10)
        report(f"paused +{i}s", serial, dev_index)

    print("back to PLAYING for 6s")
    pipeline.set_state(Gst.State.PLAYING)
    pipeline.get_state(Gst.CLOCK_TIME_NONE)
    time.sleep(6)
    report("resumed", serial, dev_index)

    pipeline.set_state(Gst.State.NULL)


if __name__ == "__main__":
    main()
