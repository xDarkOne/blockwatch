'use strict';
'require view';
'require fs';
'require poll';
'require form';
'require ui';

// Вкладка blockwatch. Всё делается само: подтверждённые блокировки
// дописываются в файлы, которые netshift/podkop читают как Local Domain List и
// Local Subnet List, sing-box подхватывает изменения на лету, а перепроверка
// убирает то, что снова открывается напрямую. Здесь — смотреть, искать,
// убирать руками и настраивать.
//
// Сверху — сводка, ниже вкладки. Автообновление раз в 30 с перерисовывает
// только таблицы: выбранная вкладка, строка поиска и прокрутка не сбрасываются.

var PAGE = 50;   // строк на странице таблицы

function call(args) {
	return fs.exec('/usr/bin/blockwatch', args).then(function (res) {
		if (!res || res.code !== 0)
			throw new Error((res && (res.stdout || res.stderr)) || 'команда не выполнилась');
		return JSON.parse(res.stdout || '{}');
	});
}

function store(key, val) {
	try {
		if (val === undefined) return window.localStorage.getItem('blockwatch.' + key);
		window.localStorage.setItem('blockwatch.' + key, val);
	} catch (e) {}
	return null;
}

// Вставить в узел: пустое пропустить, строку — текстом, массив — по элементам.
// appendChild принимает только узлы, а блоки тут бывают пустой строкой.
function put(parent, n) {
	if (Array.isArray(n)) { n.forEach(function (x) { put(parent, x); }); return; }
	if (n === '' || n == null || n === false) return;
	parent.appendChild(typeof n === 'string' || typeof n === 'number' ? document.createTextNode(String(n)) : n);
}

function backendName(st) {
	return st.backend === 'podkop' ? 'Podkop' : st.backend === 'netshift' ? 'NetShift' :
		(st.backend || 'netshift/podkop');
}

function when(ts) {
	if (!ts) return '';
	var d = new Date(ts * 1000);
	return ('0' + d.getDate()).slice(-2) + '.' + ('0' + (d.getMonth() + 1)).slice(-2) + ' ' +
		('0' + d.getHours()).slice(-2) + ':' + ('0' + d.getMinutes()).slice(-2);
}

function badge(text, kind) {
	return E('span', { 'class': 'bw-badge bw-' + (kind || 'grey') }, text);
}

function cell(content, cls) {
	return E('td', { 'class': 'td' + (cls ? ' ' + cls : '') }, content);
}

// Таблица во всю ширину раздела и не шире: доли колонок заданы, длинный
// текст переносится. Без этого домены и журнал распирали раздел шире
// интерфейса LuCI, а остальные вкладки были уже.
function table(titles, rows, widths) {
	var head = E('tr', { 'class': 'tr table-titles' }, titles.map(function (t, i) {
		return E('th', { 'class': 'th', 'style': widths && widths[i] ? 'width:' + widths[i] : '' }, t);
	}));
	return E('div', { 'class': 'bw-scroll' },
		E('table', { 'class': 'table bw-table' }, [head].concat(rows)));
}

// Таблица с поиском и постраничным показом. Поиск и число показанных строк
// живут в state — перерисовка по таймеру их не сбрасывает.
function pagedTable(state, key, items, match, titles, row, empty, widths) {
	var q = (state.q[key] || '').toLowerCase();
	var list = q ? items.filter(function (it) { return match(it).toLowerCase().indexOf(q) >= 0; }) : items;
	var shown = state.shown[key] || PAGE;
	if (!list.length)
		return E('p', { 'class': 'bw-muted' }, q ? 'Ничего не найдено.' : empty);
	var nodes = [table(titles, list.slice(0, shown).map(row), widths)];
	if (list.length > shown)
		nodes.push(E('p', {}, E('button', {
			'class': 'cbi-button',
			'click': function () { state.shown[key] = shown + PAGE; state.refresh(); }
		}, 'Показать ещё (' + (list.length - shown) + ')')));
	return E('div', {}, nodes);
}

function searchBox(state, key, placeholder) {
	return E('input', {
		'type': 'search', 'class': 'cbi-input-text bw-search', 'placeholder': placeholder,
		'value': state.q[key] || '',
		'input': function (ev) { state.q[key] = ev.target.value; state.shown[key] = PAGE; state.refresh(); }
	});
}

