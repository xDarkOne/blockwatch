// Отрисовка вкладки LuCI в Node, без браузера и без роутера.
//
//   node tests/luci-render.js [status.json ...]
//
// LuCI подменён заглушками, DOM — минимальный, но строгий, как в браузере:
// appendChild с не-узлом падает. Так ловится то, что уже случилось на
// роутере: «Failed to execute 'appendChild' on 'Node': parameter 1 is not of
// type 'Node'», когда блок проблем оказался пустой строкой. Без аргументов —
// синтетические состояния; с файлами — ответы `blockwatch status` с роутера.
'use strict';
const fs = require('fs');
const path = require('path');

class Node {
	constructor(tag, text) { this.tag = tag; this.text = text || ''; this.children = []; this.attrs = {}; this.style = {}; this.parent = null; }
	appendChild(n) {
		if (!(n instanceof Node))
			throw new TypeError("Failed to execute 'appendChild' on 'Node': parameter 1 is not of type 'Node'.");
		n.parent = this; this.children.push(n); return n;
	}
	set innerHTML(v) { this.children = []; }
	get classList() { const c = (this.attrs['class'] || '').split(/\s+/); return { contains: (x) => c.includes(x) }; }
	contains(n) { for (let p = n; p; p = p.parent) if (p === this) return true; return false; }
	get textContent() { return this.text + this.children.map((c) => c.textContent).join(''); }
	walk(f) { f(this); this.children.forEach((c) => c.walk(f)); }
	find(pred) { const out = []; this.walk((n) => { if (pred(n)) out.push(n); }); return out; }
}

function append(node, ch) {   // как L.dom.append
	if (Array.isArray(ch)) ch.forEach((x) => append(node, x));
	else if (ch instanceof Node) node.appendChild(ch);
	else if (ch !== null && ch !== undefined) node.appendChild(new Node('#text', String(ch)));
}
function E(tag, attrs, children) {
	const n = new Node(tag);
	if (attrs instanceof Node || Array.isArray(attrs) || typeof attrs !== 'object' || attrs === null) { children = attrs; attrs = {}; }
	Object.assign(n.attrs, attrs);
	append(n, children);
	return n;
}

global.document = { createTextNode: (t) => new Node('#text', t), activeElement: null };
global.window = { localStorage: { _s: {}, getItem(k) { return this._s[k] || null; }, setItem(k, v) { this._s[k] = v; } },
	confirm: () => true };
global.E = E;

function load(status) {
	let polled = null;
	const stubs = {
		view: { extend: (o) => o },
		fs: { exec: (bin, args) => Promise.resolve({ code: 0, stdout: args[0] === 'status' ? JSON.stringify(status) : 'убран' }) },
		poll: { add: (f) => { polled = f; } },
		ui: { addNotification: () => {} },
		form: {
			Map: class { constructor() {} section() { const opt = () => ({}); return { tab() {}, taboption: opt, option: opt }; }
				render() { return Promise.resolve(E('div', { 'class': 'cbi-map' }, 'настройки')); } },
			NamedSection: 1, Flag: 1, Value: 1, DynamicList: 1
		}
	};
	const src = fs.readFileSync(path.join(__dirname, '../luci-app-blockwatch/htdocs/luci-static/resources/view/blockwatch/blockwatch.js'), 'utf8');
	const mod = new Function('view', 'fs', 'poll', 'form', 'ui', src)(stubs.view, stubs.fs, stubs.poll, stubs.form, stubs.ui);
	return { mod, poll: () => polled && polled() };
}

const synth = {
	version: '0.1.1', backend: 'netshift', file: '/etc/blockwatch/domains.txt', hooked: true, section: 'main',
	wired: true, checked: 12, alive: 9, down: 2, running: false, tunnel: { ok: true, direct: '1.1.1.1', tunnel: '2.2.2.2', socks: '127.0.0.1:4534', at: 1 },
	apply: null, problems: [], pending: [], pending_ips: [], log: [], removed: [], ips: [], ips_hooked: true,
	recheck: { auto_remove: true, hours: 72, remove_after: 3 },
	added: [], found: []
};
const busy = Object.assign({}, synth, {
	problems: ['список адресов не подключён'], ips_hooked: false, wired: false, running: true, tunnel: null,
	apply: { state: 'live', at: '10:00', message: 'применено' },
	added: Array.from({ length: 130 }, (_, i) => ({ domain: 'd' + i + '.example', at: '2026-09-29 10:00', live: i % 3 !== 0,
		result: ['напрямую', 'заблокирован', 'по-адресу', 'нет-адреса', undefined][i % 5], streak: 1, checked_at: 1790000000 })),
	ips: [{ ip: '8.6.112.6', at: 1790000000, names: 'a.example,b.example', live: true, expires: 1792592000 },
		{ ip: '203.0.113.9', at: 1790000000, names: '-', live: false, expires: 1792592000 }],
	found: [{ ip: '8.6.112.6', domain: 'a.example', confirmed: true, why: 'обрыв', codes: '-/200~/200' },
		{ ip: '203.0.113.9', domain: '-', confirmed: false, why: 'молчит', codes: '000~/000~/200' }],
	pending: ['x.example'], pending_ips: ['203.0.113.9'],
	log: ['2026-09-29 10:00 ДОБАВЛЕН a.example', '2026-09-29 10:01 УБРАН b.example вручную', 'странная строка'],
	removed: [{ at: '2026-09-29 10:01', domain: 'b.example' }]
});

async function run(name, status) {
	const { mod, poll } = load(status);
	const st = await mod.load();
	const root = await mod.render(st);
	const clicks = root.find((n) => typeof n.attrs.click === 'function');
	const inputs = root.find((n) => typeof n.attrs.input === 'function');
	for (const n of clicks.filter((n) => n.tag === 'li' || /bw-tile/.test(n.attrs['class'] || ''))) n.attrs.click();
	for (const n of inputs) { n.attrs.input({ target: { value: 'd1' } }); n.attrs.input({ target: { value: '' } }); }
	for (const n of root.find((n) => n.tag === 'button' && /Показать ещё/.test(n.textContent))) n.attrs.click();
	await poll();
	const rm = root.find((n) => n.tag === 'button' && n.textContent === 'Убрать')[0];
	if (rm) await rm.attrs.click({ target: {} });
	const rows = root.find((n) => n.tag === 'tr').length;
	console.log(`  ok   ${name}: ${rows} строк, ${clicks.length} кнопок/вкладок, ${inputs.length} поиск`);
}

(async () => {
	const cases = process.argv.slice(2).length
		? process.argv.slice(2).map((f) => [path.basename(f), JSON.parse(fs.readFileSync(f, 'utf8'))])
		: [['пусто, без проблем', synth], ['большие списки, проблемы, без туннеля', busy]];
	let fails = 0;
	for (const [name, st] of cases) {
		try { await run(name, st); } catch (e) { fails++; console.log(`  FAIL ${name}: ${e.message}`); }
	}
	console.log(fails ? `== ПРОВАЛОВ: ${fails}` : '== ВСЁ ПРОШЛО');
	process.exit(fails ? 1 : 0);
})();
