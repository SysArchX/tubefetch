#!/usr/bin/env bash
# Constrói o pacote .deb do TubeFetch.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

VERSION="$(PYTHONPATH="$ROOT/src" python3 -c 'import tubefetch; print(tubefetch.APP_VERSION)')"
ARCH="$(dpkg --print-architecture)"
PKG_NAME="tubefetch_${VERSION}_${ARCH}"
STAGE="$ROOT/build/$PKG_NAME"
DIST="$ROOT/dist"

echo "==> Versão: $VERSION | Arquitetura: $ARCH"

# ----------------------------------------------------------------------
# Dependências embutidas
# ----------------------------------------------------------------------
"$ROOT/packaging/fetch-deps.sh"

QJS="$ROOT/data/bin/qjs"

# ----------------------------------------------------------------------
# Estrutura do pacote
# ----------------------------------------------------------------------
rm -rf "$STAGE"
mkdir -p "$STAGE/DEBIAN"
mkdir -p "$STAGE/usr/bin"
mkdir -p "$STAGE/usr/lib/tubefetch"
mkdir -p "$STAGE/usr/share/applications"
mkdir -p "$STAGE/usr/share/doc/tubefetch"

cp -a "$ROOT/src/tubefetch" "$STAGE/usr/lib/tubefetch/"
find "$STAGE/usr/lib/tubefetch" -type d -name "__pycache__" -prune -exec rm -rf {} +
find "$STAGE/usr/lib/tubefetch" -type f -name "*.pyc" -delete

cp -a "$ROOT/vendor" "$STAGE/usr/lib/tubefetch/vendor"
find "$STAGE/usr/lib/tubefetch/vendor" -type d -name "__pycache__" -prune -exec rm -rf {} +
find "$STAGE/usr/lib/tubefetch/vendor" -type f -name "*.pyc" -delete

install -Dm755 "$QJS" "$STAGE/usr/lib/tubefetch/bin/qjs"

cat > "$STAGE/usr/bin/tubefetch" <<'LAUNCHER'
#!/bin/sh
export PYTHONPATH="/usr/lib/tubefetch${PYTHONPATH:+:$PYTHONPATH}"
exec python3 -m tubefetch "$@"
LAUNCHER
chmod 755 "$STAGE/usr/bin/tubefetch"

install -Dm644 "$ROOT/data/com.lazlabs.TubeFetch.desktop" \
    "$STAGE/usr/share/applications/com.lazlabs.TubeFetch.desktop"

for SIZE in 16 24 32 48 64 128 256 512; do
    ICON="$ROOT/data/icons/tubefetch-${SIZE}.png"
    if [ -f "$ICON" ]; then
        install -Dm644 "$ICON" \
            "$STAGE/usr/share/icons/hicolor/${SIZE}x${SIZE}/apps/tubefetch.png"
    fi
done
install -Dm644 "$ROOT/data/tubefetch.svg" \
    "$STAGE/usr/share/icons/hicolor/scalable/apps/tubefetch.svg"

install -Dm644 "$ROOT/README.md" "$STAGE/usr/share/doc/tubefetch/README.md"
install -Dm644 "$ROOT/vendor/yt_dlp-2026.10.26.dist-info/licenses/LICENSE" \
    "$STAGE/usr/share/doc/tubefetch/copyright-yt-dlp" 2>/dev/null || true

# Permissões consistentes (arquivos 644; executáveis 755)
find "$STAGE/usr" -type d -exec chmod 755 {} +
find "$STAGE/usr" -type f -exec chmod 644 {} +
chmod 755 "$STAGE/usr/bin/tubefetch" "$STAGE/usr/lib/tubefetch/bin/qjs"

# ----------------------------------------------------------------------
# Controle do pacote
# ----------------------------------------------------------------------
INSTALLED_SIZE="$(du -sk --exclude=DEBIAN "$STAGE" | cut -f1)"

cat > "$STAGE/DEBIAN/control" <<EOF
Package: tubefetch
Version: $VERSION
Section: video
Priority: optional
Architecture: $ARCH
Installed-Size: $INSTALLED_SIZE
Depends: python3 (>= 3.11), python3-gi, gir1.2-gtk-3.0, ffmpeg
Recommends: python3-pip, yt-dlp, xdg-utils
Maintainer: LazLabs <lazlabs@localhost>
Description: Baixador de vídeos e músicas do YouTube
 Interface gráfica simples para baixar vídeos (MP4) e músicas (MP3)
 de links e playlists do YouTube. Usa o yt-dlp embutido, com suporte
 a progresso, cancelamento, escolha de qualidade, seleção de itens da
 playlist e atualização do yt-dlp.
EOF

cat > "$STAGE/DEBIAN/postinst" <<'EOF'
#!/bin/sh
set -e
if command -v update-desktop-database >/dev/null 2>&1; then
    update-desktop-database -q /usr/share/applications || true
fi
if command -v gtk-update-icon-cache >/dev/null 2>&1; then
    gtk-update-icon-cache -q -t /usr/share/icons/hicolor || true
fi
exit 0
EOF
chmod 755 "$STAGE/DEBIAN/postinst"

cat > "$STAGE/DEBIAN/postrm" <<'EOF'
#!/bin/sh
set -e
if command -v update-desktop-database >/dev/null 2>&1; then
    update-desktop-database -q /usr/share/applications || true
fi
if command -v gtk-update-icon-cache >/dev/null 2>&1; then
    gtk-update-icon-cache -q -t /usr/share/icons/hicolor || true
fi
exit 0
EOF
chmod 755 "$STAGE/DEBIAN/postrm"

# ----------------------------------------------------------------------
# Empacotamento
# ----------------------------------------------------------------------
mkdir -p "$DIST"
dpkg-deb --build --root-owner-group "$STAGE" "$DIST/$PKG_NAME.deb"

echo
echo "==> Pacote criado: $DIST/$PKG_NAME.deb"
echo "    Tamanho: $(du -h "$DIST/$PKG_NAME.deb" | cut -f1)"
echo
echo "Instale com:"
echo "    sudo apt install \"$DIST/$PKG_NAME.deb\""
