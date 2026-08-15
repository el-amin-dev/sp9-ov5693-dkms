"""Deciding when the camera may actually run.

Holding the sensor open permanently keeps the privacy LED lit and the sensor
powered whether or not anyone is watching, which is a security problem before it
is a battery one: a light that is always on tells the user nothing.

The device must still look like a working camera at all times, or apps stop
listing it -- v4l2loopback 0.15.3 has no keep_format, so a device with no
producer reverts to "output" with no format. So the pipeline stays attached and
is parked in PAUSED, which keeps v4l2sink's claim on the device while
pipewiresrc stops pulling and the sensor powers down.

The policy is a pure function of (consumers, current state) and is unit tested as
such; the loop around it only supplies the I/O.
"""

from __future__ import annotations

import logging
import os
import time
from dataclasses import dataclass, field
from enum import Enum

from . import config, loopback, pipewire
from .config import Camera
from .pipeline import Pipeline, describe

log = logging.getLogger("surfacecam")

# How long to keep streaming after the last consumer disappears. Apps routinely
# close and immediately reopen the device while negotiating, and tearing the
# sensor down in that gap makes the stream flap.
LINGER_SECONDS = 5.0

# How often to look for consumers. fuser costs ~30ms, so this is cheap; it also
# bounds how long an app waits for its first frame.
POLL_SECONDS = 0.5

# A pipeline that dies this fast was never viable -- almost always a stale
# camera node left behind by a module reload.
EARLY_DEATH_SECONDS = 15.0


class Mode(Enum):
    STREAMING = "streaming"
    IDLE = "idle"


@dataclass(frozen=True)
class Decision:
    mode: Mode
    reason: str


def decide(
    *, consumers: int, mode: Mode, idle_for: float, linger: float = LINGER_SECONDS
) -> Decision:
    """Should the sensor be running?

    Pure on purpose: every rule here is a one-line test, where the same logic
    embedded in the polling loop would only be observable by watching an LED.
    """
    if consumers > 0:
        return Decision(Mode.STREAMING, f"{consumers} consumer(s)")
    if mode is Mode.STREAMING and idle_for < linger:
        return Decision(Mode.STREAMING, f"lingering {idle_for:.1f}s < {linger}s")
    return Decision(Mode.IDLE, "no consumers")


@dataclass
class Supervisor:
    """Runs one camera's bridge for as long as the service lives."""

    camera: Camera
    on_stale_node: object = None
    """Called when the pipeline dies immediately, to re-enumerate PipeWire.

    Injected rather than called directly so the recovery path is testable without
    restarting the user's audio stack.
    """

    _mode: Mode = Mode.IDLE
    _idle_since: float = field(default_factory=time.monotonic)

    def run(self) -> int:
        device = loopback.find_device(self.camera)
        if device is None:
            log.error(
                "no loopback device labelled %r; is v4l2loopback loaded?",
                self.camera.card_label,
            )
            return 1

        node = self._wait_for_node()
        if node is None:
            return 1

        pipeline = Pipeline(describe(self.camera, node.serial, device))
        started = time.monotonic()
        pipeline.start()

        # A node can exist and still be dead: reloading the sensor module leaves
        # WirePlumber advertising nodes whose cameras are gone, and the first
        # format request on one fails with EINVAL. Nothing about the node itself
        # reveals this, so an immediate death is the signal.
        error = pipeline.failed()
        if error and time.monotonic() - started < EARLY_DEATH_SECONDS:
            log.warning("pipeline failed immediately (%s); camera node looks stale", error)
            pipeline.stop()
            if callable(self.on_stale_node):
                self.on_stale_node()
            return 1

        log.info(
            "bridging %s -> %s (node %s, rotate %d deg)",
            self.camera.key, device, node.serial, self.camera.rotation,
        )
        self._mode = Mode.STREAMING
        if not config.ON_DEMAND:
            # Stream continuously. See config.ON_DEMAND for why this is the
            # default: pausing while idle currently starves consumers entirely.
            log.info("streaming continuously (on-demand disabled)")
            try:
                self._await_failure(pipeline)
            finally:
                pipeline.stop()
            return 0

        self._enter(Mode.IDLE, pipeline, "startup: nothing watching yet")
        try:
            self._loop(pipeline, device)
        finally:
            pipeline.stop()
        return 0

    def _await_failure(self, pipeline: Pipeline) -> None:
        """Block until the pipeline posts an error, so systemd can restart us."""
        while True:
            error = pipeline.failed()
            if error:
                log.error("pipeline error: %s", error)
                return
            time.sleep(2)

    def _loop(self, pipeline: Pipeline, device: str) -> None:
        own = frozenset({os.getpid()})
        while True:
            watchers = loopback.consumers(device, ignore_pids=own)
            idle_for = time.monotonic() - self._idle_since
            decision = decide(consumers=len(watchers), mode=self._mode, idle_for=idle_for)
            self._enter(decision.mode, pipeline, decision.reason)

            error = pipeline.failed()
            if error:
                log.error("pipeline error: %s", error)
                return
            time.sleep(POLL_SECONDS)

    def _enter(self, mode: Mode, pipeline: Pipeline, reason: str) -> None:
        if mode is self._mode:
            return
        if mode is Mode.STREAMING:
            log.info("camera on (%s)", reason)
            pipeline.play()
        else:
            log.info("camera off (%s)", reason)
            pipeline.pause()
            self._idle_since = time.monotonic()
        self._mode = mode

    def _wait_for_node(self, timeout: float = 120.0):
        """Wait for the camera's PipeWire node, nudging WirePlumber once.

        At boot WirePlumber enumerates libcamera exactly once, and if it runs
        before the sensor drivers are ready it finds nothing and never looks
        again -- so the node never appears on its own.
        """
        deadline = time.monotonic() + timeout
        nudged = False
        while time.monotonic() < deadline:
            node = pipewire.current_node(self.camera)
            if node is not None:
                return node
            if not nudged and callable(self.on_stale_node):
                log.warning("no %s camera node yet; re-enumerating", self.camera.key)
                self.on_stale_node()
                nudged = True
            time.sleep(3)
        log.error("no %s camera node after %.0fs", self.camera.key, timeout)
        return None
