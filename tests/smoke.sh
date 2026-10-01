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
# обрыв по трём снимкам: «поток адрес наших-пакетов наших-байт байт-от-сервера»
printf '%s\n' 'a1 138.199.15.193 20 12000 6000' 'a2 138.199.15.193 20 12000 6000' 'b 203.0.113.80 20 9000 4000' \
    'c 203.0.113.81 50 9000 8000' 'i 213.180.204.179 40 9000 8000' 'f 198.18.0.46 20 9000 4000' > /tmp/bw-f0
printf '%s\n' 'a1 138.199.15.193 28 16116 8345' 'a2 138.199.15.193 29 17520 9831' 'b 203.0.113.80 25 9500 6000' \
    'c 203.0.113.81 50 9000 8000' 'i 213.180.204.179 40 9000 8000' 'f 198.18.0.46 25 9500 6000' \
    'd 203.0.113.71 10 3000 50000' 'g 203.0.113.72 9 1200 5000' 'h 203.0.113.73 12 2545 8369' > /tmp/bw-f1
printf '%s\n' 'a1 138.199.15.193 28 16116 8345' 'a2 138.199.15.193 29 17520 9831' 'b 203.0.113.80 25 9500 6000' \
    'c 203.0.113.81 50 9000 8000' 'i 213.180.204.179 40 9000 8000' 'f 198.18.0.46 25 9500 6000' \
    'd 203.0.113.71 13 3200 50000' 'g 203.0.113.72 9 1200 5400' 'h 203.0.113.73 12 2545 8369' > /tmp/bw-f2
S=$(sh -c '. /usr/bin/blockwatch >/dev/null 2>&1; stalled_flows /tmp/bw-f0 /tmp/bw-f1 /tmp/bw-f2' | sort | tr '\n' ';')
rm -f /tmp/bw-f0 /tmp/bw-f1 /tmp/bw-f2
check "два застрявших потока к адресу — обрыв" sh -c "echo \"\$0\" | grep -q '138.199.15.193 обрыв'" "$S"
check "один застрявший поток — замер" sh -c "echo \"\$0\" | grep -q '203.0.113.80 замер'" "$S"
check "давно простаивает (пуш) — не замер" sh -c "! echo \"\$0\" | grep -qE '203.0.113.81|213.180.204.179'" "$S"
check "подменный адрес — не считаем" sh -c "! echo \"\$0\" | grep -q 198.18.0.46" "$S"
check "переспрашивают без ответа — обрыв" sh -c "echo \"\$0\" | grep -q '203.0.113.71 обрыв'" "$S"
check "байты идут — не обрыв" sh -c "! echo \"\$0\" | grep -q 203.0.113.72" "$S"
check "получили много больше, чем отправили, — не замер" sh -c "! echo \"\$0\" | grep -q 203.0.113.73" "$S"
# обычная страница обрезана: по 2 КБ туда, ~20 КБ обратно, в двух соединениях к адресу
printf '%s\n' 'p1 216.150.1.65 10 2000 9000' 'p2 216.150.1.65 10 2100 9000' 'q 216.150.1.66 10 2000 9000' > /tmp/bw-f0
printf '%s\n' 'p1 216.150.1.65 12 2117 20621' 'p2 216.150.1.65 12 2186 20631' 'q 216.150.1.66 12 2049 22027' > /tmp/bw-f1
cp /tmp/bw-f1 /tmp/bw-f2
S=$(sh -c '. /usr/bin/blockwatch >/dev/null 2>&1; stalled_flows /tmp/bw-f0 /tmp/bw-f1 /tmp/bw-f2' | sort | tr '\n' ';')
rm -f /tmp/bw-f0 /tmp/bw-f1 /tmp/bw-f2
check "страница встала на 20 КБ в двух соединениях — обрыв" sh -c "echo \"\$0\" | grep -q '216.150.1.65 обрыв'" "$S"
check "одно такое соединение — не в счёт" sh -c "! echo \"\$0\" | grep -q 216.150.1.66" "$S"
# стоп-список: кандидат с российским именем не проверяется вовсе
: > /tmp/bw-probed
sh -c '. /usr/bin/blockwatch >/dev/null 2>&1; build_never; checked=0; checked_run=0; now=10000
    probe() { echo ru >> /tmp/bw-probed; echo "200 - -"; }; domain_of() { echo push.yandex.ru; }
    check_one 213.180.204.179 замер'
