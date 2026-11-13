"""Ponto de entrada do aplicativo."""

from __future__ import annotations

import sys

from gi.repository import GLib

from . import APP_NAME
from .window import FastSearchXApplication


def main(argv=None) -> int:
    GLib.set_prgname("fastsearchx")
    GLib.set_application_name(APP_NAME)
    application = FastSearchXApplication()
    return application.run(argv if argv is not None else sys.argv)


if __name__ == "__main__":
    raise SystemExit(main())
