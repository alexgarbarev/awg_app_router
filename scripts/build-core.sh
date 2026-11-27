#!/bin/zsh
# Go-ядро: amnezia-box -> bin/awgapprouter-box
set -euo pipefail
cd "$(dirname "$0")/.."
[ -d vendor/amnezia-box ] || scripts/fetch-vendor.sh
cd vendor/amnezia-box
GOTOOLCHAIN=local GOWORK=off go build \
  -tags "with_gvisor,with_awg,with_quic,with_utls,with_clash_api,with_dhcp,with_wireguard" \
  -o ../../bin/awgapprouter-box ./cmd/sing-box
codesign --force --sign - ../../bin/awgapprouter-box
ls -l ../../bin/awgapprouter-box
