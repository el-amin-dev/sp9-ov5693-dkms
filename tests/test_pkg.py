"""Tests for distro detection and the package list behind ``install.sh``.

The installer used to assume Ubuntu. Now it has to pick a package manager and
package names for each distro family, and a wrong guess only shows up when
someone runs it as root on hardware we don't have. ``--print-deps`` lets us check
that logic on any host: it reads an os-release file, prints what it would
install, and changes nothing. These tests drive that mode with fixture
os-release files and fake ``rpm`` / ``pacman`` binaries.
"""

from __future__ import annotations

import os
import pathlib
import stat
import subprocess
import tempfile
import unittest

REPO = pathlib.Path(__file__).resolve().parent.parent
INSTALL = REPO / "install.sh"
FIXTURES = REPO / "tests" / "fixtures"

KVER = "6.11.0-9-generic"

# Commands that would change the system. --print-deps must not call any of them,
# so the side-effect test replaces each one with a stub that records the call.
MUTATING = ("sudo", "apt-get", "apt", "dnf", "zypper", "dkms", "modprobe", "systemctl")


def fixture(name: str) -> pathlib.Path:
    path = FIXTURES / f"os-release-{name}"
    assert path.is_file(), f"missing fixture {path}"
    return path


def write_exe(directory: pathlib.Path, name: str, body: str) -> None:
    path = directory / name
    path.write_text("#!/bin/sh\n" + body + "\n")
    path.chmod(path.stat().st_mode | stat.S_IXUSR | stat.S_IXGRP | stat.S_IXOTH)


def run_print_deps(
    os_release: pathlib.Path | str,
    *,
    kver: str = KVER,
    extra_env: dict[str, str] | None = None,
    bin_dir: pathlib.Path | None = None,
) -> subprocess.CompletedProcess[str]:
    env = os.environ.copy()
    # Don't let the caller's shell leak an override into the test.
    for key in ("PKG_FAMILY", "OS_RELEASE", "KVER"):
        env.pop(key, None)
    env["OS_RELEASE"] = str(os_release)
    env["KVER"] = kver
    if bin_dir is not None:
        env["PATH"] = f"{bin_dir}{os.pathsep}{env.get('PATH', '')}"
    if extra_env:
        env.update(extra_env)
    return subprocess.run(
        [str(INSTALL), "--print-deps"],
        cwd=REPO,
        env=env,
        capture_output=True,
        text=True,
        timeout=30,
    )


def parse(stdout: str) -> dict[str, str]:
    out: dict[str, str] = {}
    for line in stdout.splitlines():
        key, sep, value = line.partition(":")
        assert sep, f"unexpected line in --print-deps output: {line!r}"
        out[key.strip()] = value.strip()
    return out


def deps_for(name: str, **kwargs) -> dict[str, str]:
    proc = run_print_deps(fixture(name), **kwargs)
    assert proc.returncode == 0, f"{name}: exit {proc.returncode}\nstderr:\n{proc.stderr}"
    return parse(proc.stdout)


class TestOutputShape(unittest.TestCase):
    def test_prints_exactly_four_keyed_lines(self):
        """Other tooling (and these tests) parse this output.

        A stray progress message on stdout would break that, so anything chatty
        has to go to stderr.
        """
        proc = run_print_deps(fixture("ubuntu"))
        assert proc.returncode == 0, proc.stderr
        lines = proc.stdout.splitlines()
        assert len(lines) == 4, lines
        assert [line.split(":", 1)[0] for line in lines] == [
            "family",
            "deps",
            "headers",
            "loopback",
        ]

    def test_changes_nothing_and_never_escalates(self):
        """--print-deps exists so this runs safely on any host.

        If it ever reached sudo, a package manager, dkms or systemd, a test run
        on a developer machine could install packages or load modules. Every
        such command is replaced with a stub that leaves a marker, and HOME is
        pointed at an empty directory so a stray user-unit or PATH edit would
        show up too.
        """
        with tempfile.TemporaryDirectory() as tmp:
            tmp_path = pathlib.Path(tmp)
            bin_dir = tmp_path / "bin"
            home = tmp_path / "home"
            calls = tmp_path / "calls"
            bin_dir.mkdir()
            home.mkdir()
            calls.mkdir()
            for name in MUTATING:
                write_exe(bin_dir, name, f'touch "{calls}/{name}"; exit 1')
            for name in ("ubuntu", "fedora", "arch", "opensuse-tumbleweed"):
                proc = run_print_deps(
                    fixture(name), bin_dir=bin_dir, extra_env={"HOME": str(home)}
                )
                assert proc.returncode == 0, f"{name}: {proc.stderr}"
            assert sorted(p.name for p in calls.iterdir()) == []
            assert list(home.iterdir()) == []


