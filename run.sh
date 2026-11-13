#!/bin/sh
# Executa o aplicativo a partir do código-fonte (modo de desenvolvimento).
set -eu
cd "$(dirname "$0")"

# Baixa o yt-dlp e o QuickJS-ng embutidos na primeira execução.
if [ ! -f vendor/yt_dlp/__init__.py ] || [ ! -x data/bin/qjs ]; then
    ./packaging/fetch-deps.sh
fi

export PYTHONPATH="$PWD/src${PYTHONPATH:+:$PYTHONPATH}"
exec python3 -m fastsearchx "$@"
