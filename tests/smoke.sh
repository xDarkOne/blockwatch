#!/bin/sh
# Smoke-тест внутри корневой ФС OpenWrt (chroot). Сети и nft там нет, поэтому
# проверяется то, что ломается между версиями OpenWrt и между бэкендами:
# установщик и пакетный менеджер, busybox, распознавание netshift и podkop,
# JSON для LuCI, hook/unhook и чистое удаление.
#
# Запуск: BW_SRC=/путь/к/исходникам sh tests/smoke.sh

set -u
SRC=${BW_SRC:?укажи BW_SRC}
FAILS=0

pass() { echo "  ok   $*"; }
fail() { echo "  FAIL $*"; FAILS=$((FAILS + 1)); }
check() { _name=$1; shift; if "$@" >/dev/null 2>&1; then pass "$_name"; else fail "$_name"; fi; }

. /etc/openwrt_release
echo "== OpenWrt $DISTRIB_RELEASE"

# поддельный бэкенд: ровно то, что blockwatch читает у netshift/podkop
fake_backend() {   # имя таблица набор
    _b=$1
    rm -f /usr/bin/netshift /usr/bin/podkop /etc/config/netshift /etc/config/podkop
    printf '#!/bin/sh\necho "%s $*" >> /tmp/%s.calls\n' "$_b" "$_b" > "/usr/bin/$_b"
    chmod 755 "/usr/bin/$_b"
    mkdir -p "/usr/lib/$_b" /etc/sing-box
    cat > "/usr/lib/$_b/constants.sh" <<EOF
FAKEIP_TEST_DOMAIN="fakeip.podkop.fyi"
TMP_SING_BOX_FOLDER="/tmp/sing-box"
TMP_RULESET_FOLDER="\$TMP_SING_BOX_FOLDER/rulesets"
NFT_TABLE_NAME="$2"
NFT_COMMON_SET_NAME="$3"
NFT_FAKEIP_MARK="0x00100000"
SB_FAKEIP_INET4_RANGE="198.18.0.0/15"
SB_DNS_INBOUND_ADDRESS="127.0.0.42"
EOF
    cat > "/etc/config/$_b" <<EOF
config settings 'settings'
	option config_path '/etc/sing-box/config.json'

config section 'main'
	option connection_type 'proxy'
EOF
    cat > /etc/sing-box/config.json <<'EOF'
{"inbounds": [
   {"type": "tproxy", "tag": "tproxy-in", "listen": "127.0.0.1", "listen_port": 1602},
   {"type": "mixed", "tag": "main-mixed-in", "listen": "192.168.1.1", "listen_port": 2080},
   {"type": "mixed", "tag": "service-mixed-in", "listen": "127.0.0.1", "listen_port": 4534}],
 "outbounds": [
   {"type": "direct", "tag": "direct-out"},
   {"type": "vless", "tag": "proxy", "server": "vpn.example.net", "server_port": 443},
   {"type": "hysteria2", "tag": "proxy2", "server": "203.0.113.7", "server_port": 443}]}
EOF
}

echo "== синтаксис"
for f in blockwatch/files/usr/bin/blockwatch blockwatch/files/etc/init.d/blockwatch install.sh tests/smoke.sh; do
    check "sh -n $f" sh -n "$SRC/$f"
done

echo "== установка (netshift)"
fake_backend netshift NetShiftTable netshift_subnets
if BW_SRC=$SRC sh "$SRC/install.sh" > /tmp/install.log 2>&1; then pass "install.sh"
else
    # дальше проверять нечего: без установки остальные проверки прошли бы
    # вхолостую или упали бы каскадом и спрятали настоящую причину
    fail "install.sh"; sed 's/^/     /' /tmp/install.log | tail -20
    echo "== установка не удалась, дальше не проверяю"; exit 1
fi
for f in /usr/bin/blockwatch /etc/init.d/blockwatch /etc/config/blockwatch \
         /usr/share/luci/menu.d/luci-app-blockwatch.json \
         /usr/share/rpcd/acl.d/luci-app-blockwatch.json \
         /www/luci-static/resources/view/blockwatch/blockwatch.js; do
    check "есть $f" test -s "$f"
done
check "исполняемый" test -x /usr/bin/blockwatch
check "задание cron" grep -q "blockwatch scan" /etc/crontabs/root
check "журнал dnsmasq включён" test "$(uci -q get dhcp.@dnsmasq[0].logqueries)" = 1
check "сохранены прежние настройки" test -f /etc/blockwatch/saved-settings