class TestDetection(unittest.TestCase):
    def test_apt_family(self):
        for name in ("ubuntu", "debian"):
            with self.subTest(distro=name):
                assert deps_for(name)["family"] == "apt"

    def test_apt_derivatives_via_id_like(self):
        """Mint and Pop!_OS have their own ID, so only ID_LIKE identifies them.

        ID_LIKE is a space-separated list in quotes; each word has to be checked,
        not the whole string.
        """
        for name in ("linuxmint", "pop"):
            with self.subTest(distro=name):
                assert deps_for(name)["family"] == "apt"

    def test_dnf_family(self):
        assert deps_for("fedora")["family"] == "dnf"

    def test_rhel_rebuild_via_id_like(self):
        """AlmaLinux quotes its ID and lists rhel first in ID_LIKE."""
        assert deps_for("almalinux")["family"] == "dnf"

    def test_pacman_family(self):
        for name in ("arch", "manjaro", "endeavouros"):
            with self.subTest(distro=name):
                assert deps_for(name)["family"] == "pacman"

    def test_zypper_family(self):
        """Tumbleweed's ID is "opensuse-tumbleweed", not "opensuse".

        Exact matching on ID would miss it. ID_LIKE ("opensuse suse") should
        catch it anyway, and this pins that behaviour down.
        """
        assert deps_for("opensuse-tumbleweed")["family"] == "zypper"

    def test_zypper_family_from_id_alone(self):
        """Leap- or SLES-style IDs should map to zypper even without ID_LIKE."""
        with tempfile.TemporaryDirectory() as tmp:
            for distro_id in ("opensuse-leap", "sles"):
                with self.subTest(id=distro_id):
                    path = pathlib.Path(tmp) / f"os-release-{distro_id}"
                    path.write_text(f'NAME="test"\nID="{distro_id}"\n')
                    proc = run_print_deps(path)
                    assert proc.returncode == 0, proc.stderr
                    assert parse(proc.stdout)["family"] == "zypper"

    def test_unknown_distro_fails_loudly(self):
        """Guessing a package manager on an unknown distro would fail halfway.

        Better to stop up front, print nothing parseable on stdout, and tell the
        user what is unsupported.
        """
        proc = run_print_deps(fixture("gentoo"))
        assert proc.returncode != 0
        assert "family:" not in proc.stdout
        err = proc.stderr.lower()
        assert "unsupported" in err or "--print-deps" in err, proc.stderr

    def test_pkg_family_overrides_detection(self):
        """PKG_FAMILY is the escape hatch for derivatives that detection gets wrong."""
        out = deps_for("ubuntu", extra_env={"PKG_FAMILY": "pacman"})
        assert out["family"] == "pacman"
        assert "base-devel" in out["deps"].split()


class TestPackageNames(unittest.TestCase):
    """Spot-check the package names that differ most between families.

    These tests don't compare full lists. Names get adjusted, and only the
    distinctive ones (the ones that are easy to get wrong) are worth pinning.
    """

    def test_apt(self):
        out = deps_for("ubuntu")
        deps = out["deps"].split()
        for pkg in ("build-essential", "gstreamer1.0-pipewire", "pipewire-bin"):
            assert pkg in deps, (pkg, deps)
        assert out["loopback"].split() == ["v4l2loopback-dkms", "v4l2loopback-utils"]
        assert out["headers"] == f"linux-headers-{KVER}"

    def test_dnf(self):
        out = deps_for("fedora")
        deps = out["deps"].split()
        for pkg in ("pipewire-gstreamer", "pipewire-utils", "python3-gobject"):
            assert pkg in deps, (pkg, deps)
        assert "akmod-v4l2loopback" in out["loopback"].split()

    def test_pacman(self):
        out = deps_for("arch")
        deps = out["deps"].split()
        for pkg in ("base-devel", "gst-plugin-pipewire", "python-gobject"):
            assert pkg in deps, (pkg, deps)
        assert "v4l2loopback-dkms" in out["loopback"].split()

    def test_zypper(self):
        out = deps_for("opensuse-tumbleweed", kver="6.11.0-1-default")
        deps = out["deps"].split()
        for pkg in ("gstreamer-plugin-pipewire", "pipewire-tools"):
            assert pkg in deps, (pkg, deps)
        assert "v4l2loopback-kmp-default" in out["loopback"].split()