function removeButton(state, what) {
	return E('button', {
		'class': 'cbi-button cbi-button-remove bw-small',
		'title': 'Убрать из списка. Если его всё ещё режут, blockwatch найдёт и добавит заново.',
		'click': function (ev) {
			if (!window.confirm('Убрать ' + what + ' из списка?'))
				return;
			ev.target.disabled = true;
			return fs.exec('/usr/bin/blockwatch', ['remove', what]).then(function (res) {
				if (!res || res.code !== 0)
					ui.addNotification(null, E('p', {}, 'Не удалось: ' + ((res && (res.stdout || res.stderr)) || '')));
				return state.reload();
			});
		}
	}, 'Убрать');
}

// --- сводка --------------------------------------------------------------------
function tiles(state, st) {
	var added = st.added || [], ips = st.ips || [];
	var live = added.filter(function (a) { return a.live; }).length;
	var found = foundRows(st);
	var pend = found.filter(function (f) { return !f.confirmed; }).length;
	var tile = function (tab, value, label, sub, kind) {
		return E('div', {
			'class': 'bw-tile' + (kind ? ' bw-tile-' + kind : ''),
			'click': function () { state.go(tab); }
		}, [E('div', { 'class': 'bw-tile-value' }, String(value)),
			E('div', { 'class': 'bw-tile-label' }, label),
			sub ? E('div', { 'class': 'bw-tile-sub' }, sub) : '']);
	};
	return E('div', { 'class': 'bw-tiles' }, [
		tile('domains', added.length, 'доменов в списке',
			live === added.length ? 'все идут в туннель' : live + ' идут в туннель', live === added.length ? '' : 'warn'),
		tile('ips', ips.length, 'адресов в туннеле', st.ips_hooked === false ? 'список не подключён' : '',
			st.ips_hooked === false ? 'warn' : ''),
		tile('found', found.length, 'находок в работе', pend ? pend + ' ждут второй проверки' : ''),
		tile('log', (st.removed || []).length, 'убрано', 'снова открываются напрямую'),
		tile('overview', st.checked, 'проверено', 'живых ' + st.alive + ' · лежит ' + st.down),
		tile('overview', st.tunnel && st.tunnel.ok ? 'есть' : 'нет', 'туннель для проверки',
			st.tunnel && st.tunnel.ok ? 'выход ' + st.tunnel.tunnel : '', st.tunnel && st.tunnel.ok ? '' : 'bad')
	]);
}

function tunnelLabel(p) {
	return /^if:/.test(p || '') ? 'интерфейс ' + p.slice(3) : 'socks-вход ' + p;
}

// Списки отключены — частый случай: Zapret-Manager, переустанавливая netshift,
// переписывает его настройки целиком. Кнопка делает то же, что blockwatch hook.
function hookButton(state, st) {
	if (!st.backend || (st.hooked && st.ips_hooked !== false))
		return '';
	return E('p', {}, E('button', {
		'class': 'cbi-button cbi-button-action',
		'click': function (ev) {
			if (!window.confirm('Подключить списки blockwatch к ' + backendName(st) + '? ' + backendName(st) +
					' перезапустится один раз — соединения прервутся секунд на двадцать.'))
				return;
			ev.target.disabled = true;
			return fs.exec('/usr/bin/blockwatch', ['hook']).then(function (res) {
				ui.addNotification(null, E('p', {}, (res && (res.stdout || res.stderr)) || 'готово'));
				return state.reload();
			});
		}
	}, 'Подключить списки к ' + backendName(st)));
}

function problemsBlock(state, st) {
	if (!st.problems || !st.problems.length)
		return '';
	return E('div', { 'class': 'alert-message warning' },
		[E('strong', {}, 'Требует внимания:')].concat(
			st.problems.map(function (p) { return E('div', {}, '— ' + p); }),
			[hookButton(state, st)]));
}

