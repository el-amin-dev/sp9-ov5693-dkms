"""The GStreamer pipeline that copies a camera into its loopback device.

Kept deliberately dumb: it builds a pipeline and moves it between states. It does
not decide *when* to do that -- that is the supervisor's job -- so the pipeline
description can be unit tested as a string without GStreamer or a camera present.
"""

from __future__ import annotations

from dataclasses import dataclass

from . import config
from .config import Camera

# Clockwise degrees -> videoflip method.
FLIP_METHODS = {0: "none", 90: "clockwise", 180: "rotate-180", 270: "counterclockwise"}


def flip_method(rotation: int) -> str:
    try:
        return FLIP_METHODS[rotation % 360]
    except KeyError:
        raise ValueError(
            f"unsupported rotation {rotation}; use one of {sorted(FLIP_METHODS)}"
        ) from None


def describe(camera: Camera, serial: str, device: str) -> str:
    """The gst-launch description for one camera.

    Capture size is fixed by config rather than following the client, because
    this sensor returns black below ~1296px wide and wedges the receiver at
    1280x720. The single fixed output caps is what stops a client negotiating its
    way into one of those modes.

    videoflip sits before videoscale: at 180 the dimensions are unchanged either
    way, but for 90/270 scaling first would fix the wrong aspect.
    """
    return (
        f"pipewiresrc target-object={serial} always-copy=true"
        f" ! video/x-raw,width={config.CAPTURE_WIDTH},height={config.CAPTURE_HEIGHT}"
        f" ! videoconvert ! videoflip method={flip_method(camera.rotation)} ! videoscale"
        f" ! video/x-raw,format={config.OUTPUT_FORMAT}"
        f",width={config.OUTPUT_WIDTH},height={config.OUTPUT_HEIGHT}"
        f" ! v4l2sink device={device} sync=false"
    )


@dataclass
class Pipeline:
    """Owns a GStreamer pipeline and its state transitions.

    GStreamer is imported lazily so that describe() and the rest of the package
    stay importable -- and testable -- on a machine with no GStreamer bindings.
    """

    description: str
    _pipeline: object | None = None

    def start(self) -> None:
        import gi

        gi.require_version("Gst", "1.0")
        from gi.repository import Gst

        Gst.init(None)
        self._pipeline = Gst.parse_launch(self.description)
        self._set("PLAYING")

    def _set(self, state_name: str) -> None:
        from gi.repository import Gst

        assert self._pipeline is not None
        self._pipeline.set_state(getattr(Gst.State, state_name))
        # Block until the transition settles, so callers never act on a state the
        # pipeline has not actually reached yet.
        self._pipeline.get_state(5 * Gst.SECOND)

    def play(self) -> None:
        """Stream from the sensor. The privacy LED lights during this."""
        self._set("PLAYING")

    def pause(self) -> None:
        """Stop pulling frames while keeping the loopback device claimed.

        v4l2sink holds the device open with its format set, so apps still see a
        usable camera, while pipewiresrc stops pulling and the sensor powers
        down. That combination is the entire point: a camera that is only on when
        something is actually watching.
        """
        self._set("PAUSED")

    def stop(self) -> None:
        if self._pipeline is not None:
            self._set("NULL")
            self._pipeline = None

    def failed(self) -> str | None:
        """Return the first error on the bus, if the pipeline has posted one."""
        if self._pipeline is None:
            return None
        from gi.repository import Gst

        bus = self._pipeline.get_bus()
        message = bus.poll(Gst.MessageType.ERROR, 0)
        if message is None:
            return None
        error, _debug = message.parse_error()
        return error.message