class TestHeaders(unittest.TestCase):
    """The headers package has to match the running kernel, not the stock one.

    linux-surface ships its own kernel package, so on a Surface the stock
    kernel-devel or linux-headers would be the wrong package. The installer asks
    the package database which package owns the running vmlinuz. Fake rpm and
    pacman binaries stand in for that query.
    """

    def setUp(self):
        self._tmp = tempfile.TemporaryDirectory()
        self.bin_dir = pathlib.Path(self._tmp.name)

    def tearDown(self):
        self._tmp.cleanup()

    def test_dnf_stock_kernel(self):
        write_exe(self.bin_dir, "rpm", "echo kernel-core")
        kver = "6.11.4-301.fc41.x86_64"
        out = deps_for("fedora", kver=kver, bin_dir=self.bin_dir)
        assert out["headers"] == f"kernel-devel-{kver}"

    def test_dnf_linux_surface_kernel(self):
        write_exe(self.bin_dir, "rpm", "echo kernel-surface")
        kver = "6.11.4-1.surface.fc41.x86_64"
        out = deps_for("fedora", kver=kver, bin_dir=self.bin_dir)
        assert out["headers"] == f"kernel-surface-devel-{kver}"

    def test_dnf_queries_the_running_kernel_image(self):
        """The query must target this KVER's vmlinuz, not whatever kernel is newest."""
        log = self.bin_dir / "rpm.args"
        write_exe(self.bin_dir, "rpm", f'echo "$@" > "{log}"; echo kernel-core')
        kver = "6.11.4-301.fc41.x86_64"
        deps_for("fedora", kver=kver, bin_dir=self.bin_dir)
        assert f"/lib/modules/{kver}/vmlinuz" in log.read_text()

    def test_dnf_falls_back_when_rpm_fails(self):
        write_exe(self.bin_dir, "rpm", "exit 1")
        kver = "6.11.4-301.fc41.x86_64"
        out = deps_for("fedora", kver=kver, bin_dir=self.bin_dir)
        assert out["headers"] == f"kernel-devel-{kver}"

    def test_pacman_zen_kernel(self):
        write_exe(self.bin_dir, "pacman", "echo linux-zen")
        out = deps_for("arch", kver="6.11.4-zen1-1-zen", bin_dir=self.bin_dir)
        assert out["headers"] == "linux-zen-headers"

    def test_pacman_queries_the_running_kernel_image(self):
        log = self.bin_dir / "pacman.args"
        write_exe(self.bin_dir, "pacman", f'echo "$@" > "{log}"; echo linux')
        kver = "6.11.4-arch1-1"
        deps_for("arch", kver=kver, bin_dir=self.bin_dir)
        assert f"/usr/lib/modules/{kver}/vmlinuz" in log.read_text()

    def test_pacman_falls_back_when_query_fails(self):
        write_exe(self.bin_dir, "pacman", "exit 1")
        out = deps_for("arch", kver="6.11.4-arch1-1", bin_dir=self.bin_dir)
        assert out["headers"] == "linux-headers"

    def test_zypper_flavor_from_kver(self):
        """openSUSE encodes the flavor as the last dash-separated part of the release."""
        out = deps_for("opensuse-tumbleweed", kver="6.11.0-1-default")
        assert out["headers"] == "kernel-default-devel"


PKG_SH = REPO / "scripts" / "pkg.sh"

# pkg.sh expects its caller to provide these. die must exit, like install.sh's.
STUBS = r"""
ok() { printf 'ok: %s\n' "$*" >&2; }
warn() { printf 'warn: %s\n' "$*" >&2; }
die() { printf 'die: %s\n' "$*" >&2; exit 1; }
need_sudo() { :; }
"""

