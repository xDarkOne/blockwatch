'use strict';
'require view';
'require fs';
'require poll';
'require form';

// Вкладка blockwatch. Всё делается само: подтверждённые блокировки
// дописываются в файл, который netshift/podkop читают как Local Domain List,
// sing-box подхватывает изменения на лету, а перепроверка убирает то, что
// снова открывается напрямую. Здесь — смотреть и настраивать.

function call(args) {
	return fs.exec('/usr/bin/blockwatch', args).then(function (res) {
		if (!res || res.code !== 0)
			throw new Error((res && res.stderr) || 'команда не выполнилась');
		return JSON.parse(res.stdout || '{}');
	});
}

function cell(content) {
	return E('td', { 'class': 'td' }, content);
}

function table(titles, rows) {
	return E('table', { 'class': 'table' }, [
		E('tr', { 'class': 'tr table-titles' },
			titles.map(function (t) { return E('th', { 'class': 'th' }, t); }))
	].concat(rows));
}

function backendName(st) {
	return st.backend === 'podkop' ? 'Podkop' : st.backend === 'netshift' ? 'NetShift' :
		(st.backend || 'netshift/podkop');
}

function statusBlock(st) {
	var nodes = [];

	nodes.push(E('p', {}, [
		'blockwatch ' + st.version + ' · ' + backendName(st) + ' · ',
		st.running ? 'идёт заход' : 'между заходами',
		' · проверено сайтов: ' + st.checked + ', живых: ' + st.alive + ', лежит: ' + st.down
	]));

	if (st.tunnel)
		nodes.push(E('p', {}, st.tunnel.ok
			? 'Туннель для проверки: ' + st.tunnel.socks + ' (выход ' + st.tunnel.tunnel +
			  ', напрямую ' + st.tunnel.direct + ')'
			: 'Туннель для проверки не найден.'));

	if (st.hooked)
		nodes.push(E('p', {}, ['Список подключён к ' + backendName(st) + ', секция «' +
			st.section + '»: ', E('code', {}, st.file)]));

	if (st.apply)
		nodes.push(E('p', {}, [E('strong', {}, 'Последнее добавление (' + st.apply.at + '): '),
			st.apply.message]));

	if (st.problems && st.problems.length)
		nodes.push(E('div', { 'class': 'alert-message warning' },
			[E('p', {}, E('strong', {}, 'Требует внимания:'))].concat(
				st.problems.map(function (p) { return E('p', {}, '— ' + p); }))));

	return nodes;
}

function addedBlock(st) {
	var added = st.added || [];
	if (!added.length)
		return E('p', {}, 'Пока ничего не добавлено.');

	return table(['Сайт', 'Добавлен', 'Сейчас', 'Перепроверка'], added.map(function (a) {
		return E('tr', { 'class': 'tr' }, [
			cell(a.domain),
			cell(a.at || '—'),
			cell(a.live ? 'идёт по правилам ' + backendName(st) :
				E('span', { 'style': 'color:#c60' }, st.wired === false ?
					'не идёт: ' + backendName(st) + ' собрал sing-box без списка — перезапусти ' + backendName(st) :
					'ещё не применён — подхватится при перезапуске ' + backendName(st))),
			cell(recheckText(st, a))
		]);
	}));
}

function when(ts) {
	if (!ts)
		return '';
	var d = new Date(ts * 1000);
	return ' (' + ('0' + d.getDate()).slice(-2) + '.' + ('0' + (d.getMonth() + 1)).slice(-2) + ' ' +
		('0' + d.getHours()).slice(-2) + ':' + ('0' + d.getMinutes()).slice(-2) + ')';
}

function recheckText(st, a) {
	var need = (st.recheck && st.recheck.remove_after) || 3;
	switch (a.result) {
	case 'напрямую':
		return E('span', { 'style': 'color:#080' }, 'открылся напрямую: ' + a.streak + ' из ' + need +
			(st.recheck && st.recheck.auto_remove ? ' — потом уберётся' : '') + when(a.checked_at));
	case 'заблокирован':
		return 'напрямую не открывается' + when(a.checked_at);
	case 'по-адресу':
		return 'адрес в IP-списке ' + backendName(st) + ' — напрямую не проверить' + when(a.checked_at);
	case 'нет-адреса':
		return 'имя не резолвится' + when(a.checked_at);
	default:
		return 'ещё не проверялся';
	}
}

function removedBlock(st) {
	var removed = st.removed || [];
	if (!removed.length)
		return E('p', {}, 'Пока ничего не убрано.');
	return table(['Сайт', 'Убран'], removed.map(function (r) {
		return E('tr', { 'class': 'tr' }, [cell(r.domain), cell(r.at)]);
	}));
}

