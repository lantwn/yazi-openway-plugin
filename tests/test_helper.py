#!/usr/bin/env python3
"""Standalone smoke test for assets/open-with-gio.

It creates a temporary XDG data directory with one fake desktop application,
then checks that the helper discovers it and launches it with the right files.
No GTK/GUI is involved (Terminal=false, the fake app only writes a log).
"""

from __future__ import annotations

import json
import os
import shutil
import subprocess
import sys
import tempfile
import time
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
HELPER = ROOT / "assets" / "open-with-gio"


def write_executable(path: Path, content: str) -> None:
    path.write_text(content)
    path.chmod(0o755)


def main() -> int:
    with tempfile.TemporaryDirectory(prefix="open-with-test-") as tmp:
        base = Path(tmp)
        applications = base / "share" / "applications"
        config = base / "config"
        applications.mkdir(parents=True)
        config.mkdir(parents=True)

        log = base / "launched.txt"
        fake_app = base / "fake-app.sh"
        write_executable(
            fake_app,
            "#!/bin/sh\n"
            'printf \'%s\\n\' "$@" > "$OPEN_WITH_TEST_LOG"\n',
        )

        (applications / "open-with-test.desktop").write_text(
            "[Desktop Entry]\n"
            "Type=Application\n"
            "Name=Open With Test\n"
            "Exec=" + str(fake_app) + " %F\n"
            "Terminal=false\n"
            "NoDisplay=false\n"
            "MimeType=text/plain;\n"
        )
        (applications / "mimeinfo.cache").write_text(
            "[MIME Cache]\n"
            "text/plain=open-with-test.desktop;\n"
        )
        (applications / "mimeapps.list").write_text(
            "[Default Applications]\n"
            "text/plain=open-with-test.desktop;\n"
        )
        (config / "mimeapps.list").write_text(
            "[Default Applications]\n"
            "text/plain=open-with-test.desktop;\n"
        )

        if shutil.which("update-desktop-database"):
            subprocess.run(
                ["update-desktop-database", str(applications)],
                check=False,
                stdout=subprocess.DEVNULL,
                stderr=subprocess.DEVNULL,
            )

        target = base / "sample.txt"
        target.write_text("hello\n")
        second = base / "second.txt"
        second.write_text("world\n")

        env = os.environ.copy()
        env.update(
            {
                "XDG_DATA_HOME": str(base / "data"),
                "XDG_DATA_DIRS": str(base / "share"),
                "XDG_CONFIG_HOME": str(config),
                "OPEN_WITH_TEST_LOG": str(log),
            }
        )

        listed = subprocess.run(
            [sys.executable, str(HELPER), "--list", "--", str(target)],
            env=env,
            capture_output=True,
            text=True,
        )
        if listed.returncode != 0:
            print("helper --list failed:", listed.stdout, listed.stderr, file=sys.stderr)
            return 1

        data = json.loads(listed.stdout)
        ids = {app["id"] for app in data.get("apps", [])}
        if "open-with-test.desktop" not in ids:
            print("fake app missing from --list:", data, file=sys.stderr)
            return 1

        launched = subprocess.run(
            [
                sys.executable,
                str(HELPER),
                "--launch",
                "open-with-test.desktop",
                "--",
                str(target),
                str(second),
            ],
            env=env,
            capture_output=True,
            text=True,
        )
        if launched.returncode != 0:
            print("helper --launch failed:", launched.stdout, launched.stderr, file=sys.stderr)
            return 1

        deadline = time.monotonic() + 2.0
        while not log.exists() and time.monotonic() < deadline:
            time.sleep(0.05)
        if not log.exists():
            print("fake app was not launched", file=sys.stderr)
            return 1

        args = log.read_text().splitlines()
        if str(target) not in args or str(second) not in args:
            print("unexpected launch args:", args, file=sys.stderr)
            return 1

        print("ok: discovered and launched the fake app with both files")
        return 0


if __name__ == "__main__":
    raise SystemExit(main())
