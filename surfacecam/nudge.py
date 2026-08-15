"""Asking WirePlumber to re-enumerate libcamera, without doing it constantly.

WirePlumber enumerates libcamera exactly once, at startup. If it ran before the
sensor drivers were ready, or if a module reload invalidated the cameras behind
its back, the only way to get usable nodes is to restart it -- which also drops
every audio stream on the machine. So it must happen when genuinely needed, and
at most once in a while.

Three guards, all of which the bash implementation had and the first Python port
dropped:

* a grace period, so a camera stack that is merely slow to appear is given time
  rather than answered with a restart;
* a precondition that the sensors are actually bound, so "drivers not up yet" is
  never mistaken for "WirePlumber is stale";
* a lock and a timestamp shared across processes, because both camera instances
  start together and would otherwise restart WirePlumber simultaneously -- each
  one aborting the enumeration the other just triggered.
"""

from __future__ import annotations

import logging
import os
import pathlib
import time
from dataclasses import dataclass, field
from typing import Callable

log = logging.getLogger("surfacecam")

RUNTIME_DIR = pathlib.Path(os.environ.get("XDG_RUNTIME_DIR", "/tmp"))
DEFAULT_LOCK = RUNTIME_DIR / "surfacecam-nudge.lock"
DEFAULT_STAMP = RUNTIME_DIR / "surfacecam-nudge.stamp"

# Minimum gap between restarts, machine-wide. Generous on purpose: with
# Restart=always a genuinely broken camera retries every few seconds, and without
# this the user's audio would be torn down on every one of those cycles.
MIN_INTERVAL_SECONDS = 120.0

# A lock older than this is assumed to be from a process that died mid-restart.
LOCK_STALE_SECONDS = 120.0


def sensors_bound(root: pathlib.Path | None = None) -> bool:
    """Is at least one camera sensor bound to its driver?

    Read from sysfs rather than by asking libcamera: `cam -l` blocks while
    another process is streaming and ignores SIGTERM while blocked, which once
    wedged the bridge for six minutes inside a `timeout` that could not fire.
    """
    base = root or pathlib.Path("/sys/bus/i2c/drivers")
    try:
        # next(...) rather than any(glob): a generator is always truthy, so
        # any(driver.glob(...)) reports success for a driver with nothing bound.
        return any(
            next(driver.glob("*:*"), None) is not None for driver in base.glob("ov*")
        )
    except OSError:
        return False


@dataclass
class Nudger:
    """Rate-limited, cross-process trigger for a WirePlumber restart."""

    action: Callable[[], None]
    lock: pathlib.Path = DEFAULT_LOCK
    stamp: pathlib.Path = DEFAULT_STAMP
    min_interval: float = MIN_INTERVAL_SECONDS
    require_sensors: bool = True
    _clock: Callable[[], float] = field(default=time.time)

    # Timestamps live in file contents rather than in mtimes so that every
    # comparison goes through the injected clock. Mixing the two made the
    # staleness rules untestable without sleeping in real time.
    def _read_time(self, path: pathlib.Path) -> float | None:
        try:
            return float(path.read_text().strip())
        except (OSError, ValueError):
            return None

    def _write_time(self, path: pathlib.Path) -> None:
        try:
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_text(f"{self._clock()}\n")
        except OSError:
            pass  # losing the stamp costs an extra restart, not correctness

    def _too_soon(self) -> bool:
        last = self._read_time(self.stamp)
        return last is not None and (self._clock() - last) < self.min_interval

    def _claim(self) -> bool:
        """Take the cross-process lock, clearing one left by a dead process.

        Staleness is judged from the directory's own mtime and real time, not the
        injected clock: the lock is a fact about other processes on this machine,
        so it has to be measured the same way they set it. Only the rate-limit
        policy above uses the injectable clock.
        """
        try:
            os.mkdir(self.lock)
            return True
        except FileExistsError:
            pass
        except OSError:
            return False

        try:
            age = time.time() - self.lock.stat().st_mtime
        except OSError:
            return False
        if age <= LOCK_STALE_SECONDS:
            return False  # somebody is genuinely holding it
        try:
            os.rmdir(self.lock)
            os.mkdir(self.lock)
            return True
        except OSError:
            return False  # lost the race to break it; let the winner proceed

    def _release(self) -> None:
        try:
            os.rmdir(self.lock)
        except OSError:
            pass

    def nudge(self, reason: str) -> bool:
        """Restart WirePlumber if all three guards allow it. True if it ran."""
        if self.require_sensors and not sensors_bound():
            log.debug("not nudging (%s): no sensor bound yet", reason)
            return False
        if self._too_soon():
            log.debug("not nudging (%s): too soon since the last one", reason)
            return False
        if not self._claim():
            log.debug("not nudging (%s): another instance is doing it", reason)
            return False
        try:
            log.warning("re-enumerating cameras: %s", reason)
            self.action()
            self._write_time(self.stamp)
            return True
        finally:
            self._release()
