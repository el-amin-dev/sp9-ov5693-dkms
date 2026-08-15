"""Single source of truth for the camera setup.

Every other module -- and the shell scripts, via `python3 -m surfacecam.config` --
reads its facts from here. Nothing about a camera is written down twice.

That is not tidiness for its own sake: card labels used to live in four files,
the camera list in three and the device numbers in two, and every bug where the
installer and the bridge disagreed about what existed came from one of those
copies drifting out of step.
"""

from __future__ import annotations

from dataclasses import dataclass

# Capture size, fixed regardless of what a client asks for.
#
# The front sensor's software ISP returns all-zero buffers below roughly 1296px
# wide, and at 1280x720 it does worse than that: the IPU6 receiver logs
# "stream stop time out" and stays wedged. So capture is pinned high and scaled
# down for clients, never the other way round.
CAPTURE_WIDTH = 1920
CAPTURE_HEIGHT = 1080

# What clients are offered. One mode, so nothing can negotiate its way into a
# resolution the sensor cannot actually deliver.
OUTPUT_WIDTH = 1280
OUTPUT_HEIGHT = 720
OUTPUT_FRAMERATE = 30
OUTPUT_FORMAT = "YUY2"

# Below this width the software ISP yields black frames; used by the tests to
# decide what is a real failure and what is a known-unsupported mode.
SOFTISP_MIN_WIDTH = 1296

# Suspend the sensor while no app has the loopback open.
#
# OFF by default because it does not yet work: the supervisor correctly notices a
# consumer and returns the pipeline to PLAYING, but the consumer then receives no
# frames at all -- measured with a 40s capture that produced zero images and no
# error. Parking in PAUSED is evidently not something v4l2sink and v4l2loopback
# resume from cleanly once a consumer has already opened the device.
#
# Leaving this on would trade a working camera for a privacy LED, which is the
# wrong trade. It stays in the code, off, because the goal is right: an
# always-lit LED tells the user nothing about whether they are being recorded.
ON_DEMAND = False


@dataclass(frozen=True)
class Camera:
    """One physical camera and the loopback device that publishes it."""

    key: str
    """Short name used on the command line and as the systemd instance."""

    acpi_suffix: str
    """Tail of api.libcamera.path, e.g. CAMF. The primary identity.

    Not api.libcamera.location: that property is not reliably populated. After
    one reboot the front camera reported "front" and the back reported nothing
    at all, and a location-only match lost the back camera entirely.
    """

    model: str
    """Sensor model, as device.product.name. Last-resort identity."""

    location: str
    """Value api.libcamera.location carries when it is populated."""

    video_nr: int
    """Fixed /dev/videoN number for this camera's loopback device."""

    card_label: str
    """Card name apps display. The contract between setup and the bridge."""

    rotation: int
    """Clockwise degrees to rotate, applied by the bridge.

    Measured, not derived from api.libcamera.rotation, which does not describe
    what leaves the pipeline: the front sensor reports 180 and libcamera already
    compensates, while the back reports 0 and is physically mounted upside down.
    Acting on that property would flip the one that is correct and leave the
    other wrong.
    """

    @property
    def device(self) -> str:
        return f"/dev/video{self.video_nr}"

    @property
    def service(self) -> str:
        return f"camera-bridge@{self.key}"


CAMERAS: tuple[Camera, ...] = (
    Camera(
        key="front",
        acpi_suffix="CAMF",
        model="ov5693",
        location="front",
        video_nr=42,
        card_label="Surface Front Camera",
        rotation=0,
    ),
    Camera(
        key="back",
        acpi_suffix="CAMR",
        model="ov13858",
        location="back",
        video_nr=43,
        card_label="Surface Back Camera",
        rotation=180,
    ),
)


def by_key(key: str) -> Camera:
    for camera in CAMERAS:
        if camera.key == key:
            return camera
    known = ", ".join(c.key for c in CAMERAS)
    raise KeyError(f"unknown camera {key!r} (known: {known})")


def modprobe_options() -> str:
    """Arguments for loading v4l2loopback with one device per camera.

    exclusive_caps=1 is what makes browsers treat these as capture devices
    rather than outputs; without it they skip them entirely.
    """
    numbers = ",".join(str(c.video_nr) for c in CAMERAS)
    labels = ",".join(c.card_label for c in CAMERAS)
    return (
        f'devices={len(CAMERAS)} video_nr={numbers} '
        f'card_label="{labels}" exclusive_caps=1'
    )


def _main() -> None:
    """Expose the config to shell, so scripts never hardcode a second copy."""
    import argparse

    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "what",
        choices=["keys", "labels", "devices", "modprobe-options", "services"],
    )
    args = parser.parse_args()

    if args.what == "keys":
        print(" ".join(c.key for c in CAMERAS))
    elif args.what == "labels":
        print("\n".join(c.card_label for c in CAMERAS))
    elif args.what == "devices":
        print("\n".join(c.device for c in CAMERAS))
    elif args.what == "services":
        print(" ".join(c.service for c in CAMERAS))
    else:
        print(modprobe_options())


if __name__ == "__main__":
    _main()