// --- вкладки ---------------------------------------------------------------------
function overviewTab(state, st) {
	var nodes = [
		E('p', {}, ['blockwatch ' + st.version + ' · ' + backendName(st) + ' · ',
			st.running ? badge('идёт заход', 'blue') : badge('между заходами')]),
		st.hooked ? E('p', {}, ['Списки подключены к ' + backendName(st) + ', секция «' + st.section + '»: ',
			E('code', {}, st.file), st.ips_hooked ? ' и адреса' : '']) : '',
		st.tunnel ? E('p', {}, st.tunnel.ok
			? 'Туннель для проверки: ' + tunnelLabel(st.tunnel.socks) + ' (выход ' + st.tunnel.tunnel + ', напрямую ' + st.tunnel.direct + ')'
			: 'Туннель для проверки не найден.') : '',
		st.apply ? E('p', {}, [E('strong', {}, 'Последнее добавление (' + st.apply.at + '): '), st.apply.message]) : '',
		E('h4', {}, 'Недавно добавлено')
	];
	var recent = (st.added || []).slice(0, 8).map(function (a) {
		return E('tr', { 'class': 'tr' }, [cell(a.domain), cell(a.at || '—'), cell(liveBadge(st, a))]);
	});
	nodes.push(recent.length ? table(['Сайт', 'Добавлен', 'Сейчас'], recent, ['50%', '25%', '25%'])
		: E('p', { 'class': 'bw-muted' }, 'Пока ничего не добавлено.'));
	return nodes;
}

function liveBadge(st, a) {
	if (a.live) return badge('в туннеле', 'green');
	return st.wired === false
		? badge(backendName(st) + ' собрал sing-box без списка — перезапусти ' + backendName(st), 'red')
		: badge('ещё не применён', 'orange');
}

function recheckBadge(st, a) {
	var need = (st.recheck && st.recheck.remove_after) || 3;
	var t = a.checked_at ? ' · ' + when(a.checked_at) : '';
	switch (a.result) {
	case 'напрямую': return badge('открылся напрямую ' + a.streak + '/' + need + t, 'green');
	case 'заблокирован': return badge('напрямую режется' + t, 'grey');
	case 'по-адресу': return badge('адрес в IP-списке — не проверить' + t, 'grey');
	case 'нет-адреса': return badge('имя не резолвится' + t, 'grey');
	default: return badge('ещё не проверялся');
	}
}

function domainsTab(state, st) {
	var added = st.added || [];
	return [
		E('p', { 'class': 'bw-muted' }, 'Перепроверка раз в ' + ((st.recheck && st.recheck.hours) || 72) +
			' ч; открылся напрямую ' + ((st.recheck && st.recheck.remove_after) || 3) + ' раза подряд — уберётся сам.'),
		pagedTable(state, 'domains', added, function (a) { return a.domain; },
			['Сайт', 'Добавлен', 'Сейчас', 'Перепроверка', ''],
			function (a) {
				return E('tr', { 'class': 'tr' }, [cell(a.domain), cell(a.at || '—'), cell(liveBadge(st, a)),
					cell(recheckBadge(st, a)), cell(removeButton(state, a.domain), 'bw-right')]);
			}, 'Пока ничего не добавлено.', ['32%', '15%', '17%', '26%', '10%'])
	];
}

function ipsTab(state, st) {
	var nodes = [E('p', { 'class': 'bw-muted' },
		'Когда имя сайта неизвестно или на адресе много сайтов (Cloudflare, CDN), в туннель уходит сам адрес. ' +
		'Проверить его напрямую после этого нельзя, поэтому у адреса срок: потом он возвращается на прямую ' +
		'и, если его всё ещё режут, находится заново. Адреса Google и YouTube не добавляются никогда.')];
	if (st.ips_hooked === false)
		nodes.push(E('div', { 'class': 'alert-message warning' },
			'Список адресов ещё не подключён к ' + backendName(st) + ': выполни в консоли blockwatch hook — ' +
			backendName(st) + ' перезапустится один раз.'));
	nodes.push(pagedTable(state, 'ips', st.ips || [], function (i) { return i.ip + ' ' + i.names; },
		['Адрес', 'Какие имена на нём видели', 'Добавлен', 'Истекает', 'Сейчас', ''],
		function (i) {
			return E('tr', { 'class': 'tr' }, [cell(E('code', {}, i.ip)),
				cell(i.names === '-' ? E('span', { 'class': 'bw-muted' }, 'имя неизвестно') : i.names.split(',').join(', ')),
				cell(when(i.at)), cell(when(i.expires)),
				cell(i.live ? badge('в туннеле', 'green') : badge('ещё не применён', 'orange')),
				cell(removeButton(state, i.ip), 'bw-right')]);
		}, 'Пока ни одного адреса.', ['15%', '33%', '12%', '12%', '16%', '12%']));
	return nodes;
}