echo "== распознавание"
blockwatch status > /tmp/s.json 2>/tmp/status.err
check "status — корректный JSON" jq -e . /tmp/s.json
check "бэкенд netshift" jq -e '.backend == "netshift"' /tmp/s.json
check "файл не подключён" jq -e '.hooked == false' /tmp/s.json
check "проблема про подключение" jq -e '[.problems[] | select(contains("не подключён"))] | length > 0' /tmp/s.json
D=$(blockwatch doctor 2>&1)
check "doctor: таблица из constants.sh" sh -c "echo \"\$0\" | grep -q 'NetShiftTable / netshift_subnets'" "$D"
check "doctor: socks-вход service-mixed-in" sh -c "echo \"\$0\" | grep -q '127.0.0.1:4534'" "$D"

echo "== стоп-список"
N=$(sh -c '. /usr/bin/blockwatch >/dev/null 2>&1; build_never; echo "$NEVER"')
# пустой шаблон grep совпадает с чем угодно — тогда проверки ниже врут
if [ -z "$N" ]; then fail "стоп-список пуст"; else pass "стоп-список собран"; fi
for d in grani.ru www.gosuslugi.ru x.xn--p1ai r1.googlevideo.com vpn.example.net cdn.example.net; do
    check "не добавлять $d" sh -c "echo $d | grep -qEi '$N'"
done
for d in discord.com linkmydroid.com rsc.cdn77.org example.com; do
    check "можно добавлять $d" sh -c "! echo $d | grep -qEi '$N'"
done

