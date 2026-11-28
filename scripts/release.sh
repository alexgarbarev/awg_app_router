#!/bin/zsh
# Релиз «AWG App Router»: версия в бандл → полная сборка → zip → tag → GitHub Release.
#
#   scripts/release.sh 1.0.0
#
# Требования: gh (brew install gh) + gh auth login; чистое дерево; brew-go для ядра;
# Xcode CLT для Swift. Тег v<version> создаётся автоматически и пушится.
set -euo pipefail
cd "$(dirname "$0")/.."

VERSION="${1:-}"
shift || true
DAEMON_CHANGED=no
[[ "${1:-}" == "--daemon" ]] && DAEMON_CHANGED=yes
[[ "$VERSION" =~ '^[0-9]+\.[0-9]+\.[0-9]+$' ]] || {
    echo "использование: scripts/release.sh X.Y.Z [--daemon]"; exit 1
}
command -v gh >/dev/null 2>&1 || { echo "нужен gh: brew install gh"; exit 1; }
gh auth status >/dev/null 2>&1 || { echo "сначала: gh auth login"; exit 1; }
# Без секции в CHANGELOG релиз выходит с пустым «Что нового» — не молчим:
grep -qE "^## v$VERSION( |—|-)" CHANGELOG.md || {
    echo "в CHANGELOG.md нет секции '## v$VERSION' — добавь описание и повтори"; exit 1; }
git diff --quiet && git diff --cached --quiet || {
    echo "дерево грязное — сначала закоммить"; exit 1
}
git rev-parse -q --verify "refs/tags/v$VERSION" >/dev/null && {
    echo "тег v$VERSION уже есть — другая версия"; exit 1
} || true

echo "=== релиз v$VERSION (демон: $([ "$DAEMON_CHANGED" = yes ] && echo 'изменён — bump' || echo 'без изменений — UI-only')) ==="

# версия внутрь бандла (plutil), чтобы скачанный .app показывал честную версию
plutil -replace CFBundleShortVersionString -string "$VERSION" Resources/Info.plist
plutil -replace CFBundleVersion -string "$(git rev-list --count HEAD)" Resources/Info.plist
# appReleaseVersion — всегда за текущим релизом
sed -i '' -E "s/^(public let appReleaseVersion = \")[^\"]*\"/\1$VERSION\"/" Sources/AWGAppRouterKit/Version.swift
# daemonVersion/minDaemonVersion — ТОЛЬКО если демон реально менялся (--daemon):
# иначе рабочий демон прошедшего релиза не будет переустанавливаться зря
if [ "$DAEMON_CHANGED" = yes ]; then
    sed -i '' -E "s/^(public let daemonVersion = \")[^\"]*\"/\1$VERSION\"/" Sources/AWGAppRouterKit/Version.swift
    sed -i '' -E "s/^(public let minDaemonVersion = \")[^\"]*\"/\1$VERSION\"/" Sources/AWGAppRouterKit/Version.swift
fi
git add Resources/Info.plist Sources/AWGAppRouterKit/Version.swift
git commit -m "release: v$VERSION" --quiet

scripts/build-core.sh
scripts/build-app.sh

APP="dist/AWG App Router.app"
ZIP="dist/AWG-App-Router-v$VERSION.zip"
NOTES="dist/release-notes-v$VERSION.md"
rm -f "$ZIP" "$NOTES"

# ditto: сохраняет хвосты бандла, симлинки и ad-hoc подпись (zip -r ломает)
ditto -c -k --keepParent "$APP" "$ZIP"
codesign --verify --deep --strict "$APP" && echo "подпись в порядке"

cat > "$NOTES" <<'EOF'
Пер-приложенческий split-tunnel для macOS (Apple Silicon): выбранные приложения
и их дочерние процессы — через AmneziaWG-туннель, остальное — напрямую через роутер.

## Установка

1. Распакуй `AWG App Router.app` в `/Applications`.
2. Gatekeeper (подпись ad-hoc): при первом запуске macOS заругается и предложит
   удалить приложение — закрой это окно. Затем **System Settings → Privacy & Security**
   → в блоке Security найди «AWG App Router был заблокирован» → **«Open Anyway»**.
   Либо в терминале:
   ```sh
   xattr -dr com.apple.quarantine "/Applications/AWG App Router.app"
   ```
3. Запусти — приложение один раз попросит пароль администратора и установит
   LaunchDaemon + бинари. Дальше включение/выключение туннеля — без пароля.

## Удаление

```sh
sudo "/Applications/AWG App Router.app/Contents/Resources/uninstall-privileged.sh"
```

Лицензии: наш код — MIT, бинарь ядра — GPL-3.0 (amnezia-box/sing-box),
подробности в THIRD-PARTY-NOTICES.txt внутри бандла.
EOF

# changelog: секция текущей версии из CHANGELOG.md — в notes релиза
{
    echo
    echo "## Что нового в v$VERSION"
    echo
    awk -v v="## v$VERSION" 'index($0, v)==1 {f=1; next} /^## v[0-9]/ {f=0} f' CHANGELOG.md
} >> "$NOTES"

git push origin main
git tag -a "v$VERSION" -m "AWG App Router v$VERSION"
git push origin "v$VERSION"

# gh release create: при обрыве загрузки на полпути остаётся релиз с битым/
# отсутствующим ассетом — повтор тогда чинит ассет, а не создаёт дубль
if ! gh release create "v$VERSION" "$ZIP" \
        --title "AWG App Router v$VERSION" \
        --notes-file "$NOTES"; then
    sleep 3
    if gh release view "v$VERSION" >/dev/null 2>&1; then
        echo "релиз уже есть — докачиваю ассет"
        gh release upload "v$VERSION" "$ZIP" --clobber
    else
        echo "релиза нет — повторяю создание"
        gh release create "v$VERSION" "$ZIP" \
            --title "AWG App Router v$VERSION" \
            --notes-file "$NOTES" --verify-tag
    fi
fi

echo "готово: https://github.com/alexgarbarev/awg_app_router/releases/tag/v$VERSION"
