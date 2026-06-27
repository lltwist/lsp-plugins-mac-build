#!/bin/bash
# Запусти этот скрипт на macOS Intel-маке.
# Результат: ~/lsp-build-x86/lsp-plugins-macos-x86_64.tar.gz
# готовый к копированию в VST3 папку или отправке обратно на M1
# для слияния с arm64-версией в universal binary через lipo.
set -euo pipefail

WORK="${WORK:-$HOME/lsp-build-x86}"
GIT_TAG="${GIT_TAG:-1.2.33}"

echo "==> рабочая директория: $WORK"
mkdir -p "$WORK"
cd "$WORK"

echo "==> проверяем brew (нужен для зависимостей)"
if ! command -v brew >/dev/null; then
  echo "Homebrew не установлен. Установи:"
  echo "  /bin/bash -c \"\$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)\""
  exit 1
fi

echo "==> ставим зависимости (если ещё нет)"
brew list make >/dev/null 2>&1 || brew install make
brew list pkg-config >/dev/null 2>&1 || brew install pkg-config
brew list cairo >/dev/null 2>&1 || brew install cairo
brew list freetype >/dev/null 2>&1 || brew install freetype
brew list libsndfile >/dev/null 2>&1 || brew install libsndfile
brew list expat >/dev/null 2>&1 || brew install expat

echo "==> клонируем LSP Plugins ($GIT_TAG)"
if [ ! -d lsp-plugins ]; then
  git clone --depth 1 --branch "$GIT_TAG" --recursive \
    https://github.com/lsp-plugins/lsp-plugins.git
fi
cd lsp-plugins

echo "==> конфигурируем (VST3 + UI)"
gmake clean 2>&1 | tail -3
gmake config FEATURES="vst3 ui" 2>&1 | tail -5
gmake fetch 2>&1 | tail -3

echo "==> собираем (10–20 минут)"
gmake -j$(sysctl -n hw.ncpu)

echo "==> ставим в локальный staging"
STAGED="$WORK/staged"
rm -rf "$STAGED"
mkdir -p "$STAGED"
gmake install DESTDIR="$STAGED" 2>&1 | tail -5

echo
echo "==> готово."
find "$STAGED" -name "*.vst3" -type d
echo
file "$STAGED/Library/Audio/Plug-Ins/VST3/lsp-plugins.vst3/Contents/MacOS/lsp-plugins"
echo
cd "$STAGED/Library/Audio/Plug-Ins/VST3"
tar czf "$WORK/lsp-plugins-macos-x86_64.tar.gz" lsp-plugins.vst3
ls -lh "$WORK/lsp-plugins-macos-x86_64.tar.gz"
echo
echo "Архив здесь: $WORK/lsp-plugins-macos-x86_64.tar.gz"
echo "Скинь его обратно на M1-мак, и он будет смержен с arm64 в universal."
