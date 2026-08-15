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
from .nudge import Nudger
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

# A pipeline that dies this fast was never viable -- almost always a stale camera
# node left behind by a module reload, which fails a few seconds in rather than
# instantly, so this is a window to watch and not a single check.
EARLY_DEATH_SECONDS = 15.0

# Grace before concluding a missing node means WirePlumber is stale rather than
# the camera stack still coming up. At boot everything is slow.
NODE_GRACE_SECONDS = 15.0


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
    _nudger: Nudger | None = None
    """Rate-limited WirePlumber restart.

    Injected rather than called directly so the recovery path is testable without
    tearing down the developer's audio, and shared across both camera instances
    through a lock so they cannot restart it on top of each other.
    """

    _mode: Mode = Mode.IDLE
    _last_consumer_at: float = field(default_factory=time.monotonic)

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
        pipeline.start()

        # A node can exist and still be dead: reloading the sensor module leaves
        # WirePlumber advertising nodes whose cameras are gone, and the first
        # format request on one fails with EINVAL a second or two in. So watch
        # the whole early window rather than checking once and moving on -- the
        # single check this replaced could only ever catch a failure that had
        # already happened before start() returned.
        error = pipeline.wait_for_end(EARLY_DEATH_SECONDS)
        if error:
            log.warning("pipeline died within %.0fs (%s); camera node looks stale",
                        EARLY_DEATH_SECONDS, error)
            pipeline.stop()
            self._nudge("pipeline failed straight after starting")
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
                error = pipeline.wait_for_end(timeout=float("inf"))
            finally:
                pipeline.stop()
            log.error("pipeline ended: %s", error)
            return 1  # non-zero so Restart=always actually means something

        self._enter(Mode.IDLE, pipeline, "startup: nothing watching yet")
        try:
            return self._loop(pipeline, device)
        finally:
            pipeline.stop()

    def _loop(self, pipeline: Pipeline, device: str) -> int:
        own = frozenset({os.getpid()})
        while True:
            watchers = loopback.consumers(device, ignore_pids=own)
            # Measured from when the last consumer left, not from when we last
            # paused: the linger exists to cover an app closing and immediately
            # reopening, and timing it from the pause made it always expired.
            if watchers:
                self._last_consumer_at = time.monotonic()
            idle_for = time.monotonic() - self._last_consumer_at
            decision = decide(consumers=len(watchers), mode=self._mode, idle_for=idle_for)
            self._enter(decision.mode, pipeline, decision.reason)

            error = pipeline.wait_for_end(POLL_SECONDS)
            if error:
                log.error("pipeline ended: %s", error)
                return 1

    def _enter(self, mode: Mode, pipeline: Pipeline, reason: str) -> None:
        if mode is self._mode:
            return
        if mode is Mode.STREAMING:
            log.info("camera on (%s)", reason)
            pipeline.play()
        else:
            log.info("camera off (%s)", reason)
            pipeline.pause()
        self._mode = mode

    def _nudge(self, reason: str) -> bool:
        """Ask for a re-enumeration, subject to the Nudger's guards."""
        if self._nudger is None:
            return False
        return self._nudger.nudge(reason)

    def _wait_for_node(self, timeout: float = 120.0):
        """Wait for the camera's PipeWire node, nudging WirePlumber once.

        At boot WirePlumber enumerates libcamera exactly once, and if it runs
        before the sensor drivers are ready it finds nothing and never looks
        again -- so the node never appears on its own.
        """
        began = time.monotonic()
        deadline = began + timeout
        nudged = False
        while time.monotonic() < deadline:
            node = pipewire.current_node(self.camera)
            if node is not None:
                return node
            # Grace first: at boot the camera stack is simply slow, and a restart
            # then would be both useless and disruptive.
            if not nudged and time.monotonic() - began > NODE_GRACE_SECONDS:
                nudged = self._nudge(f"no {self.camera.key} camera node")
            time.sleep(3)
        log.error("no %s camera node after %.0fs", self.camera.key, timeout)
        return None