function foundRows(st) {
	var inList = {};
	(st.added || []).forEach(function (a) { inList[a.domain] = true; });
	var seen = {};
	return (st.found || []).filter(function (f) {
		var key = (f.domain && f.domain !== '-') ? f.domain : f.ip;
		if (inList[f.domain] || seen[key]) return false;
		seen[key] = true;
		return true;
	});
}

function foundState(st, f) {
	var ipListed = (st.ips || []).some(function (i) { return i.ip === f.ip; });
	if (!f.confirmed) return badge('ждёт второй проверки', 'blue');
	if (ipListed) return badge('адрес в списке адресов', 'green');
	if ((st.pending_ips || []).indexOf(f.ip) >= 0) return badge('добавляется адрес', 'green');
	if ((st.pending || []).indexOf(f.domain) >= 0) return badge('добавляется', 'green');
	if (!f.domain || f.domain === '-')
		return badge('без имени; адрес не добавляется: стоп-список, Google/YouTube или уже в правилах', 'grey');
	return badge('не добавляется: стоп-список или уже в правилах ' + backendName(st), 'grey');
}

function foundTab(state, st) {
	return [
		E('p', { 'class': 'bw-muted' }, 'Всё, что выглядит заблокированным. После второй проверки сайт или адрес ' +
			'добавляется сам. Если сайт снова открыть через минуту, вторая проверка пройдёт сразу.'),
		pagedTable(state, 'found', foundRows(st), function (f) { return (f.domain || '') + ' ' + f.ip; },
			['Сайт', 'Адрес', 'Признак', 'Сайт / адрес / туннель', 'Состояние'],
			function (f) {
				return E('tr', { 'class': 'tr' }, [
					cell(f.domain && f.domain !== '-' ? f.domain : E('span', { 'class': 'bw-muted' }, 'имя неизвестно')),
					cell(E('code', {}, f.ip)), cell(f.why), cell(E('code', {}, f.codes)), cell(foundState(st, f))]);
			}, 'Находок в работе нет.', ['26%', '15%', '13%', '16%', '30%'])
	];
}

function logTab(state, st) {
	var kind = function (l) {
		return /ПОДТВЕРЖДЕНО/.test(l) ? 'blue' : /ДОБАВЛЕН/.test(l) ? 'green' : /УБРАН|ИСТЁК/.test(l) ? 'orange' : 'grey';
	};
	return [
		pagedTable(state, 'log', st.log || [], function (l) { return l; }, ['Последние события'],
			function (l) {
				var m = l.match(/^(\S+ \S+) (\S+) (.*)$/);
				return E('tr', { 'class': 'tr' }, [cell(m ? [E('span', { 'class': 'bw-muted' }, m[1] + ' '),
					badge(m[2], kind(l)), ' ' + m[3]] : l)]);
			}, 'Журнал пуст.', ['100%'])
	];
}

