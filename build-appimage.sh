#!/usr/bin/env bash
# Gera o AppImage do The Force Engine.
# Deve rodar como root dentro de um container debian:12 (glibc 2.36),
# a partir da pasta onde o AppImage final deve ficar.
#
# Variáveis opcionais:
#   TFE_REF             branch ou tag do TheForceEngine a compilar (padrão: master,
#                       que é a versão de desenvolvimento; para uma versão
#                       estável use uma tag, por exemplo v1.22.420)
#   TFE_SOURCE_TARBALL  caminho de um .tar.gz com o código-fonte a compilar, em
#                       vez de baixar do GitHub (tem prioridade sobre TFE_REF)
#   TFE_VERSION         texto da versão usado no nome do AppImage (padrão com
#                       TFE_SOURCE_TARBALL: tirado do nome da pasta do arquivo)
#   TFE_EDITOR          OFF (padrão) ou ON: compila o editor do TFE, que ainda
#                       está em fase alfa e fica desligado, como no projeto
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

rm -rf src build AppDir
if [ -n "${TFE_SOURCE_TARBALL:-}" ]; then
  # Build "fixado" a partir de um código-fonte local (.tar.gz).
  echo "==> Usando o código-fonte local: $TFE_SOURCE_TARBALL"
  mkdir src
  tar -xf "$TFE_SOURCE_TARBALL" -C src --strip-components=1
  top="$(tar -tf "$TFE_SOURCE_TARBALL" | sed -n '1p')"
  top="${top%%/*}"
  VERSION="${TFE_VERSION:-${top#TheForceEngine-}}"
  # Sem .git dentro de src, o git poderia subir e achar o repositório deste
  # projeto, e o motor mostraria a versão errada. Este limite impede isso, e o
  # motor usa o gitVersion.h que já vem no código-fonte.
  export GIT_CEILING_DIRECTORIES="$WORK"
  PINNED=1
else
  echo "==> Baixando o código ($TFE_REF)"
  git clone --depth 1 --branch "$TFE_REF" \
    https://github.com/TheForceEngine/TheForceEngine.git src
  case "$TFE_REF" in
    v[0-9]*)
      # Tag de versão: o AppImage fica fixado nela (sem atualização embutida).
      VERSION="${TFE_REF#v}"
      PINNED=1
      ;;
    *)
      VERSION="$(date +%Y%m%d)-$(git -C src rev-parse --short HEAD)"
      ;;
  esac
fi

echo "==> Compilando"
cmake -S src -B build -DCMAKE_BUILD_TYPE=Release -DCMAKE_INSTALL_PREFIX=/usr \
  -DENABLE_EDITOR="${TFE_EDITOR:-OFF}"
cmake --build build -j"$(nproc)"
DESTDIR="$WORK/AppDir" cmake --install build

echo "==> Conteúdo instalado em AppDir:"
find AppDir -maxdepth 4 | sort | head -60

# Atalhos relativos em usr/bin apontando para os dados em usr/share. O AppRun
# não depende deles (ele copia os dados para a pasta do programa), mas eles
# permitem rodar o executável direto de usr/bin, útil para testes e diagnóstico.
echo "==> Ligando os dados do motor ao lado do executável"
for item in AppDir/usr/share/TheForceEngine/*; do
  name="$(basename "$item")"
  ln -sfn "../share/TheForceEngine/$name" "AppDir/usr/bin/$name"
done
ls -la AppDir/usr/bin

# AppRun próprio. O AppImage é só um iniciador, e há duas pastas separadas:
#  - Dados do usuário (configurações, saves, capturas, log):
#    ~/.config/TheForceEngine, definido pela variável TFE_DATA_HOME do motor.
#    Quem já tiver TFE_DATA_HOME definido continua mandando no próprio caminho.
#  - Pasta do programa (Mods, Fonts, Shaders, UI_Text, Documentation...):
#    ~/.local/share/TheForceEngine, como pastas normais e editáveis.
echo "==> Criando AppRun próprio"
cat > AppRun.custom <<'EOF'
#!/bin/sh
HERE="$(dirname "$(readlink -f "$0")")"
SRC="$HERE/usr/share/TheForceEngine"

# Dados do usuário
if [ -z "$TFE_DATA_HOME" ]; then
  TFE_DATA_HOME="${XDG_CONFIG_HOME:-$HOME/.config}/TheForceEngine"
  export TFE_DATA_HOME
fi
mkdir -p "$TFE_DATA_HOME"

# Pasta do programa. Quem quiser outro lugar define TFE_PROGRAM_DIR.
PROGRAM_DIR="${TFE_PROGRAM_DIR:-${XDG_DATA_HOME:-$HOME/.local/share}/TheForceEngine}"
mkdir -p "$PROGRAM_DIR"

# Na primeira execução as pastas do motor são copiadas do pacote; nas seguintes
# só entram os itens que ainda não existem, sem sobrescrever nada seu.
# Para trazer de volta os arquivos originais do pacote (por exemplo, depois de
# atualizar o AppImage), execute com TFE_REFRESH_DATA=1: os arquivos existentes
# são substituídos e as versões antigas ficam guardadas como arquivo~1~, etc.
if [ -n "$TFE_REFRESH_DATA" ]; then
  cp -a --no-preserve=mode --backup=numbered "$SRC/." "$PROGRAM_DIR/"
else
  cp -an --no-preserve=mode "$SRC/." "$PROGRAM_DIR/"
fi

# A pasta Captions deve existir só junto das pastas do motor: se sobrou uma
# vazia entre os dados do usuário, ela é removida (rmdir não apaga pasta com
# conteúdo).
rmdir "$TFE_DATA_HOME/Captions" 2>/dev/null || true

# O motor procura UI_Text, Fonts, Shaders, Mods... a partir da pasta atual.
cd "$PROGRAM_DIR"
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

# Nome do aplicativo sem espaços (TheForceEngine), como no nome do arquivo.
# Só a linha "Name=" é alterada; as traduções (Name[xx]=) não são tocadas.
sed -i 's/^Name=.*/Name=TheForceEngine/' "$DESKTOP"
grep -n '^Name' "$DESKTOP" || true

echo "==> Baixando linuxdeploy"
wget -q -nc https://github.com/linuxdeploy/linuxdeploy/releases/download/continuous/linuxdeploy-x86_64.AppImage
wget -q -nc https://github.com/linuxdeploy/linuxdeploy-plugin-appimage/releases/download/continuous/linuxdeploy-plugin-appimage-x86_64.AppImage
chmod +x linuxdeploy-*.AppImage

export APPIMAGE_EXTRACT_AND_RUN=1   # container não tem FUSE
export PATH="$WORK:$PATH"           # o linuxdeploy acha o plugin por aqui
export LDAI_OUTPUT="TheForceEngine-${VERSION}-x86_64.AppImage"

# Atualização embutida (zsync) quando rodando no GitHub Actions. Builds fixados
# em uma versão (código-fonte local) não recebem isso, para não serem
# "atualizados" para outra versão sem querer.
if [ -n "${GITHUB_REPOSITORY:-}" ] && [ -z "${PINNED:-}" ]; then
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