check "стоп-список: .ru не проверяется" sh -c "! grep -qx ru /tmp/bw-probed"
rm -f /tmp/bw-probed
# признак «установилось и замерло» — решает адрес: сайт целиком резолвится на
# соседний рабочий узел CDN и дал бы «живой»
P='. /usr/bin/blockwatch >/dev/null 2>&1
get() { case "$*" in *socks5*) echo 200 ;; *--resolve*) echo "200~" ;; *) echo 200 ;; esac; }'
R=$(sh -c "$P; probe 138.199.46.65 cdn.example обрыв+молчит")
check "обрыв: сайт не спасает, решает адрес" test "$R" = "- 200~ 200"
check "обрыв: вердикт — заблокирован" test "$(V '-' '200~' 200)" = "ЗАБЛОКИРОВАН"
R=$(sh -c "$P; probe 162.159.136.232 discord.example нет-ответа")
check "нет ответа: соседний адрес ответил — сайт живой" test "$R" = "200 - -"
check "in_range fakeip" sh -c '. /usr/bin/blockwatch >/dev/null 2>&1; in_range 198.19.3.4 198.18.0.0/15'
check "in_range чужой" sh -c '. /usr/bin/blockwatch >/dev/null 2>&1; ! in_range 198.20.0.1 198.18.0.0/15'
check "in_nets: одна из многих" sh -c '. /usr/bin/blockwatch >/dev/null 2>&1; in_nets 172.217.132.74 10.0.0.0/8 172.217.0.0/16 && ! in_nets 151.101.2.132 10.0.0.0/8 172.217.0.0/16'
# снимок IP-множества: вывод nft как на роутере — подсети, диапазоны, адреса, перенос строк
SC='. /usr/bin/blockwatch >/dev/null 2>&1; NFT_TABLE=T; NFT_SET=S
nft() { printf "%s\n" "table inet T {" "	set S {" "		type ipv4_addr" "		flags interval" \
    "		elements = { 1.0.0.0/24, 8.6.112.0/24," "			     104.16.0.0-104.16.0.255, 149.154.167.50 }" "	}" "}"; }
set_cache'
check "снимок: подсеть" sh -c "$SC; in_backend_set 8.6.112.9"
check "снимок: диапазон" sh -c "$SC; in_backend_set 104.16.0.200"
check "снимок: одиночный адрес" sh -c "$SC; in_backend_set 149.154.167.50"
check "снимок: чужой адрес" sh -c "$SC; ! in_backend_set 8.6.113.1 && ! in_backend_set 149.154.167.51"
rm -f /tmp/blockwatch/set.cache.*

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

