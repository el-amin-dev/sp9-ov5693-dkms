"""Command line entry point.

Thin by design: it parses arguments, wires the pieces together and gets out of
the way. Anything with a decision in it belongs in a module that can be tested
without a camera.
"""

from __future__ import annotations

import argparse
import logging
import subprocess
import sys

from . import config, loopback, pipewire
from .supervisor import Supervisor


def restart_wireplumber() -> None:
    """Force WirePlumber to re-enumerate libcamera.

    It only enumerates at startup, so a camera that appears later -- or one whose
    node was invalidated by a module reload -- needs this to be noticed at all.
    """
    subprocess.run(
        ["systemctl", "--user", "restart", "wireplumber"],
        check=False,
        capture_output=True,
    )
    import time

    time.sleep(6)


def cmd_run(args) -> int:
    camera = config.by_key(args.camera)
    return Supervisor(camera=camera, on_stale_node=restart_wireplumber).run()


def cmd_status(_args) -> int:
    nodes = pipewire.parse_nodes(pipewire.dump())
    print(f"v4l2loopback: {'loaded' if loopback.module_loaded() else 'NOT LOADED'}")
    worst = 0
    for camera in config.CAMERAS:
        device = loopback.find_device(camera)
        node = pipewire.find_node(nodes, camera)
        if device is None:
            print(f"  {camera.key:<6} device=missing")
            worst = 1
            continue
        state = loopback.device_state(device)
        watchers = loopback.consumers(device)
        print(
            f"  {camera.key:<6} device={device} "
            f"state={state.state} format={state.fmt or '-'} "
            f"node={node.serial if node else 'MISSING'} "
            f"watchers={len(watchers)}"
        )
        if node is None or not state.is_ready:
            worst = 1
    return worst


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(prog="surfacecam", description=__doc__)
    parser.add_argument(
        "-v", "--verbose", action="store_true", help="log every state change"
    )
    sub = parser.add_subparsers(dest="command", required=True)

    run = sub.add_parser("run", help="bridge one camera (foreground, for systemd)")
    run.add_argument("camera", choices=[c.key for c in config.CAMERAS])
    run.set_defaults(func=cmd_run)

    status = sub.add_parser("status", help="report both cameras")
    status.set_defaults(func=cmd_status)

    args = parser.parse_args(argv)
    logging.basicConfig(
        level=logging.DEBUG if args.verbose else logging.INFO,
        format="%(levelname)s %(message)s",
    )
    try:
        return args.func(args)
    except KeyboardInterrupt:
        return 0


if __name__ == "__main__":
    sys.exit(main())
