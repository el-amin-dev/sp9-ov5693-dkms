"""The v4l2loopback devices that publish the cameras to ordinary apps.

Reads sysfs rather than shelling out to v4l2-ctl. That is not only faster -- it
matters because the supervisor polls this while deciding whether the sensor may
be switched off, and a poll that costs a process spawn each time is a poll that
gets made too rarely to be responsive.
"""

from __future__ import annotations

import pathlib
import subprocess
from dataclasses import dataclass

from .config import Camera

SYSFS = pathlib.Path("/sys/class/video4linux")
MODULE = pathlib.Path("/sys/module/v4l2loopback")


@dataclass(frozen=True)
class DeviceState:
    """What the loopback currently is, from the kernel's point of view."""

    path: str
    state: str
    """"capture" once a producer has attached and set a format, else "output".

    This is the whole reason the bridge holds the camera open: with no producer
    the device reverts to "output" with no format, and apps either skip it or
    show a blank picture.
    """
    fmt: str

    @property
    def is_ready(self) -> bool:
        return self.state == "capture" and bool(self.fmt)


def module_loaded() -> bool:
    return MODULE.exists()


def _read(node: pathlib.Path, name: str) -> str:
    try:
        return node.joinpath(name).read_text().strip()
    except OSError:
        return ""


def find_device(camera: Camera) -> str | None:
    """Locate the loopback carrying this camera's card label.

    Matched on the label rather than trusting the configured video_nr: the number
    is only a request to modprobe, and an already-loaded module with different
    options would silently hand out different ones.
    """
    if not SYSFS.exists():
        return None
    for node in sorted(SYSFS.iterdir()):
        if _read(node, "name") == camera.card_label:
            return f"/dev/{node.name}"
    return None


def device_state(device: str) -> DeviceState:
    node = SYSFS / pathlib.Path(device).name
    return DeviceState(path=device, state=_read(node, "state"), fmt=_read(node, "format"))


def consumers(device: str, ignore_pids: frozenset[int] = frozenset()) -> set[int]:
    """PIDs with the device open, excluding our own producer.

    fuser is used rather than walking /proc/*/fd: the walk takes over a second on
    this machine, which is far too slow to poll, while fuser costs about 30ms.
    """
    try:
        completed = subprocess.run(
            ["fuser", device], capture_output=True, text=True, timeout=5, check=False
        )
    except (OSError, subprocess.TimeoutExpired):
        return set()

    found = set()
    for token in completed.stdout.split():
        try:
            found.add(int(token))
        except ValueError:
            continue  # fuser annotates pids with access-mode letters
    return found - set(ignore_pids)
