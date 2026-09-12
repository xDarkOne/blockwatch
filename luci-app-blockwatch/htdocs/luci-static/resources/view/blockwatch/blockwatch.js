'use strict';
'require view';
'require fs';
'require poll';

// Вкладка blockwatch — только посмотреть. Всё делается само: подтверждённые
// блокировки дописываются в файл, который netshift/podkop читают как Local
// Domain List, а sing-box подхватывает изменения на лету.

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
		' · проверено адресов: ' + st.checked + ', живых: ' + st.alive + ', лежит: ' + st.down
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

	return table(['Сайт', 'Добавлен', 'Сейчас'], added.map(function (a) {
		return E('tr', { 'class': 'tr' }, [
			cell(a.domain),
			cell(a.at || '—'),
			cell(a.live ? 'идёт по правилам ' + backendName(st) :
				E('span', { 'style': 'color:#c60' },
					'ещё не применён — подхватится при перезапуске ' + backendName(st)))
		]);
	}));
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
		};

		draw(st);
		poll.add(function () {
			return call(['status']).then(draw).catch(function () {});
		}, 30);

		return E('div', { 'class': 'cbi-map' }, [
			E('h2', {}, 'Blockwatch'),
			E('div', { 'class': 'cbi-map-descr' },
				'Находит сайты, которые не открываются напрямую, но открываются через туннель, ' +
				'проверяет каждый опытом и подтверждённые добавляет в список ' + backendName(st) +
				'. Соединения при этом не рвутся. Российские домены и свои серверы не ' +
				'добавляются никогда.'),
			body
		]);
	},

	handleSave: null,
	handleSaveApply: null,
	handleReset: null
});
