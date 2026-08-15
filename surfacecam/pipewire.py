"""Finding a camera's PipeWire node.

Split into a pure part and an I/O part on purpose. `find_node` takes already
parsed `pw-dump` output and returns a result, with no subprocess and no clock, so
every awkward real-world state -- a node with no location, two nodes for one
sensor, a stale node left by a module reload -- is a unit test over a recorded
fixture rather than something only reproducible on hardware after a reboot.
"""

from __future__ import annotations

import json
import subprocess
from dataclasses import dataclass
from typing import Any, Callable, Iterable, Sequence

from .config import Camera

Props = dict[str, Any]


@dataclass(frozen=True)
class Node:
    """A PipeWire Video/Source node backed by libcamera."""

    serial: str
    path: str
    location: str | None
    model: str | None
    state: str | None

    @property
    def sort_key(self) -> int:
        """Higher means more recently created.

        PipeWire hands out object serials in increasing order, so when a module
        reload leaves an invalidated node advertised alongside its replacement --
        same ACPI path, same model, one of them dead -- the newer serial is the
        live one. Without this the winner was whichever the dump happened to list
        first, and binding to the dead one fails with EINVAL.
        """
        try:
            return int(self.serial)
        except ValueError:
            return -1


def parse_nodes(dump: Iterable[dict[str, Any]]) -> list[Node]:
    """Extract the libcamera camera nodes from `pw-dump` output.

    Everything else in the dump -- ports, links, the raw ipu6 V4L2 nodes that
    apps must never be pointed at -- is discarded here, so callers cannot
    accidentally match one.
    """
    nodes: list[Node] = []
    for obj in dump:
        info = obj.get("info") or {}
        props = info.get("props") or {}
        if props.get("media.class") != "Video/Source":
            continue
        if props.get("device.api") != "libcamera":
            continue
        nodes.append(
            Node(
                serial=str(props.get("object.serial", "")),
                path=str(props.get("api.libcamera.path", "")),
                location=props.get("api.libcamera.location"),
                model=props.get("device.product.name"),
                state=info.get("state"),
            )
        )
    return nodes


def find_node(nodes: Sequence[Node], camera: Camera) -> Node | None:
    """Identify a camera's node, strongest signal first.

    Each strategy is tried against every node before the next is considered, so a
    weak signal can never win while a strong one is available. Order matters:
    the ACPI path comes from firmware and has been stable across every boot,
    whereas location has been observed empty for a camera that was present and
    working, which is what made the back camera disappear.
    """
    strategies: tuple[Callable[[Node], bool], ...] = (
        lambda n: bool(camera.acpi_suffix) and n.path.endswith(camera.acpi_suffix),
        lambda n: n.location == camera.location,
        lambda n: n.model == camera.model,
    )
    for matches in strategies:
        candidates = [node for node in nodes if matches(node)]
        if candidates:
            # Newest wins: a reload can leave a dead node beside the live one.
            return max(candidates, key=lambda node: node.sort_key)
    return None


def dump() -> list[dict[str, Any]]:
    """Run `pw-dump`, returning [] rather than raising if PipeWire is not up yet.

    Callers poll this while the session is still starting, so an empty result is
    an ordinary "not yet", not an error.
    """
    try:
        completed = subprocess.run(
            ["pw-dump"], capture_output=True, text=True, timeout=15, check=False
        )
    except (OSError, subprocess.TimeoutExpired):
        return []
    if completed.returncode != 0:
        return []
    try:
        return json.loads(completed.stdout)
    except json.JSONDecodeError:
        return []


def current_node(camera: Camera) -> Node | None:
    """Convenience wrapper: dump, parse, match."""
    return find_node(parse_nodes(dump()), camera)
