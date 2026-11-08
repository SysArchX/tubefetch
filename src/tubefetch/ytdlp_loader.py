"""Localiza e importa a versão do yt-dlp que será utilizada pelo aplicativo.

Ordem de preferência:

1. ``TUBEFETCH_VENDOR`` (variável de ambiente, útil para testes);
2. ``~/.local/share/tubefetch/vendor`` (versão atualizada pelo usuário);
3. ``/usr/lib/tubefetch/vendor`` (versão embutida no pacote .deb);
4. ``vendor/`` ao lado do código-fonte (execução em modo de desenvolvimento);
5. yt-dlp instalado no sistema.
"""

from __future__ import annotations

import os
import shutil
import sys
from pathlib import Path


def _vendor_candidates():
    env = os.environ.get("TUBEFETCH_VENDOR")
    if env:
        yield Path(env).expanduser()
    yield Path.home() / ".local" / "share" / "tubefetch" / "vendor"
    yield Path("/usr/lib/tubefetch/vendor")
    yield Path(__file__).resolve().parent.parent.parent / "vendor"


def _qjs_candidates():
    yield Path.home() / ".local" / "share" / "tubefetch" / "bin" / "qjs"
    yield Path("/usr/lib/tubefetch/bin/qjs")
    yield Path(__file__).resolve().parent.parent.parent / "data" / "bin" / "qjs"
    system = shutil.which("qjs")
    if system:
        yield Path(system)


def _find_qjs() -> str | None:
    for candidate in _qjs_candidates():
        if candidate.is_file() and os.access(candidate, os.X_OK):
            return str(candidate)
    return None


def _setup_path() -> str | None:
    for path in _vendor_candidates():
        if (path / "yt_dlp" / "__init__.py").is_file():
            entry = str(path)
            if entry not in sys.path:
                sys.path.insert(0, entry)
            return entry
    return None


_VENDOR_PATH = _setup_path()

QJS_PATH = _find_qjs()

import yt_dlp  # noqa: E402  (precisa vir depois do ajuste do sys.path)

YTDLP_VERSION: str = yt_dlp.version.__version__

if _VENDOR_PATH:
    user_vendor = str(Path.home() / ".local" / "share" / "tubefetch" / "vendor")
    if _VENDOR_PATH == user_vendor:
        YTDLP_ORIGIN = "atualizado pelo usuário"
    elif _VENDOR_PATH.startswith("/usr/lib/tubefetch"):
        YTDLP_ORIGIN = "embutido no aplicativo"
    else:
        YTDLP_ORIGIN = "modo de desenvolvimento"
else:
    YTDLP_ORIGIN = "instalado no sistema"