function settingsMap() {
	var m = new form.Map('blockwatch', 'Настройки',
		'Меняются сразу, перезапуск не нужен: blockwatch перечитывает их на каждом заходе.');
	var s = m.section(form.NamedSection, 'main', 'blockwatch');
	s.addremove = false;
	var o;

	o = s.option(form.Flag, 'enabled', 'Наблюдать');
	o.default = '1'; o.rmempty = false;

	o = s.option(form.Flag, 'auto_export', 'Добавлять подтверждённые сами');
	o.default = '1'; o.rmempty = false;

	o = s.option(form.Value, 'confirm_minutes', 'Второе подтверждение через, минут',
		'Находка добавляется после двух совпадений в разных проверках — так отсекается разовый сбой.');
	o.datatype = 'range(2,120)'; o.placeholder = '5';

	o = s.option(form.Value, 'max_per_day', 'Не больше доменов в сутки',
		'Страховка от лавины ложных находок.');
	o.datatype = 'range(1,200)'; o.placeholder = '30';

	o = s.option(form.Value, 'max_domains', 'Предел всего списка',
		'Дальше новые домены не добавляются, а здесь появляется предупреждение.');
	o.datatype = 'range(10,5000)'; o.placeholder = '500';

	o = s.option(form.Flag, 'auto_remove', 'Убирать то, что снова открывается напрямую');
	o.default = '1'; o.rmempty = false;

	o = s.option(form.Value, 'recheck_hours', 'Перепроверять список раз в, часов',
		'Каждый домен открывается напрямую, мимо туннеля. После удачной проверки следующая — через сутки.');
	o.datatype = 'range(1,720)'; o.placeholder = '72';

	o = s.option(form.Value, 'remove_after', 'Убирать после удачных проверок подряд',
		'Блокировки то включают, то снимают — одной удачи мало.');
	o.datatype = 'range(1,10)'; o.placeholder = '3';

	o = s.option(form.DynamicList, 'never_suffix', 'Не добавлять никогда',
		'Окончания доменов. Имена своих серверов из конфига sing-box добавляются сами.');
	o.placeholder = 'ru';

	return m;
}

function foundBlock(st) {
	var inList = {};
	(st.added || []).forEach(function (a) { inList[a.domain] = true; });

	var seen = {};
	var waiting = (st.found || []).filter(function (f) {
		var key = (f.domain && f.domain !== '-') ? f.domain : f.ip;
		if (inList[f.domain] || seen[key])
			return false;
		seen[key] = true;
		return true;
	});

	if (!waiting.length)
		return E('p', {}, 'Находок в работе нет.');

	return table(['Сайт', 'Адрес', 'Признак', 'Сайт/адрес/туннель', 'Состояние'],
		waiting.map(function (f) {
			var state;
			if (!f.confirmed)
				state = 'ждёт второй проверки';
			else if (!f.domain || f.domain === '-')
				state = 'подтверждена, но имя сайта неизвестно — добавлять нечего';
			else if ((st.pending || []).indexOf(f.domain) >= 0)
				state = 'подтверждена, добавляется';
			else
				state = 'подтверждена, но не добавляется: стоп-список или домен уже есть в правилах ' +
					backendName(st);
			return E('tr', { 'class': 'tr' }, [
				cell(f.domain && f.domain !== '-' ? f.domain : '(имя неизвестно)'),
				cell(f.ip),
				cell(f.why),
				cell(f.codes),
				cell(state)
			]);
		}));
}

return view.extend({
	load: function () {
		return call(['status']);
	},

	render: function (st) {
		var body = E('div', {});

		var draw = function (s) {
			body.innerHTML = '';
			body.appendChild(E('div', { 'class': 'cbi-section' },
				[E('h3', {}, 'Состояние')].concat(statusBlock(s))));
			body.appendChild(E('div', { 'class': 'cbi-section' }, [
				E('h3', {}, 'Добавлено в список'),
				addedBlock(s)
			]));
			body.appendChild(E('div', { 'class': 'cbi-section' }, [
				E('h3', {}, 'Находки в работе'),
				E('p', {}, 'Всё, что выглядит заблокированным. После второй проверки сайт ' +
					'добавляется в список сам.'),
				foundBlock(s)
			]));
			body.appendChild(E('div', { 'class': 'cbi-section' }, [
				E('h3', {}, 'Убрано из списка'),
				E('p', {}, 'Домены, которые при перепроверке снова открывались напрямую. ' +
					'Если блокировка вернётся, blockwatch найдёт их заново.'),
				removedBlock(s)
			]));
		};

		draw(st);
		poll.add(function () {
			return call(['status']).then(draw).catch(function () {});
		}, 30);

		return settingsMap().render().then(function (settings) {
			return E('div', {}, [
				E('h2', {}, 'Blockwatch'),
				E('div', { 'class': 'cbi-map-descr' },
					'Находит сайты, которые не открываются напрямую, но открываются через туннель, ' +
					'проверяет каждый опытом и подтверждённые добавляет в список ' + backendName(st) +
					'. Соединения при этом не рвутся. Российские домены и свои серверы не ' +
					'добавляются никогда.'),
				body,
				settings
			]);
		});
	}
});
