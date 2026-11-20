#!/usr/bin/env bash
# Gera o AppImage do The Force Engine.
# Deve rodar como root dentro de um container debian:12 (glibc 2.36),
# a partir da pasta onde o AppImage final deve ficar.
#
# Variáveis opcionais:
#   TFE_REF  branch ou tag do TheForceEngine a compilar (padrão: master)
set -euo pipefail

TFE_REF="${TFE_REF:-master}"
WORK="$(pwd)"
export DEBIAN_FRONTEND=noninteractive

echo "==> Instalando dependências"
apt-get update
apt-get install -y --no-install-recommends \
  build-essential cmake pkg-config git ca-certificates wget file zsync \
  desktop-file-utils \
  libsdl2-dev libsdl2-image-dev librtmidi-dev \
  libtheora-dev libogg-dev libvorbis-dev libglew-dev
# Se o cmake reclamar de alguma biblioteca, adicione o pacote -dev acima.

echo "==> Baixando o código ($TFE_REF)"
rm -rf src build AppDir
git clone --depth 1 --branch "$TFE_REF" \
  https://github.com/TheForceEngine/TheForceEngine.git src
VERSION="$(date +%Y%m%d)-$(git -C src rev-parse --short HEAD)"

echo "==> Compilando"
cmake -S src -B build -DCMAKE_BUILD_TYPE=Release -DCMAKE_INSTALL_PREFIX=/usr
cmake --build build -j"$(nproc)"
DESTDIR="$WORK/AppDir" cmake --install build

echo "==> Conteúdo instalado em AppDir:"
find AppDir -maxdepth 4 | sort | head -60

# O motor procura seus dados (UI_Text, Fonts, Shaders, Mods...) ao lado do
# executável. Como o AppImage monta tudo num diretório temporário, os caminhos
# de sistema (/usr/share...) não existem em tempo de execução. Por isso criamos
# atalhos relativos em usr/bin apontando para os dados em usr/share.
echo "==> Ligando os dados do motor ao lado do executável"
for item in AppDir/usr/share/TheForceEngine/*; do
  name="$(basename "$item")"
  ln -sfn "../share/TheForceEngine/$name" "AppDir/usr/bin/$name"
done
ls -la AppDir/usr/bin

# AppRun próprio: define onde ficam os dados do usuário (configurações, saves,
# log) antes de iniciar o motor. O padrão é ~/.config/TheForceEngine, mas quem
# já tiver TFE_DATA_HOME definido continua mandando no próprio caminho.
echo "==> Criando AppRun próprio"
cat > AppRun.custom <<'EOF'
#!/bin/sh
HERE="$(dirname "$(readlink -f "$0")")"
if [ -z "$TFE_DATA_HOME" ]; then
  TFE_DATA_HOME="${XDG_CONFIG_HOME:-$HOME/.config}/TheForceEngine"
  export TFE_DATA_HOME
fi
mkdir -p "$TFE_DATA_HOME"
exec "$HERE/usr/bin/theforceengine" "$@"
EOF
chmod +x AppRun.custom

# O .desktop e o ícone abaixo vêm da instalação do próprio projeto.
DESKTOP="$(find AppDir -name '*.desktop' | head -n1 || true)"
ICON="$(find AppDir -path '*icons*' \( -name '*.png' -o -name '*.svg' \) | head -n1 || true)"
if [ -z "$DESKTOP" ] || [ -z "$ICON" ]; then
  echo "ERRO: .desktop ou ícone não encontrados em AppDir (veja a listagem acima)." >&2
  echo "      Crie os seus em AppDir/usr/share/applications e AppDir/usr/share/icons." >&2
  exit 1
fi
echo "Usando desktop: $DESKTOP"
echo "Usando ícone:   $ICON"

echo "==> Baixando linuxdeploy"
wget -q -nc https://github.com/linuxdeploy/linuxdeploy/releases/download/continuous/linuxdeploy-x86_64.AppImage
wget -q -nc https://github.com/linuxdeploy/linuxdeploy-plugin-appimage/releases/download/continuous/linuxdeploy-plugin-appimage-x86_64.AppImage
chmod +x linuxdeploy-*.AppImage

export APPIMAGE_EXTRACT_AND_RUN=1   # container não tem FUSE
export PATH="$WORK:$PATH"           # o linuxdeploy acha o plugin por aqui
export LDAI_OUTPUT="TheForceEngine-${VERSION}-x86_64.AppImage"

# Atualização embutida (zsync) quando rodando no GitHub Actions
if [ -n "${GITHUB_REPOSITORY:-}" ]; then
  export LDAI_UPDATE_INFORMATION="gh-releases-zsync|${GITHUB_REPOSITORY%%/*}|${GITHUB_REPOSITORY##*/}|latest|TheForceEngine-*x86_64.AppImage.zsync"
fi

echo "==> Empacotando"
./linuxdeploy-x86_64.AppImage \
  --appdir AppDir \
  --executable AppDir/usr/bin/theforceengine \
  --desktop-file "$DESKTOP" \
  --icon-file "$ICON" \
  --custom-apprun AppRun.custom \
  --output appimage

echo "==> Pronto:"
ls -lh TheForceEngine-*.AppImage*