function settingsMap() {
	var m = new form.Map('blockwatch', '',
		'Меняются сразу, перезапуск не нужен: blockwatch перечитывает их на каждом заходе.');
	var s = m.section(form.NamedSection, 'main', 'blockwatch');
	s.addremove = false;
	s.tab('find', 'Поиск и добавление');
	s.tab('list', 'Список и перепроверка');
	s.tab('never', 'Исключения');
	var o;

	o = s.taboption('find', form.Flag, 'enabled', 'Наблюдать');
	o.default = '1'; o.rmempty = false;
	o = s.taboption('find', form.Flag, 'auto_export', 'Добавлять подтверждённые сами');
	o.default = '1'; o.rmempty = false;
	o = s.taboption('find', form.Flag, 'auto_rehook', 'Возвращать отключённые списки',
		'Только для списков, подключённых локальными файлами: если они пропали из настроек NetShift, ' +
		'вернуть их и перезапустить NetShift — соединения прервутся секунд на двадцать (не чаще трёх раз в час). ' +
		'С Zapret-Manager не нужно: там blockwatch подключается внешними списками по ссылке, и Forkozz их сохраняет сам.');
	o.default = '0'; o.rmempty = false;

	o = s.taboption('find', form.Value, 'confirm_minutes', 'Второе подтверждение через, минут',
		'Находка добавляется после двух совпадений в разных проверках — так отсекается разовый сбой. ' +
		'Если сайт снова открывали, вторая проверка идёт через минуту.');
	o.datatype = 'range(2,120)'; o.placeholder = '5';
	o = s.taboption('find', form.Value, 'max_per_day', 'Не больше в сутки',
		'Доменов и адресов вместе. Страховка от лавины ложных находок.');
	o.datatype = 'range(1,200)'; o.placeholder = '30';

	o = s.taboption('list', form.Value, 'max_domains', 'Предел списка доменов',
		'Дальше новые домены не добавляются, а на вкладке появляется предупреждение.');
	o.datatype = 'range(10,5000)'; o.placeholder = '500';
	o = s.taboption('list', form.Value, 'max_subnets', 'Предел списка адресов');
	o.datatype = 'range(1,2000)'; o.placeholder = '200';
	o = s.taboption('list', form.Value, 'ip_ttl_days', 'Срок адреса в туннеле, дней',
		'Потом адрес возвращается на прямую; если его всё ещё режут — найдётся и добавится заново.');
	o.datatype = 'range(1,365)'; o.placeholder = '30';
	o = s.taboption('list', form.Flag, 'auto_remove', 'Убирать домены, которые снова открываются напрямую');
	o.default = '1'; o.rmempty = false;
	o = s.taboption('list', form.Value, 'recheck_hours', 'Перепроверять домены раз в, часов',
		'Каждый домен открывается напрямую, мимо туннеля. После удачной проверки следующая — через сутки.');
	o.datatype = 'range(1,720)'; o.placeholder = '72';
	o = s.taboption('list', form.Value, 'remove_after', 'Убирать после удачных проверок подряд',
		'Блокировки то включают, то снимают — одной удачи мало.');
	o.datatype = 'range(1,10)'; o.placeholder = '3';

	o = s.taboption('never', form.DynamicList, 'never_suffix', 'Не добавлять никогда',
		'Окончания доменов. Имена своих серверов из конфига sing-box добавляются сами.');
	o.placeholder = 'ru';
	o = s.taboption('never', form.DynamicList, 'never_ip_suffix', 'Не добавлять адреса с этими именами',
		'Вдобавок к списку выше. По умолчанию — Google и YouTube: YouTube у многих нарочно идёт через zapret.');
	o.placeholder = 'youtube.com';

	return m;
}

var TABS = [
	['overview', 'Обзор'], ['domains', 'Домены'], ['ips', 'Адреса'],
	['found', 'Находки'], ['log', 'Журнал'], ['settings', 'Настройки']
];

var CSS = [
	'.bw-tiles{display:flex;flex-wrap:wrap;gap:.6em;margin:.8em 0 1em}',
	'.bw-tile{flex:1 1 9em;min-width:9em;padding:.6em .8em;border:1px solid rgba(128,128,128,.3);border-radius:6px;cursor:pointer}',
	'.bw-tile:hover{border-color:rgba(128,128,128,.7)}',
	'.bw-tile-value{font-size:1.6em;font-weight:bold;line-height:1.2}',
	'.bw-tile-label{opacity:.85}',
	'.bw-tile-sub{font-size:.85em;opacity:.65;margin-top:.2em}',
	'.bw-tile-warn{border-left:4px solid #e0a000}.bw-tile-bad{border-left:4px solid #c33}',
	'.bw-badge{display:inline-block;padding:.05em .5em;border-radius:1em;font-size:.85em;white-space:normal;max-width:100%}',
	'.bw-green{background:rgba(40,160,70,.18)}.bw-orange{background:rgba(230,150,0,.22)}',
	'.bw-red{background:rgba(200,50,50,.22);white-space:normal}.bw-blue{background:rgba(50,120,220,.18)}',
	'.bw-grey{background:rgba(128,128,128,.18);white-space:normal}',
	'.bw-muted{opacity:.65}.bw-right{text-align:right}',
	'.bw-toolbar{display:flex;flex-wrap:wrap;align-items:center;gap:.8em;margin:.5em 0}',
	'.bw-search{min-width:16em}.bw-small{padding:.1em .6em!important}',
	'.bw-tabs{margin-top:.5em}.bw-tabs li{cursor:pointer}',
	'.bw-scroll{max-width:100%;overflow-x:auto}',
	'.bw-table{width:100%;table-layout:fixed}',
	'.bw-table td,.bw-table th{overflow-wrap:anywhere;word-break:break-word;vertical-align:top}',
	'.bw-table code{white-space:normal;overflow-wrap:anywhere}',
	'.bw-search{max-width:100%}'
].join('\n');

