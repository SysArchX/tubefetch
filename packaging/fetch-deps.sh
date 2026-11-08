#!/usr/bin/env bash
# Baixa as dependências embutidas (yt-dlp e QuickJS-ng) para uso local e build.
# É idempotente: não baixa nada que já exista.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

YTDLP_VERSION="${YTDLP_VERSION:-2026.10.26}"
ARCH="$(dpkg --print-architecture 2>/dev/null || uname -m)"

# ----------------------------------------------------------------------
# yt-dlp (wheel puro Python extraído em vendor/)
# ----------------------------------------------------------------------
if [ ! -f "$ROOT/vendor/yt_dlp/__init__.py" ]; then
    echo "==> Baixando yt-dlp $YTDLP_VERSION..."
    python3 - "$ROOT/vendor" "$YTDLP_VERSION" <<'PY'
import io
import json
import sys
import urllib.request
import zipfile

vendor, version = sys.argv[1], sys.argv[2]
meta_url = f"https://pypi.org/pypi/yt-dlp/{version}/json"
with urllib.request.urlopen(meta_url, timeout=60) as resp:
    meta = json.load(resp)
wheel = next(u for u in meta["urls"] if u["filename"].endswith(".whl"))
print(f"    {wheel['filename']}")
with urllib.request.urlopen(wheel["url"], timeout=120) as resp:
    data = resp.read()
with zipfile.ZipFile(io.BytesIO(data)) as archive:
    archive.extractall(vendor)
PY
else
    echo "==> yt-dlp já presente em vendor/"
fi

# ----------------------------------------------------------------------
# QuickJS-ng (runtime JavaScript usado pelo yt-dlp)
# ----------------------------------------------------------------------
QJS="$ROOT/data/bin/qjs"
if [ ! -x "$QJS" ]; then
    echo "==> Baixando QuickJS-ng..."
    case "$ARCH" in
        amd64|x86_64) ASSET="qjs-linux-x86_64" ;;
        arm64|aarch64) ASSET="qjs-linux-aarch64" ;;
        *)
            echo "ERRO: arquitetura sem binário QuickJS disponível: $ARCH" >&2
            exit 1
            ;;
    esac
    mkdir -p "$ROOT/data/bin"
    curl -L --fail --silent --show-error \
        "https://github.com/quickjs-ng/quickjs/releases/download/v0.18.0/$ASSET" \
        -o "$QJS"
    chmod +x "$QJS"
else
    echo "==> QuickJS-ng já presente em data/bin/qjs"
fi

echo "==> Dependências prontas."
