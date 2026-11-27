#!/bin/zsh
# Восстановление vendor-деревьев из upstream (репозиторий их не содержит).
set -euo pipefail
cd "$(dirname "$0")/.."
mkdir -p vendor
[ -d vendor/amnezia-box ] || git clone --depth 1 https://github.com/amnezia-vpn/amnezia-box vendor/amnezia-box
[ -d vendor/amneziawg-go ] || git clone --depth 1 https://github.com/amnezia-vpn/amneziawg-go vendor/amneziawg-go
# amnezia-box использует amneziawg-go через go.mod replace/псевдо-версии;
# при расхождении — подгонять go.mod на месте.
echo "vendor OK"