DNF5_INSTALL = """\
Updating and loading repositories:
Repositories loaded.
Package                 Arch   Version       Repository      Size
Installing:
 foo                    x86_64 1.0-1.fc44    fedora      10.0 KiB

Transaction Summary:
 Installing:         1 package

Total size of inbound packages is 4 KiB. Need to download 4 KiB.
After this operation, 10 KiB extra will be used (install 10 KiB, remove 0 B).
Operation aborted by the user.
"""

DNF5_REMOVING_50 = """\
Updating and loading repositories:
Repositories loaded.
Package                 Arch   Version       Repository      Size
Installing:
 foo                    x86_64 1.0-1.fc44    fedora      10.0 KiB
Removing:
 gnome-shell            x86_64 48.0-1.fc44   updates     12.0 MiB
Removing dependent packages:
 gdm                    x86_64 48.0-1.fc44   updates      4.0 MiB

Transaction Summary:
 Installing:         1 package
 Removing:          50 packages

Operation aborted by the user.
"""

DNF4_REMOVE_3 = """\
Dependencies resolved.
================================================================================
 Package          Arch      Version          Repository                    Size
================================================================================
Removing:
 foo              x86_64    1.0-1.el9        @appstream                    10 k
Removing dependent packages:
 bar              x86_64    1.0-1.el9        @appstream                    10 k
 baz              x86_64    1.0-1.el9        @appstream                    10 k

Transaction Summary
================================================================================
Remove  3 Packages

Freed space: 30 k
Operation aborted.
"""

DNF_NOTHING = """\
Dependencies resolved.
Nothing to do.
Complete!
"""

APT_REMV_2 = """\
NOTE: This is only a simulation!
      apt-get needs root privileges for real execution.
      Keep also in mind that locking is deactivated,
      so don't depend on the relevance to the real current situation!
Reading package lists...
Building dependency tree...
Reading state information...
The following packages will be REMOVED:
  bar baz
The following NEW packages will be installed:
  foo
0 upgraded, 1 newly installed, 2 to remove and 0 not upgraded.
Remv bar [1.0]
Remv baz [1.0]
Inst foo (1.0 Ubuntu:24.04/noble [amd64])
Conf foo (1.0 Ubuntu:24.04/noble [amd64])
"""

ZYPPER_REMOVED_3 = """\
Loading repository data...
Reading installed packages...
Resolving package dependencies...

The following 3 packages are going to be REMOVED:
  bar baz qux

The following NEW package is going to be installed:
  foo

1 new package to install, 3 to remove.
"""

ZYPPER_REMOVED_1 = """\
Loading repository data...
Reading installed packages...
Resolving package dependencies...

The following package is going to be REMOVED:
  bar

1 package to remove.
"""

ZYPPER_NEW_2 = """\
Loading repository data...
Reading installed packages...
Resolving package dependencies...

The following 2 NEW packages are going to be installed:
  foo libfoo1

2 new packages to install.
Overall download size: 120.0 KiB. Already cached: 0 B. After the operation,
additional 400.0 KiB will be used.
"""

ZYPPER_NOTHING = """\
Loading repository data...
Reading installed packages...
Resolving package dependencies...

Nothing to do.
"""

ZYPPER_GERMAN = """\
Repository-Daten werden geladen...
Installierte Pakete werden gelesen...
Paketabhängigkeiten werden aufgelöst...

Die folgenden 3 Pakete werden GELÖSCHT:
  bar baz qux

3 zu entfernende Pakete.
"""


