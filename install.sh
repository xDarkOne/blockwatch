#!/bin/sh
# Установка blockwatch на OpenWrt 24.10+ с netshift или podkop.
#
#   sh -c "$(curl -fsSL https://raw.githubusercontent.com/xDarkOne/blockwatch/main/install.sh)"
#
# Удаление (список доменов и журнал остаются):
#   sh -c "$(curl -fsSL https://raw.githubusercontent.com/xDarkOne/blockwatch/main/install.sh)" -- uninstall
# Полное удаление, вместе со списком и подключением к netshift/podkop:
#   ... -- uninstall --purge
#
# Переменные: BW_REF — ветка или тег (по умолчанию main), BW_SRC — локальный
# каталог с исходниками вместо загрузки, BW_FORCE=1 — ставить на старую OpenWrt.

set -e

REPO=${BW_REPO:-xDarkOne/blockwatch}
REF=${BW_REF:-main}
SRC=${BW_SRC:-}

# источник:назначение:права[:keep — не перезаписывать изменённое пользователем]
FILES="
blockwatch/files/usr/bin/blockwatch:/usr/bin/blockwatch:755
blockwatch/files/etc/init.d/blockwatch:/etc/init.d/blockwatch:755
blockwatch/files/etc/config/blockwatch:/etc/config/blockwatch:644:keep
luci-app-blockwatch/root/usr/share/luci/menu.d/luci-app-blockwatch.json:/usr/share/luci/menu.d/luci-app-blockwatch.json:644
luci-app-blockwatch/root/usr/share/rpcd/acl.d/luci-app-blockwatch.json:/usr/share/rpcd/acl.d/luci-app-blockwatch.json:644
luci-app-blockwatch/htdocs/luci-static/resources/view/blockwatch/blockwatch.js:/www/luci-static/resources/view/blockwatch/blockwatch.js:644
"

say()  { echo "[blockwatch] $*"; }
die()  { echo "[blockwatch] ОШИБКА: $*" >&2; exit 1; }

check_system() {
    [ -f /etc/openwrt_release ] || die "это не OpenWrt"
    . /etc/openwrt_release
    _ver=${DISTRIB_RELEASE:-0}
    case "$_ver" in
        SNAPSHOT*|*-SNAPSHOT) ;;
        *)
            _maj=$(echo "$_ver" | cut -d. -f1); _min=$(echo "$_ver" | cut -d. -f2)
            if [ "$((${_maj:-0} * 100 + ${_min:-0}))" -lt 2410 ] && [ "$BW_FORCE" != 1 ]; then
                die "нужна OpenWrt 24.10 или новее, а здесь $_ver (BW_FORCE=1 — ставить всё равно)"
            fi
            ;;
    esac
    say "OpenWrt $_ver"
    if [ -x /usr/bin/netshift ]; then say "найден netshift"
    elif [ -x /usr/bin/podkop ]; then say "найден podkop"
    else say "ВНИМАНИЕ: не найден ни netshift, ни podkop — наблюдатель будет ждать их появления"
    fi
}

pkg_install() {
    _missing=""
    command -v jq   >/dev/null 2>&1 || _missing="$_missing jq"
    command -v curl >/dev/null 2>&1 || _missing="$_missing curl"
    command -v nft  >/dev/null 2>&1 || _missing="$_missing nftables"
    [ -n "$_missing" ] || return 0
    say "ставлю:$_missing"
    if command -v apk >/dev/null 2>&1; then
        apk update >/dev/null && apk add $_missing
    elif command -v opkg >/dev/null 2>&1; then
        opkg update >/dev/null && opkg install $_missing
    else
        die "не найден ни apk, ни opkg"
    fi
}

fetch() {   # путь в репозитории, куда положить
    if [ -n "$SRC" ]; then
        cp -f "$SRC/$1" "$2"
    else
        curl -fsSL "https://raw.githubusercontent.com/$REPO/$REF/$1" -o "$2" ||
            die "не удалось скачать $1"
    fi
}

install_files() {
    _tmp=$(mktemp -d)
    echo "$FILES" | while IFS=: read -r _src _dst _mode _keep; do
        [ -n "$_src" ] || continue
        # сначала всё скачиваем во временный каталог — чтобы оборванная
        # загрузка не оставила полуустановленный набор файлов
        fetch "$_src" "$_tmp/$(echo "$_dst" | tr / _)"
    done
    # файл скачан, но пуст — значит что-то не так, лучше остановиться
    for _f in "$_tmp"/*; do [ -s "$_f" ] || die "пустой файл: $_f"; done

    echo "$FILES" | while IFS=: read -r _src _dst _mode _keep; do
        [ -n "$_src" ] || continue
        if [ "$_keep" = keep ] && [ -f "$_dst" ]; then
            say "оставляю свои настройки: $_dst"
            continue
        fi
        mkdir -p "$(dirname "$_dst")"
        mv -f "$_tmp/$(echo "$_dst" | tr / _)" "$_dst"
        chmod "$_mode" "$_dst"
    done
    rm -rf "$_tmp"
}

remove_files() {
    echo "$FILES" | while IFS=: read -r _src _dst _mode _keep; do
        [ -n "$_src" ] || continue
        [ "$_keep" = keep ] && [ "$PURGE" != 1 ] && continue
        rm -f "$_dst"
    done
    rmdir /www/luci-static/resources/view/blockwatch 2>/dev/null || true
}

refresh_luci() {
    rm -rf /tmp/luci-indexcache* /tmp/luci-modulecache 2>/dev/null
    /etc/init.d/rpcd reload >/dev/null 2>&1 || true
}

case "$1" in
    uninstall)
        PURGE=0; [ "$2" = --purge ] && PURGE=1
        # даже если сама команда удаления споткнулась, файлы убираем всё равно:
        # полуудалённый наблюдатель хуже любого другого исхода
        if [ -x /usr/bin/blockwatch ]; then
            if [ "$PURGE" = 1 ]; then _arg=--purge; else _arg=""; fi
            /usr/bin/blockwatch uninstall $_arg ||
                say "ВНИМАНИЕ: blockwatch uninstall завершился с ошибкой, удаляю файлы всё равно"
        fi
        /etc/init.d/blockwatch disable >/dev/null 2>&1 || true
        remove_files
        refresh_luci
        say "удалён"
        [ "$PURGE" = 1 ] || say "список доменов и журнал остались в /etc/blockwatch"
        ;;
    ""|install)
        check_system
        pkg_install
        install_files
        /usr/bin/blockwatch install
        refresh_luci
        say "установлен: $(/usr/bin/blockwatch version)"
        echo
        /usr/bin/blockwatch doctor || true
        echo
        if /usr/bin/blockwatch status 2>/dev/null | jq -e '.hooked' >/dev/null 2>&1; then
            say "Файл доменов уже подключён. Смотри, что происходит: LuCI → Службы → Blockwatch"
        else
            say "Дальше:"
            say "  1. подключи файл доменов к netshift/podkop:  blockwatch hook main"
            say "     (или вручную: секция → Local Domain Lists → /etc/blockwatch/domains.txt)"
            say "  2. смотри, что происходит: LuCI → Службы → Blockwatch"
        fi
        ;;
    *)
        die "неизвестная команда: $1 (install | uninstall [--purge])"
        ;;
esac
