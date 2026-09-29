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
203.0.113.22|fresh.example.com|лежит|0|29500|29500|нет-ответа|000~/000~/000~
203.0.113.25|edge.cdn.example|лежит|0|28000|28000|обход|000~/000~/000~
EOF
R=$(sh -c '. /usr/bin/blockwatch >/dev/null 2>&1; now=30000; redo_list')
check "«лежит» один раз — в повтор" sh -c "echo \"\$0\" | grep -qx '216.150.1.1 нет-ответа noodledude.io'" "$R"
check "«лежит» дважды — не в повтор" sh -c "! echo \"\$0\" | grep -q dead.example.com" "$R"
check "недоподтверждённое — в повтор" sh -c "echo \"\$0\" | grep -q half.example.com" "$R"
check "моложе 15 минут — не в повтор" sh -c "! echo \"\$0\" | grep -q fresh.example.com" "$R"
check "«лежит» из обхода — не в повтор" sh -c "! echo \"\$0\" | grep -q edge.cdn.example" "$R"
check "«лежит» старше RECHECK — не в повтор" sh -c "! echo \"\$0\" | grep -q ancient.example.com" "$R"
check "свежие — первыми" test "$(echo "$R" | grep -E 'noodledude|older' | head -1 | cut -d' ' -f3)" = noodledude.io
: > /tmp/bw-probed
sh -c "$CK; now=30000; PROBE=down1; check_one 216.150.1.1 нет-ответа noodledude.io"
check "«лежит» один раз перепроверяется" grep -qx down1 /tmp/bw-probed
check "после повтора first остался прежним" grep -q '^216.150.1.1|noodledude.io|ЗАБЛОКИРОВАН|1|28000|30000|' /tmp/blockwatch/verdicts
rm -f /tmp/blockwatch/verdicts /tmp/bw-probed

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

echo "== hook / unhook"
blockwatch hook main >/dev/null 2>&1
check "hook добавил путь" sh -c "uci -q get netshift.main.local_domain_lists | grep -q /etc/blockwatch/domains.txt"
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
jq '.dns.rules = []' /etc/sing-box/config.json > /tmp/sb-config.nodns && cp /tmp/sb-config.nodns /etc/sing-box/config.json
check "в route есть, в DNS нет — не подключён" sh -c '. /usr/bin/blockwatch >/dev/null 2>&1; ! ruleset_wired'
cp /tmp/sb-config.orig /etc/sing-box/config.json
rm -rf /tmp/sing-box /tmp/sb-config.orig /tmp/sb-config.nodns
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