echo "== карта имён: имя запроса, а не конец CNAME"
# строки с домашнего роутера: www.noodledude.io за Vercel
cat > /tmp/bw-log <<'EOF'
Mon Sep 28 21:29:50 2026 daemon.info dnsmasq[1]: 106320 192.168.1.249/5002 query[A] 74db6ff77fea4b2e.vercel-dns-016.com from 192.168.1.249
Mon Sep 28 21:29:50 2026 daemon.info dnsmasq[1]: 106320 192.168.1.249/5002 reply 74db6ff77fea4b2e.vercel-dns-016.com is 216.150.99.1
Mon Sep 28 21:29:58 2026 daemon.info dnsmasq[1]: 106324 192.168.1.249/51251 query[A] www.noodledude.io from 192.168.1.249
Mon Sep 28 21:29:58 2026 daemon.info dnsmasq[1]: 106324 192.168.1.249/51251 forwarded www.noodledude.io to 127.0.0.42
Mon Sep 28 21:29:58 2026 daemon.info dnsmasq[1]: 106327 192.168.1.249/56630 query[A] plain.example.com from 192.168.1.249
Mon Sep 28 21:29:58 2026 daemon.info dnsmasq[1]: 106327 192.168.1.249/56630 reply plain.example.com is 203.0.113.5
Mon Sep 28 21:29:58 2026 daemon.info dnsmasq[1]: 106324 192.168.1.249/51251 reply www.noodledude.io is <CNAME>
Mon Sep 28 21:29:58 2026 daemon.info dnsmasq[1]: 106324 192.168.1.249/51251 reply 74db6ff77fea4b2e.vercel-dns-016.com is 216.150.1.65
Mon Sep 28 21:29:58 2026 daemon.info dnsmasq[1]: 106324 192.168.1.249/51251 reply 74db6ff77fea4b2e.vercel-dns-016.com is 216.150.16.65
Mon Sep 28 21:30:01 2026 daemon.info dnsmasq[1]: 106330 192.168.1.249/5000 query[A] cdn.example.org from 192.168.1.249
Mon Sep 28 21:30:01 2026 daemon.info dnsmasq[1]: 106330 192.168.1.249/5000 cached cdn.example.org is <CNAME>
Mon Sep 28 21:30:01 2026 daemon.info dnsmasq[1]: 106330 192.168.1.249/5000 cached edge.cdnprovider.net is 198.51.100.7
Mon Sep 28 21:30:01 2026 daemon.info dnsmasq[1]: 106331 192.168.1.249/5001 query[A] 74db6ff77fea4b2e.vercel-dns-016.com from 192.168.1.249
Mon Sep 28 21:30:01 2026 daemon.info dnsmasq[1]: 106331 192.168.1.249/5001 reply 74db6ff77fea4b2e.vercel-dns-016.com is 216.150.1.1
Mon Sep 28 21:30:02 2026 daemon.info dnsmasq[2]: query[A] old.example.net from 192.168.1.20
Mon Sep 28 21:30:02 2026 daemon.info dnsmasq[2]: reply old.example.net is <CNAME>
Mon Sep 28 21:30:02 2026 daemon.info dnsmasq[2]: reply old.cdn.example is 198.51.100.9
EOF
M=$(sh -c '. /usr/bin/blockwatch >/dev/null 2>&1; logread() { cat /tmp/bw-log; }; DIR=/tmp/bw-map; mkdir -p $DIR; : > $DIR/ipmap; update_ipmap; cat $DIR/ipmap')
# старая карта, где устаревшая привязка стоит последней: свежая должна её перебить
O=$(sh -c '. /usr/bin/blockwatch >/dev/null 2>&1; logread() { cat /tmp/bw-log; }; DIR=/tmp/bw-map
    printf "216.150.1.65 www.noodledude.io\n216.150.1.65 74db6ff77fea4b2e.vercel-dns-016.com\n" > $DIR/ipmap
    rm -f $DIR/ipmap.sum; update_ipmap; domain_of 216.150.1.65')
# тот же журнал второй раз карту не трогает — слияние пропускается
P=$(sh -c '. /usr/bin/blockwatch >/dev/null 2>&1; logread() { cat /tmp/bw-log; }; DIR=/tmp/bw-map
    echo "203.0.113.99 marker.example" >> $DIR/ipmap; update_ipmap; tail -1 $DIR/ipmap')
rm -rf /tmp/bw-map /tmp/bw-log
check "CNAME: адрес под именем запроса" sh -c "echo \"\$0\" | grep -qx '216.150.1.65 www.noodledude.io'" "$M"
check "CNAME: второй адрес тоже" sh -c "echo \"\$0\" | grep -qx '216.150.16.65 www.noodledude.io'" "$M"
check "служебное имя, спрошенное напрямую, — тоже на сайт" sh -c "echo \"\$0\" | grep -qx '216.150.1.1 www.noodledude.io'" "$M"
check "служебное имя, спрошенное до цепочки, — тоже на сайт" sh -c "echo \"\$0\" | grep -qx '216.150.99.1 www.noodledude.io'" "$M"
check "свежая привязка перебивает устаревшую" test "$O" = www.noodledude.io
check "тот же журнал — без слияния" test "$P" = "203.0.113.99 marker.example"
check "CNAME: служебного имени нет" sh -c "! echo \"\$0\" | grep -q vercel-dns" "$M"
check "простой ответ не задет" sh -c "echo \"\$0\" | grep -qx '203.0.113.5 plain.example.com'" "$M"
check "CNAME из кэша" sh -c "echo \"\$0\" | grep -qx '198.51.100.7 cdn.example.org'" "$M"
check "журнал без номеров: цепочка по соседним строкам" sh -c "echo \"\$0\" | grep -qx '198.51.100.9 old.example.net'" "$M"

echo "== вердикт на пару «адрес + имя»"
# probe подменён: сеть в chroot не нужна, важно только, дошло ли до проверки
CK='. /usr/bin/blockwatch >/dev/null 2>&1
probe() { echo "$PROBE" >> /tmp/bw-probed; echo "200~ 200~ 200"; }
now=10000; checked=0; checked_run=0'
echo "216.150.1.193|74db6ff77fea4b2e.vercel-dns-016.com|живой|0|9000|9000|обход|000~/404/000~" > /tmp/blockwatch/verdicts
: > /tmp/bw-probed
sh -c "$CK; PROBE=www; check_one 216.150.1.193 обход www.noodledude.io"
check "новое имя на проверенном адресе проверяется" grep -qx www /tmp/bw-probed
check "вердикт нового имени записан" grep -q '^216.150.1.193|www.noodledude.io|ЗАБЛОКИРОВАН|1|' /tmp/blockwatch/verdicts
check "вердикт соседа по адресу сохранён" grep -q '^216.150.1.193|74db6ff77fea4b2e.vercel-dns-016.com|живой|' /tmp/blockwatch/verdicts
sh -c "$CK; PROBE=again; check_one 216.150.1.193 обход 74db6ff77fea4b2e.vercel-dns-016.com"
check "решённая пара ждёт RECHECK" sh -c "! grep -qx again /tmp/bw-probed"

echo "== повторная проверка через 15 минут"
cat > /tmp/blockwatch/verdicts <<'EOF'
203.0.113.23|ancient.example.com|лежит|0|5000|5000|нет-ответа|000~/000~/000~
203.0.113.24|older.example.com|лежит|0|20000|20000|нет-ответа|000~/000~/000~
216.150.1.1|noodledude.io|лежит|0|28000|28000|нет-ответа|000~/000~/000~
203.0.113.20|dead.example.com|лежит|0|1000|28000|нет-ответа|000~/000~/000~
203.0.113.21|half.example.com|ЗАБЛОКИРОВАН|1|28000|28000|обрыв|200~/200~/200
203.0.113.22|fresh.example.com|лежит|0|29900|29900|нет-ответа|000~/000~/000~
203.0.113.25|edge.cdn.example|лежит|0|28000|28000|обход|000~/000~/000~
EOF
R=$(sh -c '. /usr/bin/blockwatch >/dev/null 2>&1; now=30000; redo_list')
check "«лежит» один раз — в повтор" sh -c "echo \"\$0\" | grep -qx '216.150.1.1 нет-ответа noodledude.io'" "$R"
check "«лежит» дважды — не в повтор" sh -c "! echo \"\$0\" | grep -q dead.example.com" "$R"
check "недоподтверждённое — в повтор" sh -c "echo \"\$0\" | grep -q half.example.com" "$R"
check "моложе 5 минут — не в повтор" sh -c "! echo \"\$0\" | grep -q fresh.example.com" "$R"
check "«лежит» из обхода — не в повтор" sh -c "! echo \"\$0\" | grep -q edge.cdn.example" "$R"
check "«лежит» старше RECHECK — не в повтор" sh -c "! echo \"\$0\" | grep -q ancient.example.com" "$R"
check "свежие — первыми" test "$(echo "$R" | grep -E 'noodledude|older' | head -1 | cut -d' ' -f3)" = noodledude.io
: > /tmp/bw-probed
sh -c "$CK; now=30000; PROBE=down1; check_one 216.150.1.1 нет-ответа noodledude.io"
check "«лежит» один раз перепроверяется" grep -qx down1 /tmp/bw-probed
check "после повтора first остался прежним" grep -q '^216.150.1.1|noodledude.io|ЗАБЛОКИРОВАН|1|28000|30000|' /tmp/blockwatch/verdicts
rm -f /tmp/blockwatch/verdicts /tmp/bw-probed

echo "== после 0.1.0: её «лежит» недостоверны"
V3='203.0.113.30|down.example.com|лежит|0|1|1|обход|000~/000~/000~
203.0.113.31|up.example.com|живой|0|1|1|обход|200/-/-
203.0.113.33|hit.example.com|ЗАБЛОКИРОВАН|2|1|1|обрыв|200~/200~/200'
rm -f /etc/blockwatch/verdicts.v; echo "$V3" > /tmp/blockwatch/verdicts
sh -c '. /usr/bin/blockwatch >/dev/null 2>&1; forget_stale_verdicts'
check "с 0.1.0: «лежит» выброшено" sh -c "! grep -q down.example.com /tmp/blockwatch/verdicts"
check "с 0.1.0: «живой» выброшен" sh -c "! grep -q up.example.com /tmp/blockwatch/verdicts"
check "с 0.1.0: находка осталась" grep -q hit.example.com /tmp/blockwatch/verdicts
echo 2 > /etc/blockwatch/verdicts.v; echo "$V3" > /tmp/blockwatch/verdicts
sh -c '. /usr/bin/blockwatch >/dev/null 2>&1; forget_stale_verdicts'
check "с версии 2: «лежит» остался" grep -q down.example.com /tmp/blockwatch/verdicts
check "с версии 2: «живой» выброшен" sh -c "! grep -q up.example.com /tmp/blockwatch/verdicts"
echo "$V3" > /tmp/blockwatch/verdicts
sh -c '. /usr/bin/blockwatch >/dev/null 2>&1; forget_stale_verdicts'
check "чистка только один раз" grep -q up.example.com /tmp/blockwatch/verdicts
# «живой», по которому снова есть признак в трафике, — через час, а не через 6 часов
echo "203.0.113.40|cdn.example|живой|0|1000|1000|обход|200/-/-" > /tmp/blockwatch/verdicts
: > /tmp/bw-probed
sh -c "$CK; now=5000; PROBE=sym; check_one 203.0.113.40 обрыв cdn.example"
check "«живой» + обрыв через час — проверяется" grep -qx sym /tmp/bw-probed
echo "203.0.113.40|cdn.example|живой|0|1000|1000|обход|200/-/-" > /tmp/blockwatch/verdicts
: > /tmp/bw-probed
sh -c "$CK; now=5000; PROBE=sweep; check_one 203.0.113.40 обход cdn.example"
check "«живой» + обход — ждёт 6 часов" sh -c "! grep -qx sweep /tmp/bw-probed"
# порядок кандидатов: «1 из 2» — первыми, потом без вердикта, потом прочие
printf '%s\n' '203.0.113.60|old.example|живой|0|1|1|обход|200/-/-' \
    '203.0.113.61|pend.example|ЗАБЛОКИРОВАН|1|1|1|обрыв|200~/200~/200' > /tmp/blockwatch/verdicts
cp /tmp/blockwatch/ipmap /tmp/bw-ipmap.save 2>/dev/null; echo "203.0.113.63 named.example" > /tmp/blockwatch/ipmap
O=$(printf '203.0.113.60 сброс\n203.0.113.62 молчит\n203.0.113.64 молчит+обрыв\n203.0.113.63 сброс\n203.0.113.61 молчит\n' |
    sh -c '. /usr/bin/blockwatch >/dev/null 2>&1; cand_order' | awk '{print $1}' | tr '\n' ' ')
mv /tmp/bw-ipmap.save /tmp/blockwatch/ipmap 2>/dev/null || rm -f /tmp/blockwatch/ipmap
check "порядок: 1 из 2, обрыв, с именем, без имени, прочие" test "$O" = "203.0.113.61 203.0.113.64 203.0.113.63 203.0.113.62 203.0.113.60 "
# человек снова открыл сайт — второе подтверждение через минуту, а не через 5
echo "203.0.113.61|pend.example|ЗАБЛОКИРОВАН|1|1000|1000|обрыв|200~/200~/200" > /tmp/blockwatch/verdicts
: > /tmp/bw-probed
sh -c "$CK; now=1070; PROBE=f5; check_one 203.0.113.61 обрыв pend.example"
check "повторный заход через минуту — подтверждение" grep -qx f5 /tmp/bw-probed
echo "203.0.113.61|pend.example|ЗАБЛОКИРОВАН|1|1000|1000|обрыв|200~/200~/200" > /tmp/blockwatch/verdicts
: > /tmp/bw-probed
sh -c "$CK; now=1070; PROBE=sw; check_one 203.0.113.61 обход pend.example"
check "обход — ждёт confirm_minutes" sh -c "! grep -qx sw /tmp/bw-probed"
# туннель не ответил на подтверждении — находка не теряется, но только один раз
echo "203.0.113.50|flaky.example|ЗАБЛОКИРОВАН|1|1000|1000|обрыв|200~/200~/200" > /tmp/blockwatch/verdicts
IN='. /usr/bin/blockwatch >/dev/null 2>&1; probe() { echo "200~ 200~ 000~"; }; checked=0; checked_run=0'
sh -c "$IN; now=2000; check_one 203.0.113.50 обрыв flaky.example"
check "туннель не ответил — «1 из 2» держится" grep -q '^203.0.113.50|flaky.example|ЗАБЛОКИРОВАН|1|1000|2000|обрыв|200~/200~/000~$' /tmp/blockwatch/verdicts
sh -c "$IN; now=3000; check_one 203.0.113.50 обрыв flaky.example"
check "и второй раз подряд — сдаётся" grep -q '^203.0.113.50|flaky.example|лежит|0|' /tmp/blockwatch/verdicts
echo "203.0.113.50|flaky.example|ЗАБЛОКИРОВАН|1|1000|1000|обрыв|200~/200~/200" > /tmp/blockwatch/verdicts
sh -c ". /usr/bin/blockwatch >/dev/null 2>&1; probe() { echo '200 - -'; }; checked=0; checked_run=0; now=2000; check_one 203.0.113.50 обрыв flaky.example"
check "ответ напрямую — сбрасывает" grep -q '^203.0.113.50|flaky.example|живой|0|' /tmp/blockwatch/verdicts
rm -f /tmp/blockwatch/verdicts /etc/blockwatch/verdicts.v /tmp/bw-probed /tmp/blockwatch/state.dirty

echo "== пределы: список, журнал, запись на флеш"
printf '# шапка\na.example\nb.example\nc.example\n' > /tmp/bw-dom.txt
E=$(sh -c '. /usr/bin/blockwatch >/dev/null 2>&1; DOMAINS_FILE=/tmp/bw-dom.txt; MAX_TOTAL=3
    pending() { echo new.example; }; export_domains auto | jq -r .mode')
check "полный список: новые не добавляются" test "$E" = full
check "полный список: файл не тронут" sh -c "! grep -q new.example /tmp/bw-dom.txt"
Q=$(sh -c '. /usr/bin/blockwatch >/dev/null 2>&1; DOMAINS_FILE=/tmp/bw-dom.txt; MAX_TOTAL=3; problems')
check "полный список: предупреждение" sh -c "echo \"\$0\" | grep -q 'достиг предела 3'" "$Q"
Q=$(sh -c '. /usr/bin/blockwatch >/dev/null 2>&1; DOMAINS_FILE=/tmp/bw-dom.txt; MAX_TOTAL=4; problems')
check "есть место: без предупреждения" sh -c "! echo \"\$0\" | grep -q 'достиг предела'" "$Q"
rm -f /tmp/bw-dom.txt
sh -c '. /usr/bin/blockwatch >/dev/null 2>&1; LOG=/tmp/bw-log.txt; LOG_KEEP=5
    for i in $(seq 1 106); do log_find "запись $i"; done'
check "журнал обрезан до LOG_KEEP" test "$(wc -l < /tmp/bw-log.txt)" = 5
check "в журнале остались последние" grep -q 'запись 106$' /tmp/bw-log.txt
rm -f /tmp/bw-log.txt
mkdir -p /tmp/blockwatch /tmp/bw-st
echo "1.2.3.4|old.example|живой|0|1|1|обход|200/-/-" > /tmp/bw-st/verdicts
echo "1.2.3.4|new.example|живой|0|2|2|обход|200/-/-" > /tmp/blockwatch/verdicts
S='. /usr/bin/blockwatch >/dev/null 2>&1; STATE_DIR=/tmp/bw-st; STATE=/tmp/bw-st/verdicts'
sh -c "$S; save_state"
check "свежее сохранение: на флеш не пишем" grep -q old.example /tmp/bw-st/verdicts
touch /tmp/blockwatch/state.dirty
sh -c "$S; save_state"
check "после находки: пишем сразу" grep -q new.example /tmp/bw-st/verdicts
check "метка находки снята" test ! -f /tmp/blockwatch/state.dirty
echo "1.2.3.4|newer.example|живой|0|3|3|обход|200/-/-" > /tmp/blockwatch/verdicts
sh -c "$S; STATE_EVERY=0; save_state"
check "прошёл час: пишем" grep -q newer.example /tmp/bw-st/verdicts
rm -rf /tmp/bw-st /tmp/blockwatch/verdicts

echo "== обрыв на маленьком ответе: повтор в одном соединении"
# curl подменён: одиночный запрос отдаёт 505 байт; повтор (много URL сразу)
# либо висит — как оборванное соединение, — либо проходит
G='. /usr/bin/blockwatch >/dev/null 2>&1; BULK_TIME=2
curl() { case "$*" in *"%{http_code}"*) printf "200 505"; return 0 ;; esac
         [ "$MODE" = cut ] && { sleep 30; return 0; }; return 0; }'
S=$(date +%s)
R=$(sh -c "$G; MODE=cut; get 9 https://cdn.example/")
check "маленький ответ + оборванный повтор — 200~" test "$R" = "200~"
check "повтор ограничен по времени" test $(( $(date +%s) - S )) -le 6
R=$(sh -c "$G; MODE=ok; get 9 https://cdn.example/")
check "маленький ответ + целый повтор — 200" test "$R" = "200"
R=$(sh -c '. /usr/bin/blockwatch >/dev/null 2>&1; curl() { printf "200 50000"; }; bulk() { echo called >> /tmp/bw-bulk; return 1; }; get 9 https://big.example/')
check "большой ответ — без повтора" sh -c "test '$R' = 200 && test ! -f /tmp/bw-bulk"
rm -f /tmp/bw-bulk
R=$(sh -c '. /usr/bin/blockwatch >/dev/null 2>&1; curl() { printf "200 548255"; return 28; }; get 9 https://slow.example/')
check "таймаут на большой странице — не обрыв" test "$R" = 200
R=$(sh -c '. /usr/bin/blockwatch >/dev/null 2>&1; curl() { printf "200 13037"; return 28; }; get 9 https://cut.example/')
check "замерло на 13 КБ — обрыв" test "$R" = "200~"

echo "== перепроверка списка"
mkdir -p /tmp/blockwatch /tmp/bw-rs
printf '# 2026-09-29 10:00\nopen.example\nshut.example\nbyip.example\n' > /tmp/bw-rd.txt
echo '{"version":3,"rules":[{"domain_suffix":["byip.example","open.example","shut.example"]}]}' > /tmp/bw-rs/rs.json
echo "1.1.1.1|open.example|ЗАБЛОКИРОВАН|2|1|1|обрыв|200~/200~/200" > /tmp/blockwatch/verdicts
RC='. /usr/bin/blockwatch >/dev/null 2>&1
DOMAINS_FILE=/tmp/bw-rd.txt; LISTED=/tmp/bw-listed; LOG=/tmp/bw-rlog; REMOVE_AFTER=2
checked=0; checked_run=0
dns_a() { case "$1" in byip.*) echo 104.16.0.1 ;; *) echo 203.0.113.50 ;; esac; }
in_backend_set() { [ "$1" = 104.16.0.1 ]; }
get() { case "$*" in *open.example*) echo 200 ;; *) echo "200~" ;; esac; }
live_ruleset() { echo /tmp/bw-rs/rs.json; }'
rm -f /tmp/bw-listed /tmp/bw-rlog
check "все три — на перепроверку" test "$(sh -c "$RC; now=1000; RECHECK_LISTED=259200; listed_due" | wc -l)" = 3
for t in 1000 2000; do sh -c "$RC; now=$t; RECHECK_LISTED=0; for d in open.example shut.example byip.example; do recheck_one \$d; done"; done
check "открывшийся напрямую убран из файла" sh -c "! grep -qx open.example /tmp/bw-rd.txt"
check "…и из живого набора" sh -c "! jq -r '.rules[0].domain_suffix[]' /tmp/bw-rs/rs.json | grep -qx open.example"
check "…и из вердиктов" sh -c "! grep -q open.example /tmp/blockwatch/verdicts"
check "…и записан в журнал" grep -q 'УБРАН open.example' /tmp/bw-rlog
check "заблокированный остался" grep -qx shut.example /tmp/bw-rd.txt
check "заблокированный: серия удач 0" grep -q '^shut.example|2000|0|200~|заблокирован$' /tmp/bw-listed
check "адрес в IP-списке — не проверяется и остаётся" sh -c "grep -qx byip.example /tmp/bw-rd.txt && grep -q '^byip.example|2000|0|-|по-адресу$' /tmp/bw-listed"
printf 'keep.example\n' >> /tmp/bw-rd.txt
sh -c "$RC; now=3000; RECHECK_LISTED=0; get() { echo 200; }; recheck_one keep.example"
sh -c "$RC; now=4000; RECHECK_LISTED=0; get() { echo '200~'; }; recheck_one keep.example"
check "неудача обнуляет серию" grep -q '^keep.example|4000|0|' /tmp/bw-listed
D=$(sh -c "$RC; now=100000; RECHECK_LISTED=259200; listed_due")
check "после неудачи — ждёт полный интервал" sh -c "! echo \"\$0\" | grep -qx keep.example" "$D"
sh -c "$RC; now=5000; RECHECK_LISTED=259200; get() { echo 200; }; recheck_one keep.example"
D=$(sh -c "$RC; now=95000; RECHECK_LISTED=259200; listed_due")
check "после удачи — через сутки" sh -c "echo \"\$0\" | grep -qx keep.example" "$D"
sh -c "$RC; now=6000; RECHECK_LISTED=0; AUTO_REMOVE=0; get() { echo 200; }; recheck_one keep.example"
check "auto_remove=0 — не убирает" grep -qx keep.example /tmp/bw-rd.txt
rm -rf /tmp/bw-rd.txt /tmp/bw-rs /tmp/bw-listed /tmp/bw-rlog /tmp/blockwatch/verdicts
N=$(sh -c '. /usr/bin/blockwatch >/dev/null 2>&1; checked=0; checked_run=0; MAX_TICK=2
    sweep_filter() { printf "203.0.113.1 a.example\n203.0.113.2 b.example\n203.0.113.3 c.example\n"; }
    check_one() { checked=$((checked + 1)); }
    sweep 1; echo $checked')
check "обход с пределом 1 — одна проверка" test "$N" = 1
echo "manual.example" >> /etc/blockwatch/domains.txt; echo "203.0.113.77" >> /etc/blockwatch/subnets.txt
blockwatch remove manual.example > /tmp/rm.out 2>&1
check "remove: домен убран" sh -c "! grep -qx manual.example /etc/blockwatch/domains.txt"
check "remove: в журнале «вручную»" grep -q 'УБРАН manual.example вручную' /etc/blockwatch/blockwatch.log
blockwatch remove 203.0.113.77 > /tmp/rm.out 2>&1
check "remove: адрес убран" sh -c "! grep -qx 203.0.113.77 /etc/blockwatch/subnets.txt"
check "remove: чужого нет — ошибка" sh -c "! blockwatch remove nothere.example >/dev/null 2>&1"
blockwatch status > /tmp/s.json 2>/dev/null
check "status: адреса, журнал, ожидающие адреса" jq -e '(.ips | type == "array") and (.log | type == "array") and (.pending_ips | type == "array") and (.ips_hooked | type == "boolean")' /tmp/s.json
check "status: настройки перепроверки" jq -e '.recheck.hours == 72 and .recheck.remove_after == 3 and .recheck.auto_remove == true and (.removed | type == "array")' /tmp/s.json

echo "== адреса: без имени и общие"
mkdir -p /tmp/blockwatch
cp /tmp/blockwatch/ipmap /tmp/bw-ipmap.save 2>/dev/null
printf '%s\n' '8.6.112.6 eshop-prices.com' '8.6.112.6 checkonline.home-assistant.io' '8.6.112.6 api.ipify.org' \
    '203.0.113.90 one.example' '142.250.1.1 www.youtube.com' '142.250.1.1 other.example' \
    '198.51.100.20 site.ru' '198.51.100.20 x.example' > /tmp/blockwatch/ipmap
N=$(date +%s)
cat > /tmp/blockwatch/verdicts <<EOF
8.6.112.6|checkonline.home-assistant.io|ЗАБЛОКИРОВАН|2|1|$N|обрыв|-/200~/200
203.0.113.90|one.example|ЗАБЛОКИРОВАН|2|1|$N|обрыв|-/200~/200
203.0.113.91|-|ЗАБЛОКИРОВАН|2|1|$N|молчит|000~/000~/200
203.0.113.92|-|ЗАБЛОКИРОВАН|1|1|$N|молчит|000~/000~/200
142.250.1.1|other.example|ЗАБЛОКИРОВАН|2|1|$N|обрыв|-/200~/200
198.51.100.20|x.example|ЗАБЛОКИРОВАН|2|1|$N|обрыв|-/200~/200
10.0.0.5|-|ЗАБЛОКИРОВАН|2|1|$N|молчит|000~/000~/200
EOF
IPS='. /usr/bin/blockwatch >/dev/null 2>&1; SUBNETS_FILE=/tmp/bw-sub.txt; SUBNETS_META=/tmp/bw-sub.meta
DOMAINS_FILE=/tmp/bw-dom2.txt; LOG=/tmp/bw-iplog; in_backend_set() { return 1; }; via_backend() { return 1; }
proxy_ips() { echo 203.0.113.99; }'
rm -f /tmp/bw-sub.txt /tmp/bw-sub.meta /tmp/bw-dom2.txt /tmp/bw-iplog
check "общий адрес — три имени — общий" sh -c "$IPS; shared_ips | grep -qx 8.6.112.6"
PD=$(sh -c "$IPS; pending" | tr '\n' ' ')
check "общий адрес по признаку: имя-догадку не добавлять" sh -c "! echo \"\$0\" | grep -q checkonline" "$PD"
check "свой адрес у сайта — добавляется домен" sh -c "echo \"\$0\" | grep -q one.example" "$PD"
PI=$(sh -c "$IPS; pending_ips" | tr '\n' ' ')
check "общий адрес — в адреса" sh -c "echo \"\$0\" | grep -q 8.6.112.6" "$PI"
check "без имени — в адреса" sh -c "echo \"\$0\" | grep -q 203.0.113.91" "$PI"
check "без имени, 1 из 2 — ещё нет" sh -c "! echo \"\$0\" | grep -q 203.0.113.92" "$PI"
check "свой адрес у сайта — не в адреса" sh -c "! echo \"\$0\" | grep -q 203.0.113.90" "$PI"
check "адрес с YouTube — никогда" sh -c "! echo \"\$0\" | grep -q 142.250.1.1" "$PI"
check "адрес с .ru — никогда" sh -c "! echo \"\$0\" | grep -q 198.51.100.20" "$PI"
check "частный адрес — никогда" sh -c "! echo \"\$0\" | grep -q 10.0.0.5" "$PI"
check "сеть Google без имени — никогда" sh -c ". /usr/bin/blockwatch >/dev/null 2>&1; SUBNETS_FILE=/tmp/bw-none; in_backend_set() { return 1; }; build_never; : > /tmp/blockwatch/proxy-ips; ! ip_ok 172.217.132.74 && ! ip_ok 173.194.183.135 && ip_ok 151.101.2.132"
sh -c "$IPS; inject_ips() { echo \"\$1\" > /tmp/bw-injected; return 0; }; export_ips auto"
check "добавлен в файл адресов" sh -c "grep -qx 8.6.112.6 /tmp/bw-sub.txt && grep -qx 203.0.113.91 /tmp/bw-sub.txt"
check "…и в метаданные с именами" grep -q '^8.6.112.6|[0-9]*|api.ipify.org,checkonline.home-assistant.io,eshop-prices.com$' /tmp/bw-sub.meta
check "…и вписан на лету" grep -qx 8.6.112.6 /tmp/bw-injected
check "…и в журнал" grep -q 'ДОБАВЛЕН-АДРЕС 8.6.112.6' /tmp/bw-iplog
check "повторно не добавляется" sh -c ". /usr/bin/blockwatch >/dev/null 2>&1; SUBNETS_FILE=/tmp/bw-sub.txt; in_backend_set() { return 1; }; proxy_ips() { :; }; build_never; : > /tmp/blockwatch/proxy-ips; ! ip_ok 8.6.112.6"
check "адрес прокси-сервера — никогда" sh -c ". /usr/bin/blockwatch >/dev/null 2>&1; SUBNETS_FILE=/tmp/bw-sub.txt; in_backend_set() { return 1; }; build_never; echo 203.0.113.99 > /tmp/blockwatch/proxy-ips; ! ip_ok 203.0.113.99"
# срок жизни
awk -F'|' -v OFS='|' '$1 == "203.0.113.91" { $2 = 1 } { print }' /tmp/bw-sub.meta > /tmp/bw-sub.m2 && mv /tmp/bw-sub.m2 /tmp/bw-sub.meta
sh -c "$IPS; live_subnet_ruleset() { return 1; }; nft() { :; }; now=\$(date +%s); expire_ips"
check "истёкший адрес убран из файла" sh -c "! grep -qx 203.0.113.91 /tmp/bw-sub.txt"
check "…и из метаданных" sh -c "! grep -q '^203.0.113.91|' /tmp/bw-sub.meta"
check "…и из вердиктов — найдётся заново" sh -c "! grep -q '^203.0.113.91|' /tmp/blockwatch/verdicts"
check "…и записан в журнал" grep -q 'ИСТЁК-АДРЕС 203.0.113.91' /tmp/bw-iplog
check "свежий адрес остался" grep -qx 8.6.112.6 /tmp/bw-sub.txt
rm -f /tmp/bw-sub.txt /tmp/bw-sub.meta /tmp/bw-dom2.txt /tmp/bw-iplog /tmp/bw-injected /tmp/blockwatch/verdicts /tmp/blockwatch/state.dirty
mv /tmp/bw-ipmap.save /tmp/blockwatch/ipmap 2>/dev/null || rm -f /tmp/blockwatch/ipmap

echo "== hook / unhook"
blockwatch hook main >/dev/null 2>&1
check "hook добавил путь" sh -c "uci -q get netshift.main.local_domain_lists | grep -q /etc/blockwatch/domains.txt"
check "hook добавил и список адресов" sh -c "uci -q get netshift.main.local_subnet_lists | grep -q /etc/blockwatch/subnets.txt"
blockwatch status > /tmp/s.json 2>/dev/null
check "status: подключён" jq -e '.hooked == true and .section == "main"' /tmp/s.json
blockwatch hook main >/dev/null 2>&1
check "повторный hook не дублирует" test "$(uci -q get netshift.main.local_domain_lists | wc -w)" = 1
# набор собран, но конфиг sing-box на него не ссылается: так netshift собирает
# конфиг, когда файл набора пережил очистку при наложившихся перезапусках
mkdir -p /tmp/sing-box/rulesets
echo '{"version":3,"rules":[{"domain_suffix":["linkmydroid.com"]}]}' > /tmp/sing-box/rulesets/main-local-domains-ruleset.json
cp /etc/sing-box/config.json /tmp/sb-config.orig
blockwatch status > /tmp/s.json 2>/dev/null
check "не подключён к sing-box: wired=false" jq -e '.wired == false' /tmp/s.json
check "не подключён к sing-box: есть проблема" jq -e '[.problems[] | select(contains("без списка blockwatch"))] | length == 1' /tmp/s.json
jq '.route.rule_set = [{"tag": "main-local-domains-ruleset", "type": "local", "format": "source",
                        "path": "/tmp/sing-box/rulesets/main-local-domains-ruleset.json"}]
    | .dns.rules = [{"action": "route", "server": "fakeip-server",
                     "rule_set": ["main-local-domains-ruleset"]}]' /tmp/sb-config.orig > /etc/sing-box/config.json
