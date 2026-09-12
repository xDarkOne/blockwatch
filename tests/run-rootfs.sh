#!/bin/bash
# Прогон tests/smoke.sh в корневой ФС OpenWrt x86_64 нужной версии.
#   tests/run-rootfs.sh 24.10     (или 25.12)
# Без root работает через unshare -r; в CI, где непривилегированные user
# namespaces запрещены, — через sudo.

set -eu
MAJOR=${1:?укажи версию, например 24.10}
HERE=$(cd "$(dirname "$0")/.." && pwd)
WORK=${WORK:-/tmp/blockwatch-rootfs}
mkdir -p "$WORK" && cd "$WORK"

VER=$(curl -sf --retry 3 https://downloads.openwrt.org/releases/ | grep -oE "${MAJOR}\.[0-9]+/" |
      tr -d / | sort -uV | tail -1)
if [ -z "$VER" ]; then
    # сайт OpenWrt не ответил — берём уже скачанную ФС этой версии, если она есть
    VER=$(ls openwrt-"${MAJOR}".*-x86-64-rootfs.tar.gz 2>/dev/null |
          sed -E 's/^openwrt-([0-9.]+)-x86-64.*/\1/' | sort -uV | tail -1)
fi
[ -n "$VER" ] || { echo "не найдена OpenWrt $MAJOR: сайт не ответил, скачанной нет"; exit 1; }
TAR="openwrt-${VER}-x86-64-rootfs.tar.gz"
[ -s "$TAR" ] || curl -sfL -o "$TAR" "https://downloads.openwrt.org/releases/${VER}/targets/x86/64/${TAR}"

if [ "$(id -u)" = 0 ]; then RUN=""
elif sudo -n true 2>/dev/null; then RUN="sudo"
else RUN="unshare -r"
fi

ROOT="$WORK/rootfs-$VER"
$RUN rm -rf "$ROOT"
mkdir -p "$ROOT"
$RUN tar -xzf "$TAR" -C "$ROOT" 2>/dev/null || true
$RUN mkdir -p "$ROOT/tmp" "$ROOT/var/lock" "$ROOT/src"
# в OpenWrt resolv.conf — ссылка в /tmp, в архиве она битая; кладём файл вместо неё
$RUN rm -f "$ROOT/etc/resolv.conf"
$RUN cp /etc/resolv.conf "$ROOT/etc/resolv.conf"
$RUN cp -r "$HERE/." "$ROOT/src/"

# jq и curl в чистой OpenWrt не стоят — и это нарочно: их должен поставить
# сам установщик, через opkg или apk, в зависимости от версии.
#
# Внутри chroot нужны устройства: без /dev/urandom не стартует TLS, и opkg/apk
# не скачивают пакеты («SSL error: Generic error»). tar файлов устройств не
# создаёт, поэтому пробрасываем их с хоста — в отдельном пространстве
# монтирования, чтобы после прогона на хосте ничего не осталось.
INNER='
    R=$1
    mkdir -p "$R/dev" "$R/proc"
    for n in null zero random urandom; do
        rm -f "$R/dev/$n"; touch "$R/dev/$n"
        mount --bind "/dev/$n" "$R/dev/$n"
    done
    mount --rbind /proc "$R/proc"
    chroot "$R" /bin/sh -c "BW_SRC=/src sh /src/tests/smoke.sh"
'
case "$RUN" in
    "")   unshare -m sh -c "$INNER" _ "$ROOT" ;;
    sudo) sudo unshare -m sh -c "$INNER" _ "$ROOT" ;;
    *)    unshare -r -m sh -c "$INNER" _ "$ROOT" ;;
esac