echo "== вердикты"
V() { sh -c ". /usr/bin/blockwatch >/dev/null 2>&1; verdict_of $1 $2 $3"; }
check "000~/200/200 — живой (адрес ответил)" test "$(V '000~' 200 200)" = "живой"
check "200~/200~/200 — заблокирован (обрыв)" test "$(V '200~' '200~' 200)" = "ЗАБЛОКИРОВАН"
check "000/000/000 — лежит" test "$(V 000 000 000)" = "лежит"
# при свежем кэше туннеля socks-адрес всё равно должен быть известен: в 0.1.0
# он оставался пустым, и проверка через туннель 59 минут из 60 шла вхолостую
T=$(sh -c '. /usr/bin/blockwatch >/dev/null 2>&1; now=10000; mkdir -p $DIR
    echo "9999 1 198.51.100.1 198.51.100.2 127.0.0.1:4534" > $DIR/tunnel
    tunnel_check && echo "ok $SOCKS"; rm -f $DIR/tunnel')
check "свежий кэш туннеля: socks известен" test "$T" = "ok 127.0.0.1:4534"
check "in_range fakeip" sh -c '. /usr/bin/blockwatch >/dev/null 2>&1; in_range 198.19.3.4 198.18.0.0/15'
check "in_range чужой" sh -c '. /usr/bin/blockwatch >/dev/null 2>&1; ! in_range 198.20.0.1 198.18.0.0/15'

echo "== фильтр обхода"
# подменные адреса бэкенда и уже проверенные имена отбрасываются; пустой файл
# вердиктов не должен ломать фильтр (раньше обход тогда не находил ничего)
mkdir -p /tmp/blockwatch
printf '198.18.3.4 tunnel.example.com\n203.0.113.9 fresh.example.com\n203.0.113.10 checked.example.com\n203.0.113.11 site.ru\n' > /tmp/bw-ipmap
: > /tmp/blockwatch/verdicts
F=$(sh -c '. /usr/bin/blockwatch >/dev/null 2>&1; build_never; sweep_filter /tmp/bw-ipmap')
check "пустые вердикты: свежее имя в обходе" sh -c "echo \"\$0\" | grep -q fresh.example.com" "$F"
check "подменный адрес не в обходе" sh -c "! echo \"\$0\" | grep -q tunnel.example.com" "$F"
check "российский не в обходе" sh -c "! echo \"\$0\" | grep -q site.ru" "$F"
echo "203.0.113.10|checked.example.com|живой|0|1|1|обход|200/-/-" > /tmp/blockwatch/verdicts
F=$(sh -c '. /usr/bin/blockwatch >/dev/null 2>&1; build_never; sweep_filter /tmp/bw-ipmap')
check "проверенное имя не в обходе" sh -c "! echo \"\$0\" | grep -q checked.example.com" "$F"
check "непроверенное осталось" sh -c "echo \"\$0\" | grep -q fresh.example.com" "$F"
# на 4000 строк — один awk, а не процесс на строку
awk 'BEGIN { for (i = 0; i < 4000; i++) printf "203.0.%d.%d host%d.example.com\n", i / 250, i % 250, i }' > /tmp/bw-ipmap
S=$(date +%s)
sh -c '. /usr/bin/blockwatch >/dev/null 2>&1; build_never; sweep_filter /tmp/bw-ipmap' > /tmp/bw-sweep
check "4000 имён за пару секунд" test $(( $(date +%s) - S )) -le 3
check "все 4000 прошли фильтр" test "$(wc -l < /tmp/bw-sweep)" = 4000
rm -f /tmp/bw-ipmap /tmp/bw-sweep /tmp/blockwatch/verdicts

echo "== после 0.1.0: её «лежит» недостоверны"
rm -f /etc/blockwatch/verdicts.v
printf '%s\n' '203.0.113.30|down.example.com|лежит|0|1|1|обход|000~/000~/000~' \
    '203.0.113.31|up.example.com|живой|0|1|1|обход|200/-/-' > /tmp/blockwatch/verdicts
sh -c '. /usr/bin/blockwatch >/dev/null 2>&1; forget_blind_down'
check "старое «лежит» выброшено" sh -c "! grep -q down.example.com /tmp/blockwatch/verdicts"
check "«живой» остался" grep -q up.example.com /tmp/blockwatch/verdicts
echo '203.0.113.32|new.example.com|лежит|0|2|2|сброс|000~/000~/000~' >> /tmp/blockwatch/verdicts
sh -c '. /usr/bin/blockwatch >/dev/null 2>&1; forget_blind_down'
check "чистка только один раз" grep -q new.example.com /tmp/blockwatch/verdicts
rm -f /tmp/blockwatch/verdicts /etc/blockwatch/verdicts.v

echo "== hook / unhook"
blockwatch hook main >/dev/null 2>&1
check "hook добавил путь" sh -c "uci -q get netshift.main.local_domain_lists | grep -q /etc/blockwatch/domains.txt"
blockwatch status > /tmp/s.json 2>/dev/null
check "status: подключён" jq -e '.hooked == true and .section == "main"' /tmp/s.json
blockwatch hook main >/dev/null 2>&1
check "повторный hook не дублирует" test "$(uci -q get netshift.main.local_domain_lists | wc -w)" = 1
blockwatch unhook >/dev/null 2>&1
check "unhook убрал путь" sh -c "! uci -q get netshift.main.local_domain_lists"

echo "== podkop"
fake_backend podkop PodkopTable podkop_subnets
blockwatch status > /tmp/s.json 2>/dev/null
check "бэкенд podkop" jq -e '.backend == "podkop"' /tmp/s.json
check "doctor: таблица podkop" sh -c "blockwatch doctor 2>&1 | grep -q 'PodkopTable / podkop_subnets'"
blockwatch hook main >/dev/null 2>&1
check "hook в podkop" sh -c "uci -q get podkop.main.local_domain_lists | grep -q domains.txt"

echo "== удаление"
echo "linkmydroid.com" >> /etc/blockwatch/domains.txt
BW_SRC=$SRC sh "$SRC/install.sh" uninstall > /tmp/uninstall.log 2>&1 && pass "uninstall" || fail "uninstall"
check "файлы убраны" sh -c "! test -e /usr/bin/blockwatch && ! test -e /www/luci-static/resources/view/blockwatch/blockwatch.js"
check "cron очищен" sh -c "! grep -q blockwatch /etc/crontabs/root"
check "список доменов сохранён" grep -q linkmydroid.com /etc/blockwatch/domains.txt
BW_SRC=$SRC sh "$SRC/install.sh" >/dev/null 2>&1
BW_SRC=$SRC sh "$SRC/install.sh" uninstall --purge >/dev/null 2>&1
check "purge: всё убрано" sh -c "! test -e /etc/blockwatch && ! test -e /etc/config/blockwatch"
check "purge: отключён от podkop" sh -c "! uci -q get podkop.main.local_domain_lists"

echo
if [ "$FAILS" = 0 ]; then echo "== ВСЁ ПРОШЛО"; else echo "== ПРОВАЛОВ: $FAILS"; fi
exit "$FAILS"