blockwatch status > /tmp/s.json 2>/dev/null
check "подключён к sing-box: wired=true" jq -e '.wired == true' /tmp/s.json
check "подключён к sing-box: проблемы нет" jq -e '[.problems[] | select(contains("без списка blockwatch"))] | length == 0' /tmp/s.json
cp /etc/blockwatch/domains.txt /tmp/dom.save 2>/dev/null
printf '# 2026-09-29 10:00\nlinkmydroid.com\nnotyet.example\n' > /etc/blockwatch/domains.txt
blockwatch status > /tmp/s.json 2>/dev/null
check "в туннеле — домен есть в подключённом наборе" jq -e '[.added[] | select(.domain == "linkmydroid.com" and .live and .at == "2026-09-29 10:00")] | length == 1' /tmp/s.json
check "ещё не применён — домена нет в наборе" jq -e '[.added[] | select(.domain == "notyet.example" and (.live | not))] | length == 1' /tmp/s.json
mv /tmp/dom.save /etc/blockwatch/domains.txt 2>/dev/null || : > /etc/blockwatch/domains.txt
jq '.dns.rules = []' /etc/sing-box/config.json > /tmp/sb-config.nodns && cp /tmp/sb-config.nodns /etc/sing-box/config.json
check "в route есть, в DNS нет — не подключён" sh -c '. /usr/bin/blockwatch >/dev/null 2>&1; ! ruleset_wired'
cp /tmp/sb-config.orig /etc/sing-box/config.json
rm -rf /tmp/sing-box /tmp/sb-config.orig /tmp/sb-config.nodns
blockwatch unhook >/dev/null 2>&1
check "unhook убрал путь" sh -c "! uci -q get netshift.main.local_domain_lists"
check "unhook убрал и список адресов" sh -c "! uci -q get netshift.main.local_subnet_lists"

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