return view.extend({
	load: function () {
		return call(['status']);
	},

	render: function (st) {
		var state = {
			data: st, q: {}, shown: {},
			tab: store('tab') || 'overview'
		};
		if (!TABS.some(function (t) { return t[0] === state.tab; })) state.tab = 'overview';

		var head = E('div', {});
		var menu = E('ul', { 'class': 'cbi-tabmenu bw-tabs' });
		var SEARCH = { domains: 'Поиск по доменам', ips: 'Поиск по адресу или имени',
			found: 'Поиск по сайту или адресу', log: 'Поиск в журнале' };
		var panels = {}, bodies = {};
		TABS.forEach(function (t) {
			var k = t[0];
			panels[k] = E('div', { 'class': 'cbi-section' });
			// строка поиска создаётся один раз: перерисовка её не трогает,
			// и фокус с набранным текстом сохраняются
			if (SEARCH[k])
				panels[k].appendChild(E('div', { 'class': 'bw-toolbar' }, searchBox(state, k, SEARCH[k])));
			bodies[k] = E('div', {});
			panels[k].appendChild(bodies[k]);
		});

		var drawMenu = function () {
			menu.innerHTML = '';
			TABS.forEach(function (t) {
				var extra = t[0] === 'found' ? foundRows(state.data).length :
					t[0] === 'domains' ? (state.data.added || []).length :
					t[0] === 'ips' ? (state.data.ips || []).length : 0;
				menu.appendChild(E('li', {
					'class': t[0] === state.tab ? 'cbi-tab' : 'cbi-tab-disabled',
					'click': function () { state.go(t[0]); }
				}, E('a', {}, t[1] + (extra ? ' (' + extra + ')' : ''))));
			});
			Object.keys(panels).forEach(function (k) {
				panels[k].style.display = k === state.tab ? '' : 'none';
			});
		};

		// перерисовать всё, кроме строк поиска и настроек
		var RENDER = { overview: overviewTab, domains: domainsTab, ips: ipsTab, found: foundTab, log: logTab };
		state.refresh = function () {
			var s = state.data;
			head.innerHTML = '';
			put(head, problemsBlock(state, s));
			put(head, tiles(state, s));
			Object.keys(RENDER).forEach(function (k) {
				bodies[k].innerHTML = '';
				var nodes = RENDER[k](state, s);
				put(bodies[k], nodes);
			});
			drawMenu();
		};
		state.go = function (tab) { state.tab = tab; store('tab', tab); drawMenu(); };
		state.reload = function () {
			return call(['status']).then(function (s) { state.data = s; state.refresh(); }).catch(function () {});
		};

		state.refresh();
		poll.add(state.reload, 30);

		return settingsMap().render().then(function (settings) {
			panels.settings.appendChild(settings);
			return E('div', {}, [
				E('style', {}, CSS),
				E('h2', {}, 'Blockwatch'),
				E('div', { 'class': 'cbi-map-descr' },
					'Находит сайты, которые не открываются напрямую, но открываются через туннель, проверяет каждый ' +
					'опытом и подтверждённые добавляет в список ' + backendName(st) + ' — на лету, соединения не рвутся.'),
				head, menu
			].concat(TABS.map(function (t) { return panels[t[0]]; })));
		});
	}
});
