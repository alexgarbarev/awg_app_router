#!/bin/zsh
# Сборка «AWG App Router.app»: Swift-бинари + Go-ядро + ресурсы, ad-hoc подпись.
# Имя бандла с пробелом — everywhere цитируем (APP ниже).
set -euo pipefail
cd "$(dirname "$0")/.."
swift build -c release
APP="dist/AWG App Router.app"
rm -rf "$APP" dist/AppRouter.app   # старый бандл до ренойма — не плодить сущности
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

cp .build/release/AWGAppRouter "$APP/Contents/MacOS/AWGAppRouter"
cp .build/release/awgapprouterd "$APP/Contents/Resources/awgapprouterd"
cp bin/awgapprouter-box "$APP/Contents/Resources/awgapprouter-box"
cp Resources/Info.plist "$APP/Contents/Info.plist"
if [ -f Resources/AppIcon.icns ]; then cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"; fi
# иконки трея: PNG 18/@2x (template); -full — контроль, не в бандл;
# предыдущее содержимое вычищается (следы старых конвейеров: pdf и пр.)
rm -f "$APP/Contents/Resources"/tray-*(N)
for f in Resources/tray/*.png(N); do
    [[ "$f" == *-full.png ]] && continue
    cp "$f" "$APP/Contents/Resources/"
done
cp Resources/com.awgapprouter.daemon.plist "$APP/Contents/Resources/com.awgapprouter.daemon.plist"
cp Resources/install-privileged.sh Resources/uninstall-privileged.sh "$APP/Contents/Resources/"
# лицензии внутри бандла (GPL-требование для ядра + наш MIT)
cp LICENSE THIRD-PARTY-NOTICES.txt "$APP/Contents/Resources/"
chmod +x "$APP/Contents/Resources"/*.sh "$APP/Contents/Resources/awgapprouterd"

# ad-hoc подпись: сначала вложенные исполняемые, потом бандл
codesign --force --sign - "$APP/Contents/Resources/awgapprouter-box"
codesign --force --sign - "$APP/Contents/Resources/awgapprouterd"
codesign --force --deep --sign - "$APP"
codesign --verify --deep --strict "$APP" && echo "signature OK"
# LaunchServices: зарегистрировать заново (renamed bundle id — иконка/имя не протухли)
/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -f "$APP"
echo "готово: $APP"
