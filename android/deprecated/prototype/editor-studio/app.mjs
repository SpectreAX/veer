import {
  REGIONS, restore, serialize, createSession, activeSession, anyBusy, switchSession, deleteSession, filterSessions,
  unknownRegions, hasUnsavedChanges, setRegion, canSend, startTurn, completeTurn, cancelTurn, setDecision, acceptedCount,
  candidateRules, applyTurn, rejectTurn, undoTurn, canUndo, triggerAt, menuItems, applyMenuItem, diffRules, diffStats,
  toYaml, markExported, searchRules, matchDomain, initialApp,
} from './state.mjs';

const $ = id => document.getElementById(id);
const escape = value => String(value).replace(/[&<>"']/g, c => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' })[c]);

const PATHS = {
  plus: 'M12 5v14M5 12h14', up: 'M12 19V5m-6 6 6-6 6 6', down: 'M12 5v14m-6-6 6 6 6-6', right: 'm9 6 6 6-6 6',
  chevron: 'm9 6 6 6-6 6', arrow: 'M5 12h14m-5-5 5 5-5 5', close: 'm6 6 12 12M6 18 18 6', search: 'm20 20-4.2-4.2M11 18a7 7 0 1 1 0-14 7 7 0 0 1 0 14',
  file: 'M14 3H6v18h12V7Zm0 0v4h4', globe: 'M12 3a9 9 0 1 0 0 18 9 9 0 0 0 0-18M3 12h18M12 3c3 3 3 15 0 18M12 3c-3 3-3 15 0 18',
  key: 'M14 10a4 4 0 1 0-3 3.9V21h3v-2h2v-3h-2v-2.1A4 4 0 0 0 14 10Z', export: 'M12 15V3m-4 4 4-4 4 4M5 11v10h14V11',
  panel: 'M3 5h18v14H3Zm11 0v14', sidebar: 'M3 5h18v14H3Zm6 0v14', moon: 'M20 15A8 8 0 0 1 9 4a8 8 0 1 0 11 11',
  sun: 'M12 8a4 4 0 1 0 0 8 4 4 0 0 0 0-8M12 2v2m0 16v2M2 12h2m16 0h2M5 5l1.5 1.5m11 11L19 19M5 19l1.5-1.5m11-11L19 5',
  check: 'm5 12 4 4L19 6', x: 'm7 7 10 10M7 17 17 7', alert: 'M12 4 2 20h20Zm0 6v4m0 3v.5', stop: 'M7 7h10v10H7Z',
  retry: 'M4 12a8 8 0 1 0 2.3-5.7M4 4v4h4', trash: 'M5 7h14M10 7V4h4v3m-7 0 1 13h8l1-13', at: 'M16 12a4 4 0 1 1-8 0 4 4 0 0 1 8 0Zm0 0v1.5a2.5 2.5 0 0 0 5 0V12a9 9 0 1 0-4 7.5',
  slash: 'm15 4-6 16', target: 'M12 3v4m0 10v4M3 12h4m10 0h4M12 8a4 4 0 1 0 0 8 4 4 0 0 0 0-8',
};
const icon = (name, cls = '') => `<svg class="${cls}" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.7" stroke-linecap="round" stroke-linejoin="round" aria-hidden="true"><path d="${PATHS[name] ?? PATHS.file}"/></svg>`;
document.querySelectorAll('[data-icon]').forEach(el => { el.innerHTML = icon(el.dataset.icon); });

const STATUS = {
  running: '处理中', pending: '待审批', blocked: '校验失败 · 不能写入', confirmed: '已写入草稿', undone: '已撤销',
  superseded: '已失效', cancelled: '已取消', failed: '未完成', clarify: '需要澄清', discarded: '已全部拒绝', unchanged: '无需修改',
};
const ACTION = { route: '路由', remove: '删除' };
const VALIDATION_ICON = { passed: 'check', failed: 'x', unavailable: 'alert' };
const STORAGE = 'veer-studio-v1';
const LAYOUT = 'veer-studio-layout';

/* ---------- state ---------- */
const store = (() => { try { return localStorage; } catch { return null; } })();
const app = (() => { try { return restore(store?.getItem(STORAGE) ?? ''); } catch { return initialApp(); } })();
const ui = {
  inspector: false, tab: 'diff', ruleQuery: '', testDomain: '', sidebar: false, following: true, query: '',
  menu: null, timers: new Map(), toastTimer: null,
  width: (() => { try { return Number(store?.getItem(LAYOUT)) || 440; } catch { return 440; } })(),
};
let saveTimer;
function save() {
  clearTimeout(saveTimer);
  saveTimer = setTimeout(() => { try { store?.setItem(STORAGE, serialize(app)); } catch { /* Storage may be unavailable. */ } }, 150);
}
const session = () => activeSession(app);
const selectedTurn = () => { const s = session(); return s?.turns.find(t => t.id === s.selected) ?? null; };
const scenario = () => $('scenario').value;

function toast(text) {
  clearTimeout(ui.toastTimer);
  $('toast-text').textContent = text;
  $('toast').hidden = false;
  ui.toastTimer = setTimeout(() => { $('toast').hidden = true; }, 4000);
}

function relativeTime(ms) {
  const minutes = Math.round((Date.now() - ms) / 60000);
  if (minutes < 1) return '刚刚';
  if (minutes < 60) return `${minutes} 分钟前`;
  const hours = Math.round(minutes / 60);
  return hours < 24 ? `${hours} 小时前` : `${Math.round(hours / 24)} 天前`;
}

/* ---------- fragments ---------- */
function regionEditor(s, onlyUnknown = false) {
  return s.doc.groups.map((g, i) => onlyUnknown && g.region !== 'UNKNOWN' ? '' : `
    <div class="region-row">
      <div class="region-name">${escape(g.name)}${g.region === 'UNKNOWN' ? '<small>未指定地区 · 不会被当作任何地区</small>' : ''}</div>
      <label class="sr-only" for="region-${i}">${escape(g.name)} 的地区</label>
      <select id="region-${i}" data-region="${escape(g.name)}" ${s.busy ? 'disabled' : ''}>
        ${Object.entries(REGIONS).map(([code, label]) => `<option value="${code}" ${code === g.region ? 'selected' : ''}>${label}</option>`).join('')}
      </select>
    </div>`).join('');
}

function validationHTML(v) {
  return `<p class="validation ${v.status}">${icon(VALIDATION_ICON[v.status])}<span>${escape(v.message)}</span></p>`;
}

function cardHTML(t, c, index) {
  const target = c.action === 'remove' ? '移除已有规则' : c.target;
  let control;
  if (t.status === 'pending') {
    control = `<div class="decision" role="group" aria-label="${escape(c.label)} 的审批">
      ${['accepted', 'rejected'].map(d => `<button data-action="decide" data-turn="${t.id}" data-index="${index}" data-decision="${d}" aria-pressed="${c.decision === d}">${d === 'accepted' ? '接受' : '拒绝'}</button>`).join('')}
    </div>`;
  } else {
    const label = c.decision === 'applied' ? '已写入' : c.decision === 'rejected' ? '已拒绝' : t.status === 'blocked' ? '不能写入' : '未写入';
    control = `<span class="state-chip ${c.decision}">${c.decision === 'applied' ? icon('check') : ''}${label}</span>`;
  }
  const shown = c.after.slice(0, 2);
  return `<article class="card ${c.decision === 'rejected' ? 'rejected' : ''}">
    <div class="card-head"><span class="badge ${c.action}">${ACTION[c.action]}</span><strong>${escape(c.label)}</strong>${icon('arrow', 'arrow')}<span class="target">${escape(target)}</span>${control}</div>
    <div class="rule-lines">
      ${c.before.map(r => `<span class="minus">− ${escape(r)}</span>`).join('')}
      ${shown.map(r => `<span class="plus">+ ${escape(r)}</span>`).join('')}
      ${c.after.length > 2 ? `<small>以及另外 ${c.after.length - 2} 条</small>` : ''}
      ${!c.before.length && !c.after.length ? '<small>没有规则变化</small>' : ''}
    </div>
    <details><summary>${c.domains.length} 个域名 · 匹配范围</summary><ul>${c.domains.map(d => `<li>${escape(d)}</li>`).join('')}</ul></details>
  </article>`;
}

function turnHTML(s, t) {
  const running = t.status === 'running';
  const label = running ? '处理中' : t.status === 'failed' ? '处理未完成' : t.status === 'cancelled' ? '已取消' : `处理完成 · ${t.steps.length} 个步骤`;
  const steps = `<div class="steps">
    <button class="steps-toggle" data-action="steps" data-turn="${t.id}" aria-expanded="${t.open}" ${running ? 'disabled' : ''}>
      ${running ? '<span class="thinking" aria-hidden="true"><i></i><i></i><i></i></span>' : icon('chevron', 'chevron')}${label}
    </button>
    <div class="collapse ${t.open ? 'open' : ''}"><div><ul class="step-list">${t.steps.map(step => `<li>${escape(step)}</li>`).join('')}</ul></div></div>
  </div>`;
  let body = '';
  if (t.status === 'failed') {
    body = `<p class="error" role="alert">${icon('alert')}<span>${escape(t.error)}</span></p><div><button class="text-button" data-action="retry" data-turn="${t.id}">${icon('retry')}重试此指令</button></div>`;
  } else if (t.status === 'clarify') {
    body = `<div class="question"><p class="answer">${escape(t.question)}</p><small>直接回复，或选择一个建议。草稿没有变化。</small>
      <div class="chips">${t.suggestions.map(p => `<button class="chip" data-action="prompt" data-prompt="${escape(p)}">${escape(p)}</button>`).join('')}</div></div>`;
  } else if (t.status === 'cancelled') {
    body = '<p class="answer">操作已取消，草稿未改变。</p>';
  } else if (t.changes.length) {
    const accepted = acceptedCount(t);
    const st = diffStats(diffRules(t.base, candidateRules(t)));
    const text = {
      pending: `生成了 ${t.changes.length} 项修改。逐项接受或拒绝，然后写入草稿。`,
      blocked: '已生成修改，但校验没有通过，这些修改不能写入。',
      confirmed: '已写入草稿，尚未应用到代理。导出后由代理客户端加载。',
      undone: '已撤销这次写入，草稿恢复到之前的快照。',
      superseded: '之后的操作改变了草稿或出口地区，这轮修改已失效，只能查看。',
      discarded: '已全部拒绝，草稿未改变。',
      unchanged: '这些规则已经存在，草稿无需修改。',
    }[t.status] ?? '';
    let actions = `<button class="text-button" data-action="review" data-turn="${t.id}">在检查器中查看 Diff（+${st.add} −${st.remove}）</button>`;
    if (t.status === 'pending') {
      actions = `<button class="primary" data-action="apply" data-turn="${t.id}" ${accepted && !s.busy ? '' : 'disabled'}>${accepted ? `写入 ${accepted} 项到草稿` : '没有接受的修改'}</button>
        <button class="secondary" data-action="reject-all" data-turn="${t.id}" ${s.busy ? 'disabled' : ''}>全部拒绝</button>${actions}`;
    } else if (t.status === 'confirmed') {
      actions = `<button class="secondary" data-action="undo" data-turn="${t.id}" ${canUndo(s, t.id) ? '' : 'disabled title="只能撤销最近一次写入"'}>撤销写入</button>${actions}`;
    }
    body = `<p class="answer">${escape(text)}</p>
      <div class="cards">${t.changes.map((c, i) => cardHTML(t, c, i)).join('')}</div>
      ${validationHTML(t.validation)}
      <div class="turn-actions">${actions}</div>
      <p class="limits">地区来自组名推断，未实测；不代表网络可达或服务解锁。</p>`;
  } else if (!running) {
    body = '<p class="answer">没有生成修改。</p>';
  }
  return `<article class="turn" id="turn-${t.id}">
    <div class="user">${escape(t.prompt)}<small>${t.mode === 'ai' ? 'AI 理解 · 匿名上下文' : '本地解析'}</small></div>
    ${steps}${body}
  </article>`;
}

function startHTML(s) {
  const unknown = unknownRegions(s);
  const examples = ['Netflix 走日本，ChatGPT 走美国', '@YouTube 走 @香港 IPLC', '删除 Netflix 规则', '节点太卡了'];
  return `<div class="start">
    <h2>想如何调整分流？</h2>
    <p>描述服务与出口。输入 <kbd>/</kbd> 选择操作，<kbd>@</kbd> 选择服务或出口。每项修改都由你逐项审批后才写入草稿。</p>
    ${unknown.length ? `<section class="card-warn" aria-labelledby="region-check">
      <header>${icon('alert')}<div><h3 id="region-check">请确认 ${unknown.length} 个出口的地区</h3><p>无法从组名推断。设置后才能用“走新加坡”等说法指向它；也可以直接用 @ 选择完整名称。</p></div></header>
      ${regionEditor(s, true)}</section>` : ''}
    <div class="chips">${examples.map(p => `<button class="chip" data-action="prompt" data-prompt="${escape(p)}">${escape(p)}</button>`).join('')}</div>
  </div>`;
}

/* ---------- inspector ---------- */
function diffPanel(s) {
  const t = selectedTurn();
  if (!t?.changes.length) {
    return `<div class="empty">${icon('file')}<p>发送一条分流指令后，在这里查看规则差异。</p></div>`;
  }
  const lines = diffRules(t.base, candidateRules(t));
  const st = diffStats(lines);
  return `<div class="section-head"><h3>第 ${t.id} 轮 · ${escape(STATUS[t.status])}</h3><small><span class="plus">+${st.add}</span> <span class="minus">−${st.remove}</span></small></div>
    <p class="limits">${t.status === 'pending' ? '只包含已接受的修改；拒绝的项不会出现在这里。' : '仅修改 rules；其他字段逐字节保留。'}</p>
    <div class="diff" tabindex="0" aria-label="规则差异，可横向滚动"><pre>${lines.map((l, i) => `<span class="diff-line ${l.kind}"><span class="ln">${i + 1}</span><span class="sign">${l.kind === 'add' ? '+' : l.kind === 'remove' ? '−' : ''}</span>${escape(l.text)}</span>`).join('')}</pre></div>
    ${validationHTML(t.validation)}
    <div class="section-head"><button class="text-button" id="copy-diff">复制差异</button></div>`;
}

function rulesPanel(s) {
  const exported = new Set(s.exported);
  const rows = searchRules(s.draft, ui.ruleQuery);
  const unsaved = hasUnsavedChanges(s);
  return `<div class="field"><label class="sr-only" for="rule-query">筛选规则</label><input id="rule-query" type="search" placeholder="筛选规则，例如 netflix 或 DIRECT" value="${escape(ui.ruleQuery)}"></div>
    <div class="section-head"><h3>当前草稿 · ${s.draft.length + 1} 条</h3><small>${unsaved ? '<span class="chip-warn">有未导出的修改</span>' : '与上次导出一致'}</small></div>
    ${rows.length ? `<ol class="rule-table">${rows.map(r => `<li class="${exported.has(r.rule) || r.rule === 'MATCH,DIRECT' ? '' : 'new'}"><span class="ln">${r.index}</span><span>${escape(r.rule)}</span></li>`).join('')}</ol>`
      : `<div class="empty"><p>没有匹配“${escape(ui.ruleQuery)}”的规则。</p></div>`}
    <p class="limits">高亮行是上次导出后新增的规则。规则按顺序匹配，第一条命中即生效。</p>`;
}

function testResultHTML(label, rules, domain) {
  const r = matchDomain(rules, domain);
  if (r.error) return `<p class="error">${icon('alert')}<span>${escape(r.error)}</span></p>`;
  return `<div class="result" aria-live="polite">
    <small>${escape(label)}</small>
    <div class="route">${escape(r.domain)}${icon('arrow')}<span>${escape(r.target)}</span></div>
    <code>命中第 ${r.index} 条：${escape(r.rule)}</code>
    ${r.skipped.length ? `<small>跳过 ${r.skipped.length} 条需要内核数据或 DNS 的规则（${r.skipped.map(x => escape(x.rule.split(',').slice(0, 2).join(','))).join('、')}）。实际结果可能更早命中它们。</small>` : ''}
  </div>`;
}

function testPanel(s) {
  const t = selectedTurn();
  const pending = t?.status === 'pending' ? t : null;
  return `<form id="test-form" class="field"><label class="sr-only" for="test-domain">测试域名</label>
      <input id="test-domain" placeholder="输入域名，例如 www.netflix.com" value="${escape(ui.testDomain)}" autocomplete="off"><button class="primary">测试</button></form>
    ${ui.testDomain ? testResultHTML('当前草稿', s.draft, ui.testDomain) + (pending ? testResultHTML(`写入第 ${pending.id} 轮已接受的修改后`, candidateRules(pending), ui.testDomain) : '')
      : `<div class="empty">${icon('target')}<p>检查一个域名会命中哪条规则、走哪个出口。只在本机计算，不访问网络。</p></div>`}`;
}

function renderInspector(s) {
  document.querySelectorAll('.tabs [role=tab]').forEach(tab => { tab.setAttribute('aria-selected', String(tab.dataset.tab === ui.tab)); tab.tabIndex = tab.dataset.tab === ui.tab ? 0 : -1; });
  if (!s) { $('inspector-body').innerHTML = ''; return; }
  $('inspector-body').innerHTML = ui.tab === 'diff' ? diffPanel(s) : ui.tab === 'rules' ? rulesPanel(s) : testPanel(s);
  const foot = `<div class="inspector-foot"><small>导出完整配置副本，原文件不会被覆盖。</small><button class="secondary" data-action="export" ${s.busy ? 'disabled' : ''}>${icon('export')}导出…</button></div>`;
  $('inspector').querySelector('.inspector-foot')?.remove();
  $('inspector').insertAdjacentHTML('beforeend', foot);
  $('copy-diff')?.addEventListener('click', async () => {
    const t = selectedTurn();
    const text = diffRules(t.base, candidateRules(t)).map(l => (l.kind === 'add' ? '+' : l.kind === 'remove' ? '-' : ' ') + l.text).join('\n');
    try { await navigator.clipboard.writeText(text); toast('已复制差异。'); } catch { toast('无法访问剪贴板，可在 Diff 中选择文本复制。'); }
  });
  $('rule-query')?.addEventListener('input', e => {
    ui.ruleQuery = e.target.value;
    const caret = e.target.selectionStart;
    renderInspector(s);
    const input = $('rule-query'); input.focus(); input.setSelectionRange(caret, caret);
  });
  $('test-form')?.addEventListener('submit', e => { e.preventDefault(); ui.testDomain = $('test-domain').value; renderInspector(s); $('test-domain').focus(); });
}

/* ---------- render ---------- */
function renderSessions() {
  const list = filterSessions(app, ui.query);
  $('sessions').innerHTML = list.length ? list.map(s => {
    const last = s.turns.at(-1)?.prompt ?? `${s.doc.groups.length} 个出口 · ${s.draft.length + 1} 条规则`;
    return `<li class="session-row">
      <button class="session" data-action="session" data-id="${s.id}" aria-current="${s.id === app.activeId}">
        <span class="session-name">${hasUnsavedChanges(s) ? '<span class="unsaved-dot" aria-label="有未导出的修改"></span>' : ''}${escape(s.doc.name)}</span>
        <span class="session-time">${relativeTime(s.updatedAt)}</span>
        <span class="session-sub">${escape(last)}</span>
      </button>
      <button class="icon-button small delete" data-action="delete-session" data-id="${s.id}" aria-label="删除会话 ${escape(s.doc.name)}">${icon('trash')}</button>
    </li>`;
  }).join('') : `<li class="empty-list"><p>${app.sessions.length ? '没有匹配的会话。' : '还没有会话。导入一份配置开始。'}</p></li>`;
}

function renderBanner() {
  const banner = $('service-banner');
  banner.hidden = app.service === 'ready';
  banner.className = `service-banner${app.service === 'unavailable' ? ' down' : ''}`;
  banner.setAttribute('role', app.service === 'unavailable' ? 'alert' : 'status');
  banner.innerHTML = app.service === 'starting'
    ? '<span class="spinner" aria-hidden="true"></span>正在启动内置编辑服务…'
    : `${icon('alert')}<span>内置编辑服务已停止。所有会话与草稿仍保留在本机。</span><button data-action="restart">重新启动服务</button>`;
}

function render() {
  const s = session();
  const unsaved = hasUnsavedChanges(s);
  document.body.classList.toggle('inspector-open', ui.inspector && !!s);
  document.body.classList.toggle('sidebar-open', ui.sidebar);
  $('scrim').hidden = !ui.sidebar;
  $('sidebar-toggle').setAttribute('aria-expanded', String(ui.sidebar));
  $('key-state').textContent = { none: '未设置', session: '会话 Key', saved: '已保存' }[app.key];

  $('title').textContent = s?.doc.name ?? 'Veer Editor';
  $('title').title = s?.doc.name ?? '';
  $('meta').innerHTML = s
    ? `<span>${s.doc.source === 'url' ? '订阅' : '文件'} · ${s.draft.length + 1} 条规则 · 未应用代理</span>${unsaved ? '<span class="chip-warn">未导出</span>' : ''}`
    : '<span>仅编辑分流规则 · 不控制代理</span>';
  const unknown = s ? unknownRegions(s).length : 0;
  $('regions').disabled = !s;
  $('regions-badge').hidden = !unknown;
  $('regions-badge').textContent = unknown || '';
  $('regions').setAttribute('aria-label', unknown ? `出口地区，${unknown} 个未指定` : '出口地区');
  $('export').disabled = !s || !!s.busy;
  $('inspector-toggle').disabled = !s;
  $('inspector-toggle').setAttribute('aria-expanded', String(ui.inspector));
  $('inspector-toggle').setAttribute('aria-label', ui.inspector ? '关闭检查器' : '显示检查器');

  renderSessions();
  renderBanner();
  $('landing').hidden = !!s;
  $('messages').innerHTML = !s ? '' : s.turns.length ? s.turns.map(t => turnHTML(s, t)).join('') : startHTML(s);

  const ready = app.service === 'ready' && !!s;
  $('prompt').disabled = !ready || !!s?.busy;
  $('prompt').placeholder = !s ? '导入配置以开始' : app.service !== 'ready' ? '等待编辑服务…' : '描述分流修改，例如 Netflix 走日本';
  document.querySelectorAll('[data-mode]').forEach(b => { b.setAttribute('aria-checked', String(b.dataset.mode === app.mode)); b.disabled = !ready || !!s?.busy; b.tabIndex = b.dataset.mode === app.mode ? 0 : -1; });
  $('key-hint').hidden = !(s && app.mode === 'ai' && app.key === 'none');
  $('send').innerHTML = icon(s?.busy ? 'stop' : 'up');
  $('send').type = s?.busy ? 'button' : 'submit';
  $('send').setAttribute('aria-label', s?.busy ? '取消处理' : '发送');
  $('send').disabled = !s?.busy && (!canSend(app, s) || !$('prompt').value.trim());
  $('work-status').textContent = s?.busy ? '处理中…' : '';

  $('inspector').hidden = !ui.inspector || !s;
  $('splitter').hidden = !ui.inspector || !s;
  $('inspector').style.setProperty('--inspector', `${ui.width}px`);
  $('splitter').setAttribute('aria-valuenow', String(ui.width));
  renderInspector(s);

  const timeline = $('timeline');
  if (ui.following && timeline.getClientRects().length) timeline.scrollTop = timeline.scrollHeight;
  updateScrollState();
  save();
}

function updateScrollState() {
  const t = $('timeline');
  const atBottom = t.scrollHeight - t.clientHeight - t.scrollTop < 40;
  t.classList.toggle('fade-top', t.scrollTop > 4);
  t.classList.toggle('fade-bottom', !atBottom);
  $('latest').hidden = !session()?.turns.length || atBottom;
}

/* ---------- composer and completion menu ---------- */
function autoGrow() {
  const el = $('prompt');
  el.style.height = 'auto';
  el.style.height = `${Math.min(el.scrollHeight, 200)}px`;
}

function updateMenu() {
  const el = $('prompt');
  const trigger = triggerAt(el.value, el.selectionStart);
  const items = menuItems(session(), trigger);
  ui.menu = trigger && items.length ? { trigger, items, index: Math.min(ui.menu?.index ?? 0, items.length - 1) } : null;
  const menu = $('menu');
  el.setAttribute('aria-expanded', String(!!ui.menu));
  if (!ui.menu) { menu.hidden = true; el.removeAttribute('aria-activedescendant'); return; }
  menu.hidden = false;
  const title = trigger.char === '/' ? '操作' : '服务与出口';
  menu.innerHTML = `<div class="menu-title">${title}</div>` + items.map((item, i) => `
    <div class="menu-item" role="option" id="menu-${i}" data-index="${i}" aria-selected="${i === ui.menu.index}">
      ${icon(item.kind === 'command' ? 'slash' : item.kind === 'service' ? 'at' : 'target')}
      <span class="label">${escape(item.label)}</span><small>${escape(item.hint ?? '')}</small>
    </div>`).join('');
  el.setAttribute('aria-activedescendant', `menu-${ui.menu.index}`);
  menu.querySelector('[aria-selected=true]')?.scrollIntoView({ block: 'nearest' });
}

function chooseMenuItem(index) {
  const el = $('prompt');
  const { trigger, items } = ui.menu;
  const item = items[index];
  if (item.action === 'check') {
    const rest = (el.value.slice(0, trigger.start) + el.value.slice(trigger.end)).trim();
    el.value = '';
    ui.menu = null; updateMenu();
    ui.inspector = true; ui.tab = 'test'; ui.testDomain = /\./.test(rest) ? rest : '';
    render();
    $('test-domain')?.focus();
    return;
  }
  const next = applyMenuItem(el.value, trigger, item);
  el.value = next.text;
  el.setSelectionRange(next.caret, next.caret);
  ui.menu = null;
  updateMenu(); autoGrow(); syncSend();
  el.focus();
}

function syncSend() {
  const s = session();
  $('send').disabled = !s?.busy && (!canSend(app, s) || !$('prompt').value.trim());
}

$('prompt').addEventListener('input', () => { autoGrow(); updateMenu(); syncSend(); });
$('prompt').addEventListener('click', updateMenu);
$('prompt').addEventListener('blur', () => setTimeout(() => { if (document.activeElement !== $('prompt')) { ui.menu = null; updateMenu(); } }, 120));
$('prompt').addEventListener('keydown', e => {
  // Never act on keys that belong to an IME composition (pinyin candidates, etc.).
  if (e.isComposing || e.keyCode === 229) return;
  if (ui.menu) {
    if (e.key === 'ArrowDown' || e.key === 'ArrowUp') {
      e.preventDefault();
      const n = ui.menu.items.length;
      ui.menu.index = (ui.menu.index + (e.key === 'ArrowDown' ? 1 : n - 1)) % n;
      updateMenu();
      return;
    }
    if (e.key === 'Enter' || e.key === 'Tab') { e.preventDefault(); chooseMenuItem(ui.menu.index); return; }
    if (e.key === 'Escape') { e.preventDefault(); ui.menu = null; updateMenu(); return; }
  }
  if (e.key === 'Enter' && !e.shiftKey) { e.preventDefault(); send(); }
});
$('menu').addEventListener('mousedown', e => {
  const item = e.target.closest('.menu-item');
  if (!item) return;
  e.preventDefault();
  chooseMenuItem(Number(item.dataset.index));
});

/* ---------- actions ---------- */
function send() {
  const s = session();
  const turn = startTurn(app, s, $('prompt').value);
  if (!turn) return;
  const run = scenario();
  $('prompt').value = ''; autoGrow(); ui.menu = null; updateMenu();
  ui.following = true;
  render();
  const timers = [
    setTimeout(() => { if (s.busy === turn.id) { turn.steps.push(turn.mode === 'ai' ? '等待 AI 返回结构化计划…' : '正在生成规则候选…'); render(); } }, 700),
    setTimeout(() => {
      completeTurn(s, turn.id, run);
      ui.timers.delete(s.id);
      if (turn.changes.length && innerWidth >= 1100) { ui.inspector = true; ui.tab = 'diff'; }
      render();
      if (turn.status === 'failed') toast('处理未完成，详情保留在对话中。');
    }, 1600),
  ];
  ui.timers.set(s.id, timers);
}

function cancel() {
  const s = session();
  ui.timers.get(s.id)?.forEach(clearTimeout);
  ui.timers.delete(s.id);
  cancelTurn(s);
  render();
  toast('已取消，草稿未改变。');
}

function startService() {
  app.service = 'starting';
  render();
  setTimeout(() => { app.service = 'ready'; render(); }, 900);
}

function openImport() {
  if (anyBusy(app)) { toast('请先等待或取消当前处理。'); return; }
  $('import-dialog').showModal();
}

function load(source) {
  const s = createSession(app, $('long-sample').checked ? 'long' : 'normal', source);
  $('import-dialog').close();
  ui.following = true; ui.sidebar = false; ui.inspector = false;
  $('prompt').value = '';
  if (scenario() === 'service-down') app.service = 'unavailable';
  render();
  toast(unknownRegions(s).length ? '已创建会话。请先确认未指定地区的出口。' : '已创建会话，可开始对话。');
  $('prompt').focus();
}

function openExport() {
  const s = session();
  if (!s || s.busy) return;
  const st = diffStats(diffRules(s.exported, s.draft));
  $('export-content').innerHTML = `<p>导出包含修改后 rules 的完整配置副本。节点、Provider、DNS 等字段保持原样；原文件 <strong>${escape(s.doc.name)}</strong> 不会被覆盖。</p>
    <div class="stats"><span class="plus">+${st.add}</span><span class="minus">−${st.remove}</span><small>相对上次导出</small></div>
    ${st.add + st.remove ? '' : '<p>草稿与上次导出相同；仍可再次导出。</p>'}
    <p>导出后请由代理客户端加载并校验。Veer 编辑器不启动或控制代理。</p>`;
  $('export-dialog').showModal();
}

function openRegions() {
  const s = session();
  if (!s) return;
  $('regions-content').innerHTML = regionEditor(s);
  $('regions-dialog').showModal();
}

document.addEventListener('click', e => {
  const el = e.target.closest('[data-action]');
  if (!el) return;
  const s = session();
  const id = Number(el.dataset.turn);
  switch (el.dataset.action) {
    case 'decide': if (setDecision(s, id, Number(el.dataset.index), el.dataset.decision)) render(); break;
    case 'apply': {
      const t = s.turns.find(x => x.id === id);
      const n = acceptedCount(t);
      if (applyTurn(s, id)) { render(); toast(`已写入 ${n} 项到草稿，尚未应用到代理。`); }
      else { render(); toast('草稿已变化，这轮修改已失效。请重新生成。'); }
      break;
    }
    case 'reject-all': if (rejectTurn(s, id)) { render(); toast('已全部拒绝，草稿未改变。'); } break;
    case 'undo': if (undoTurn(s, id)) { render(); toast('已撤销写入。'); } break;
    case 'retry': { const t = s.turns.find(x => x.id === id); if (t && !s.busy) { $('prompt').value = t.prompt; send(); } break; }
    case 'prompt': $('prompt').value = el.dataset.prompt; autoGrow(); syncSend(); $('prompt').focus(); break;
    case 'review': s.selected = id; ui.inspector = true; ui.tab = 'diff'; render(); break;
    case 'steps': { const t = s.turns.find(x => x.id === id); if (t && t.status !== 'running') { t.open = !t.open; render(); } break; }
    case 'session':
      if (el.dataset.id === app.activeId) { ui.sidebar = false; render(); break; }
      if (switchSession(app, el.dataset.id)) { ui.following = true; ui.sidebar = false; ui.testDomain = ''; ui.ruleQuery = ''; render(); }
      else toast('请先等待或取消当前处理，再切换会话。');
      break;
    case 'delete-session': {
      const target = app.sessions.find(x => x.id === el.dataset.id);
      if (!target) break;
      if (hasUnsavedChanges(target) && !confirm(`“${target.doc.name}”有未导出的修改。删除后无法恢复，继续？`)) break;
      if (deleteSession(app, target.id)) { render(); toast('会话已删除。'); }
      break;
    }
    case 'export': openExport(); break;
    case 'restart': $('scenario').value = 'normal'; startService(); break;
  }
});

document.addEventListener('change', e => {
  const name = e.target.dataset?.region;
  if (!name) return;
  const s = session();
  const hadPending = s.turns.some(t => t.status === 'pending');
  if (!setRegion(s, name, e.target.value)) return;
  render();
  if ($('regions-dialog').open) $('regions-content').innerHTML = regionEditor(s);
  toast(`已将“${name}”设为${REGIONS[e.target.value]}。${hadPending ? '待审批的修改已失效，请重新生成。' : ''}`);
});

$('composer').addEventListener('submit', e => { e.preventDefault(); if (!session()?.busy) send(); });
$('send').addEventListener('click', e => { if (session()?.busy) { e.preventDefault(); cancel(); } });
document.querySelectorAll('[data-mode]').forEach(b => b.addEventListener('click', () => { app.mode = b.dataset.mode; render(); }));
document.querySelector('.segmented').addEventListener('keydown', e => {
  if (!['ArrowLeft', 'ArrowRight'].includes(e.key)) return;
  app.mode = app.mode === 'local' ? 'ai' : 'local';
  render();
  document.querySelector(`[data-mode=${app.mode}]`).focus();
});
$('key-hint').addEventListener('click', () => openAi());

$('new-session').addEventListener('click', openImport);
$('landing-import').addEventListener('click', openImport);
$('sample-file').addEventListener('click', () => load('file'));
$('sample-url').addEventListener('click', () => load('url'));
$('session-search').addEventListener('input', e => { ui.query = e.target.value; renderSessions(); });
$('regions').addEventListener('click', openRegions);
$('export').addEventListener('click', openExport);
$('inspector-toggle').addEventListener('click', () => { ui.inspector = !ui.inspector; render(); });
$('inspector-close').addEventListener('click', () => { ui.inspector = false; render(); $('prompt').focus(); });
document.querySelectorAll('.tabs [role=tab]').forEach(tab => tab.addEventListener('click', () => { ui.tab = tab.dataset.tab; render(); }));
document.querySelector('.tabs').addEventListener('keydown', e => {
  if (!['ArrowLeft', 'ArrowRight'].includes(e.key)) return;
  const order = ['diff', 'rules', 'test'];
  ui.tab = order[(order.indexOf(ui.tab) + (e.key === 'ArrowRight' ? 1 : 2)) % 3];
  render();
  document.querySelector(`[data-tab=${ui.tab}]`).focus();
});
$('sidebar-toggle').addEventListener('click', () => { ui.sidebar = !ui.sidebar; render(); });
$('scrim').addEventListener('click', () => { ui.sidebar = false; render(); });

function openAi() {
  document.querySelectorAll('input[name=key]').forEach(el => { el.checked = el.value === app.key; });
  $('ai-dialog').showModal();
}
$('ai-settings').addEventListener('click', openAi);
document.querySelectorAll('input[name=key]').forEach(el => el.addEventListener('change', () => {
  app.key = el.value;
  render();
  toast({ none: '已移除 Key。AI 理解不可用。', session: '已使用会话 Key（演示）；重新打开后清除。', saved: '已保存到钥匙串（演示）。' }[app.key]);
}));
document.querySelectorAll('[data-close]').forEach(el => el.addEventListener('click', () => el.closest('dialog').close()));
$('toast-close').addEventListener('click', () => { $('toast').hidden = true; clearTimeout(ui.toastTimer); });

$('export-confirm').addEventListener('click', () => {
  const s = session();
  const name = s.doc.name.replace(/\.ya?ml$/i, '') + '-edited.yaml';
  const url = URL.createObjectURL(new Blob([`# 合成演示副本；不含真实节点，不能作为可用代理配置\n${toYaml(s.draft)}`], { type: 'text/yaml' }));
  Object.assign(document.createElement('a'), { href: url, download: name }).click();
  setTimeout(() => URL.revokeObjectURL(url), 1000);
  markExported(s);
  $('export-dialog').close();
  render();
  toast(`已导出 ${name}；原文件未覆盖。`);
});

$('scenario').addEventListener('change', () => {
  if (scenario() !== 'service-down') return;
  app.sessions.forEach(s => { if (s.busy) { ui.timers.get(s.id)?.forEach(clearTimeout); cancelTurn(s); } });
  app.service = 'unavailable';
  render();
});
$('clear-data').addEventListener('click', () => {
  if (!confirm('清除本机保存的全部演示会话？')) return;
  try { store?.removeItem(STORAGE); } catch { /* ignore */ }
  Object.assign(app, initialApp());
  ui.inspector = false;
  render();
});

/* ---------- splitter ---------- */
const splitter = $('splitter');
const clampWidth = w => Math.round(Math.min(Math.max(w, 360), Math.max(360, $('workspace').clientWidth - 420)));
function setWidth(w) {
  ui.width = clampWidth(w);
  $('inspector').style.setProperty('--inspector', `${ui.width}px`);
  splitter.setAttribute('aria-valuenow', String(ui.width));
  try { store?.setItem(LAYOUT, String(ui.width)); } catch { /* ignore */ }
}
splitter.addEventListener('pointerdown', e => {
  const startX = e.clientX, startW = ui.width;
  let moved = false;
  splitter.setPointerCapture(e.pointerId);
  splitter.classList.add('dragging');
  const move = ev => {
    // A small dead zone keeps clicks from resizing.
    if (!moved && Math.abs(ev.clientX - startX) < 4) return;
    moved = true;
    setWidth(startW - (ev.clientX - startX));
  };
  const up = () => { splitter.classList.remove('dragging'); splitter.removeEventListener('pointermove', move); };
  splitter.addEventListener('pointermove', move);
  splitter.addEventListener('pointerup', up, { once: true });
  splitter.addEventListener('pointercancel', up, { once: true });
});
splitter.addEventListener('dblclick', () => setWidth(440));
splitter.addEventListener('keydown', e => {
  if (e.key === 'ArrowLeft') { e.preventDefault(); setWidth(ui.width + 24); }
  if (e.key === 'ArrowRight') { e.preventDefault(); setWidth(ui.width - 24); }
  if (e.key === 'Home') { e.preventDefault(); setWidth(440); }
});

/* ---------- scrolling and shortcuts ---------- */
const timeline = $('timeline');
timeline.addEventListener('wheel', () => { ui.following = false; }, { passive: true });
timeline.addEventListener('touchstart', () => { ui.following = false; }, { passive: true });
timeline.addEventListener('keydown', e => { if (['Home', 'End', 'PageUp', 'PageDown', 'ArrowUp', 'ArrowDown'].includes(e.key)) ui.following = false; });
timeline.addEventListener('scroll', () => {
  if (timeline.scrollHeight - timeline.clientHeight - timeline.scrollTop < 40) ui.following = true;
  updateScrollState();
}, { passive: true });
$('latest').addEventListener('click', () => { ui.following = true; timeline.scrollTop = timeline.scrollHeight; updateScrollState(); });

document.addEventListener('keydown', e => {
  const mod = e.metaKey || e.ctrlKey;
  if (!mod || document.querySelector('dialog[open]')) return;
  const key = e.key.toLowerCase();
  if (key === 'o') { e.preventDefault(); openImport(); }
  if (key === 'e' && session()) { e.preventDefault(); openExport(); }
  if (key === 'i' && session()) { e.preventDefault(); ui.inspector = !ui.inspector; render(); }
});

let dark = matchMedia('(prefers-color-scheme: dark)').matches;
function applyTheme() {
  document.documentElement.dataset.theme = dark ? 'dark' : 'light';
  $('theme').innerHTML = icon(dark ? 'sun' : 'moon');
  $('theme').setAttribute('aria-label', dark ? '切换浅色外观' : '切换深色外观');
}
$('theme').addEventListener('click', () => { dark = !dark; applyTheme(); });
applyTheme();
startService();