class TestRemovalGuard(unittest.TestCase):
    """The install step must never remove packages to make room.

    A dependency conflict can make a package manager offer to "fix" things by
    removing half the desktop. ``_pkg_removals`` reads a dry run and reports how
    many packages would go. If it doesn't recognise the output it has to return
    an error, never 0, because a 0 lets the real install go ahead.

    PKG_DRYRUN_CMD replaces the package manager with a fake that prints canned
    output and exits with a chosen code. The fake also records its arguments
    and the LC_ALL it was given.
    """

    def setUp(self):
        self._tmp = tempfile.TemporaryDirectory()
        self.tmp = pathlib.Path(self._tmp.name)
        self.out_file = self.tmp / "out"
        self.code_file = self.tmp / "code"
        self.args_file = self.tmp / "args"
        self.env_file = self.tmp / "env"
        write_exe(
            self.tmp,
            "fake-pm",
            f'echo "$@" >> "{self.args_file}"\n'
            f'env | grep ^LC_ALL= >> "{self.env_file}"\n'
            f'cat "{self.out_file}"\n'
            f'exit "$(cat "{self.code_file}")"',
        )

    def tearDown(self):
        self._tmp.cleanup()

    def bash(
        self,
        body: str,
        *args: str,
        extra_env: dict[str, str] | None = None,
        bin_dir: pathlib.Path | None = None,
    ) -> subprocess.CompletedProcess[str]:
        env = os.environ.copy()
        for key in ("PKG_FAMILY", "OS_RELEASE", "PKG_DRYRUN_CMD", "LC_ALL", "LANGUAGE"):
            env.pop(key, None)
        env["KVER"] = KVER
        env["PKG_DRYRUN_CMD"] = str(self.tmp / "fake-pm")
        if bin_dir is not None:
            env["PATH"] = f"{bin_dir}{os.pathsep}{env.get('PATH', '')}"
        if extra_env:
            env.update(extra_env)
        script = f'{STUBS}\nsource "{PKG_SH}"\n{body}\n'
        return subprocess.run(
            ["bash", "-c", script, "bash", *args],
            cwd=REPO,
            env=env,
            capture_output=True,
            text=True,
            timeout=30,
        )

    def removals(
        self, fam: str, op: str, output: str, code: int, *pkgs: str, **kwargs
    ) -> tuple[int, str]:
        self.out_file.write_text(output)
        self.code_file.write_text(str(code))
        proc = self.bash('_pkg_removals "$@"', fam, op, *(pkgs or ("foo",)), **kwargs)
        return proc.returncode, proc.stdout.strip()

    def assert_count(self, result: tuple[int, str], expected: int) -> None:
        rc, out = result
        assert rc == 0, result
        assert out == str(expected), result

    def assert_fails_closed(self, result: tuple[int, str]) -> None:
        """A failed parse must print no count at all, and in particular not "0"."""
        rc, out = result
        assert rc != 0, result
        assert out == "", result

    # dnf: --assumeno always exits 1, so the exit code says nothing either way.

    def test_dnf5_install_without_removals(self):
        self.assert_count(self.removals("dnf", "install", DNF5_INSTALL, 1), 0)

    def test_dnf5_removing_summary(self):
        """The "Removing:" section header has no count; only the summary line does."""
        self.assert_count(self.removals("dnf", "install", DNF5_REMOVING_50, 1), 50)

    def test_dnf4_remove_summary(self):
        self.assert_count(self.removals("dnf", "install", DNF4_REMOVE_3, 1), 3)

    def test_dnf_nothing_to_do(self):
        self.assert_count(self.removals("dnf", "install", DNF_NOTHING, 0), 0)

    def test_dnf_unrecognised_output_fails_closed(self):
        """Without a summary, a repo error looks the same as "nothing to remove"."""
        garbage = "Error: Failed to download metadata for repo 'fedora'\n"
        self.assert_fails_closed(self.removals("dnf", "install", garbage, 1))

    # apt

    def test_apt_counts_remv_lines(self):
        self.assert_count(self.removals("apt", "install", APT_REMV_2, 0), 2)

    def test_apt_failure_fails_closed(self):
        out = "E: Unable to locate package foo\n"
        self.assert_fails_closed(self.removals("apt", "install", out, 100))

    # zypper

    def test_zypper_plural_removal(self):
        self.assert_count(self.removals("zypper", "install", ZYPPER_REMOVED_3, 0), 3)

    def test_zypper_singular_removal(self):
        """zypper leaves the number out when it is one package."""
        self.assert_count(self.removals("zypper", "install", ZYPPER_REMOVED_1, 0), 1)

    def test_zypper_new_packages_only(self):
        """A count in a NEW line must not be read as a removal count."""
        self.assert_count(self.removals("zypper", "install", ZYPPER_NEW_2, 0), 0)

    def test_zypper_nothing_to_do(self):
        self.assert_count(self.removals("zypper", "install", ZYPPER_NOTHING, 0), 0)

    def test_zypper_localised_output_fails_closed(self):
        """The script forces LC_ALL=C, but if a translation leaks through anyway
        the English parser sees no summary. It has to report that as unknown,
        not as 0 removals."""
        self.assert_fails_closed(self.removals("zypper", "install", ZYPPER_GERMAN, 0))

    def test_zypper_failure_fails_closed(self):
        out = "No provider of 'foo' found.\n"
        self.assert_fails_closed(self.removals("zypper", "install", out, 104))

    # pacman

    def test_pacman_install_resolves(self):
        out = "https://mirror.example/core/os/x86_64/foo-1.0-1-x86_64.pkg.tar.zst\n"
        self.assert_count(self.removals("pacman", "install", out, 0), 0)

    def test_pacman_install_failure_fails_closed(self):
        out = "error: target not found: foo\n"
        self.assert_fails_closed(self.removals("pacman", "install", out, 1))

    def test_pacman_remove_counts_lines(self):
        out = "v4l2loopback-dkms-0.13.2-1\nv4l2loopback-utils-0.13.2-1\n"
        self.assert_count(
            self.removals(
                "pacman", "remove", out, 0, "v4l2loopback-dkms", "v4l2loopback-utils"
            ),
            2,
        )

    def test_pacman_remove_failure_fails_closed(self):
        out = "error: target not found: foo\n"
        self.assert_fails_closed(self.removals("pacman", "remove", out, 1))

    # Behaviour shared by every family

    def test_dry_run_is_forced_into_the_c_locale(self):
        """The parsers match English text, so a German LANG must not reach them."""
        outputs = {
            "apt": APT_REMV_2,
            "dnf": DNF5_INSTALL,
            "zypper": ZYPPER_NOTHING,
            "pacman": "",
        }
        for fam, output in outputs.items():
            with self.subTest(family=fam):
                self.env_file.unlink(missing_ok=True)
                self.removals(
                    fam,
                    "install",
                    output,
                    0,
                    extra_env={"LANG": "de_DE.UTF-8"},
                )
                assert self.env_file.read_text().split() == ["LC_ALL=C"]

    def test_dry_run_flags_are_passed(self):
        """PKG_DRYRUN_CMD only replaces the binary. If a dry-run flag went missing,
        the "dry run" would be a real transaction."""
        expected = {
            ("apt", "install"): "-s",
            ("dnf", "install"): "--assumeno",
            ("zypper", "install"): "--dry-run",
            ("pacman", "install"): "-Sp",
            ("pacman", "remove"): "-Rp",
        }
        for (fam, op), flag in expected.items():
            with self.subTest(family=fam, op=op):
                self.args_file.unlink(missing_ok=True)
                self.removals(fam, op, "", 0)
                assert flag in self.args_file.read_text().split()

    def test_pkg_install_refuses_when_dry_run_would_remove(self):
        """End to end: a dry run that would remove packages stops pkg_install
        before sudo is asked to run the real install."""
        bin_dir = self.tmp / "bin"
        bin_dir.mkdir()
        sudo_log = self.tmp / "sudo.calls"
        dnf_log = self.tmp / "dnf.calls"
        write_exe(bin_dir, "sudo", f'echo "$@" >> "{sudo_log}"')
        # Satisfies `command -v dnf` on any host. The dry run goes through
        # PKG_DRYRUN_CMD, so this binary should never actually be run.
        write_exe(bin_dir, "dnf", f'echo "$@" >> "{dnf_log}"; exit 1')
        self.out_file.write_text(
            "Transaction Summary:\n Installing:         1 package\n"
            " Removing:          2 packages\n"
        )
        self.code_file.write_text("1")
        proc = self.bash(
            'pkg_installed() { return 1; }\npkg_install dnf foo',
            bin_dir=bin_dir,
        )
        assert proc.returncode != 0, proc
        assert "REMOVE" in proc.stderr, proc.stderr
        sudo_calls = sudo_log.read_text() if sudo_log.exists() else ""
        assert "dnf install" not in sudo_calls, sudo_calls
        assert not dnf_log.exists(), dnf_log.read_text()


if __name__ == "__main__":
    unittest.main()
