#!/bin/sh
# Копирует FarvaterCore.xcframework в Frameworks/ (в git его нет: репозиторий публичный, бинарь 27 МБ).
# Использование: tools/fetch-farvater-core.sh [путь к FarvaterCore.xcframework]
set -eu

SOURCE="${1:-$HOME/Developer/NyutagX-iOS/Frameworks/FarvaterCore.xcframework}"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TARGET="$ROOT/Frameworks/FarvaterCore.xcframework"

if [ ! -f "$SOURCE/Info.plist" ]; then
    echo "Не найден xcframework: $SOURCE" >&2
    exit 1
fi

mkdir -p "$ROOT/Frameworks"
rm -rf "$TARGET"
cp -R "$SOURCE" "$TARGET"
echo "Готово: $TARGET"
