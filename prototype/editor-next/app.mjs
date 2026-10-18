import {
  REGIONS, initialState, importDocument, unknownRegions, hasUnsavedChanges, setRegion, canSend, startTurn,
  completeTurn, cancelTurn, confirmTurn, discardTurn, undoTurn, canUndo, diffRules, diffStats, toYaml, markExported,
} from './state.mjs';

const $ = id => document.getElementById(id);
const escape = value => String(value).replace(/[&<>"']/g, c => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' })[c]);

const PATHS = {
  plus: 'M12 4v16M4 12h16', up: 'M12 20V4m-6 6 6-6 6 6', down: 'M12 4v16m-6-6 6 6 6-6', right: 'm9 5 7 7-7 7',
  close: 'm6 6 12 12M6 18 18 6', file: 'M14 2H5v20h14V7Zm0 0v5h5M8 12h8M8 16h8', chat: 'M4 4h16v12H9l-5 4Zm4 4h8M8 12h5',
  globe: 'M12 3a9 9 0 1 0 0 18 9 9 0 0 0 0-18M3 12h18M12 3c3 3 3 15 0 18M12 3c-3 3-3 15 0 18', key: 'M14 10a4 4 0 1 0-3 3.9V21h3v-2h2v-3h-2v-2.1A4 4 0 0 0 14 10Z',
  menu: 'M4 6h16M4 12h16M4 18h16', export: 'M12 15V3m-4 4 4-4 4 4M5 10v11h14V10', panel: 'M3 4h18v16H3Zm11 0v16',
  moon: 'M20 15A8 8 0 0 1 9 4a8 8 0 1 0 11 11', sun: 'M12 7a5 5 0 1 0 0 10 5 5 0 0 0 0-10M12 2v2m0 16v2M2 12h2m16 0h2M5 5l1 1m12 12 1 1M5 19l1-1M18 6l1-1',
  check: 'm5 12 4 4L19 6', x: 'm7 7 10 10M7 17 17 7', alert: 'M12 4 2 20h20Zm0 6v4m0 3v.5', help: 'M12 21a9 9 0 1 0 0-18 9 9 0 0 0 0 18m-2.5-11.5a2.5 2.5 0 1 1 3.5 2.3c-.6.3-1 .9-1 1.6v.6m0 3v.5',
  stop: 'M7 7h10v10H7Z', retry: 'M4 12a8 8 0 1 0 2.3-5.7M4 4v4h4',
};
const icon = name => `<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.6" stroke-linecap="round" stroke-linejoin="round" aria-hidden="true"><path d="${PATHS[name] ?? PATHS.file}"/></svg>`;
const fillIcons = root => root.querySelectorAll('[data-icon]').forEach(el => { el.innerHTML = icon(el.dataset.icon); });
fillIcons(document);

const STATUS = {
  running: '处理中', pending: '候选修改 · 尚未写入草稿', blocked: '校验失败 · 不能确认', confirmed: '已确认到草稿',
  undone: '已撤销', superseded: '已被后续操作取代', cancelled: '已取消', failed: '未完成', clarify: '需要澄清',
  discarded: '已放弃', unchanged: '规则已存在 · 无需修改',
};
const ACTION = { route: '路由', remove: '删除' };
const VALIDATION_ICON = { passed: 'check', failed: 'x', unavailable: 'alert' };

const s = initialState();
let reviewOpen = false, reviewTab = 'changes', following = true, timers = [], toastTimer;
const disclosures = new Map();

/* ---------- helpers ---------- */
const clearTimers = () => { timers.forEach(clearTimeout); timers = []; };
const later = (ms, fn) => timers.push(setTimeout(fn, ms));
function toast(text) {
  clearTimeout(toastTimer);
  $('toast-text').textContent = text;
  $('toast').hidden = false;
  toastTimer = setTimeout(() => { $('toast').hidden = true; }, 4000);
}
const selected = () => s.turns.find(t => t.id === s.selected);
const stats = t => diffStats(diffRules(t.before ?? [], t.after ?? []));
const scenario = () => $('scenario').value;

function startService() {
  s.service = 'starting';
  render();
  later(900, () => { s.service = 'ready'; render(); });
}

/* ---------- fragments ---------- */
function regionEditor() {
  return `<div class="region-list">${s.doc.groups.map(g => `
    <div class="region-row">
      <div class="region-name">${escape(g.name)}${g.region === 'UNKNOWN' ? `<small>${icon('alert')}未指定地区 · 不会被当作任何地区使用</small>` : ''}</div>
      <label class="sr-only" for="region-${escape(g.name)}">${escape(g.name)} 的地区</label>
      <select id="region-${escape(g.name)}" data-region="${escape(g.name)}" ${s.busy ? 'disabled' : ''}>
        ${Object.entries(REGIONS).map(([code, label]) => `<option value="${code}" ${code === g.region ? 'selected' : ''}>${label}</option>`).join('')}
      </select>
    </div>`).join('')}</div>`;
}

function validationHTML(v) {
  return `<p class="validation ${v.status}">${icon(VALIDATION_ICON[v.status])}<span>${escape(v.message)}</span></p>`;
}

function changeRow(c) {
  const target = c.action === 'remove' ? '移除已有规则' : c.target;
  return `<div class="change-row"><span class="badge ${c.action}">${ACTION[c.action]}</span><strong>${escape(c.label)}</strong>${icon('right')}<span class="target">${escape(target)}</span></div>`;
}

function assistantText(t) {
  switch (t.status) {
    case 'running': return '正在生成候选并运行校验…';
    case 'pending': return `已准备 ${t.changes.length} 项修改，等待你审阅。`;
    case 'blocked': return '已生成修改，但校验没有通过，此候选不能确认。';
    case 'confirmed': return '已写入草稿，尚未应用到代理。导出后由代理客户端加载。';
    case 'undone': return '已撤销此次修改，草稿恢复到上一快照。';
    case 'superseded': return '保留此轮修改供查看；之后的操作使它失效，不能再确认。';
    case 'discarded': return '已放弃此次候选，草稿未改变。';
    case 'unchanged': return '这些规则已经存在，草稿无需修改。';
    case 'cancelled': return '操作已取消，草稿未改变。';
    default: return '';
  }
}

function turnHTML(t) {
  const st = t.changes.length ? stats(t) : null;
  const summary = t.status === 'running' ? '处理中' : t.status === 'failed' ? '处理未完成' : t.status === 'cancelled' ? '已取消' : '处理完成';
  let body;
  if (t.status === 'failed') {
    body = `<p class="error-text" role="alert">${icon('alert')}<span>${escape(t.error)}</span></p><button class="text-button" data-retry="${t.id}">${icon('retry')}重试此指令</button>`;
  } else if (t.status === 'clarify') {
    body = `<p class="assistant-text question">${icon('help')}<span>${escape(t.question)}</span></p>
      <div class="chips">${t.suggestions.map(p => `<button data-prompt="${escape(p)}">${escape(p)}</button>`).join('')}</div>`;
  } else {
    body = `<p class="assistant-text">${escape(assistantText(t))}</p>`;
  }
  const changes = t.changes.length ? `
    <div class="change-list">${t.changes.map(changeRow).join('')}</div>
    ${validationHTML(t.validation)}
    <button class="file-change" data-review="${t.id}">
      <span class="file-label">${icon('file')}<strong>${escape(s.doc.name)}</strong></span>
      <span class="file-meta"><span class="plus">+${st.add}</span><span class="minus">−${st.remove}</span>${escape(STATUS[t.status])}${icon('right')}</span>
    </button>
    <p class="limits">${t.status === 'pending' ? '确认前草稿不变。' : ''}地区来自组名推断，未实测；不代表服务解锁。</p>` : '';
  return `<article class="turn" id="turn-${t.id}">
    <div class="user-row"><div class="user-message">${escape(t.prompt)}<small>${t.mode === 'ai' ? 'AI 理解 · 匿名上下文' : '本地解析'}</small></div></div>
    <details class="steps" data-steps="${t.id}" ${t.open ? 'open' : ''}><summary>${summary} · ${t.steps.length} 个步骤</summary>
      <ul class="step-list">${t.steps.map(step => `<li>${escape(step)}</li>`).join('')}</ul></details>
    ${body}${changes}
  </article>`;
}

function startHTML() {
  const unknown = unknownRegions(s);
  const examples = ['Netflix 走日本，ChatGPT 走美国', '删除 Netflix 规则', 'YouTube 走新加坡', '节点太卡了'];
  return `<div class="start">
    <h1>想如何调整分流？</h1>
    <p>告诉 Veer 服务与出口。确认前规则稿不会改变，确认后也只写入草稿。</p>
    ${unknown.length ? `<section class="note-card warn" aria-labelledby="regions-check">
      <header>${icon('alert')}<div><h3 id="regions-check">请确认 ${unknown.length} 个出口的地区</h3>
      <p>无法从组名推断地区。设置后才能用“走新加坡”等说法指向它。</p></div></header>
      ${regionEditor()}</section>` : ''}
    <div class="chips">${examples.map(p => `<button data-prompt="${p}">${p}</button>`).join('')}</div>
  </div>`;
}

function reviewChangesHTML(t) {
  const lines = diffRules(t.before, t.after);
  return `<div class="review-file">${icon('file')}<div><strong>${escape(s.doc.name)}</strong><p class="limits">仅修改 rules · 其他字段逐字节保留</p></div></div>
    <h3>流量出口</h3>
    ${t.changes.map((c, index) => `<section class="review-change">
      ${changeRow(c)}
      <div class="rule-move">
        ${c.before.length ? c.before.map(r => `<span class="minus">− ${escape(r)}</span>`).join('') : '<small>原配置没有对应规则</small>'}
        ${c.after.map((r, i) => i < 2 ? `<span class="plus">+ ${escape(r)}</span>` : '').join('')}
        ${c.after.length > 2 ? `<small>以及另外 ${c.after.length - 2} 条</small>` : ''}
      </div>
      <details data-disclosure="${t.id}:${index}"><summary>${c.domains.length} 个域名 · 匹配范围</summary><ul>${c.domains.map(d => `<li>${escape(d)}</li>`).join('')}</ul></details>
    </section>`).join('')}
    <h3>校验</h3>${validationHTML(t.validation)}
    <div class="section-title"><h3>YAML Diff</h3><button id="copy-diff" class="secondary">复制差异</button></div>
    <div class="diff" tabindex="0" aria-label="YAML 差异，可横向滚动"><pre>${lines.map((l, i) => `<span class="diff-line ${l.kind}"><span class="line-number">${i + 1}</span><span class="diff-sign">${l.kind === 'add' ? '+' : l.kind === 'remove' ? '−' : ''}</span>${escape(l.text)}</span>`).join('')}</pre></div>
    <p class="limits">+ 新增 / − 删除。校验只覆盖修改的规则，不代表网络可达或服务解锁。</p>`;
}

function reviewDraftHTML() {
  const unsaved = hasUnsavedChanges(s);
  return `<p>当前已确认的规则稿。候选修改不计入。${unsaved ? '<strong class="unsaved">有未导出的修改</strong>' : '与上次导出一致。'}</p>
    <pre class="yaml">${escape(toYaml(s.draft))}</pre>`;
}

function renderReview() {
  const t = selected();
  $('tab-changes').setAttribute('aria-selected', String(reviewTab === 'changes'));
  $('tab-draft').setAttribute('aria-selected', String(reviewTab === 'draft'));
  $('review-state').textContent = reviewTab === 'draft' ? `${s.draft.length + 1} 条规则` : t ? STATUS[t.status] : '尚无候选';
  if (reviewTab === 'draft') {
    $('review-content').innerHTML = reviewDraftHTML();
    $('review-actions').innerHTML = `<small>导出完整配置副本，原文件不会被覆盖。</small><div class="action-group"><button class="secondary" data-open-export ${s.busy ? 'disabled' : ''}>导出副本</button></div>`;
    return;
  }
  if (!t?.changes.length) {
    $('review-content').innerHTML = '<p>发送一条分流指令后，在这里审阅出口与 YAML 差异。</p>';
    $('review-actions').innerHTML = '';
    return;
  }
  $('review-content').innerHTML = reviewChangesHTML(t);
  $('review-content').querySelectorAll('[data-disclosure]').forEach(el => {
    el.open = disclosures.get(el.dataset.disclosure) ?? false;
    el.ontoggle = () => disclosures.set(el.dataset.disclosure, el.open);
  });
  $('copy-diff').onclick = async () => {
    try { await navigator.clipboard.writeText(diffRules(t.before, t.after).map(l => (l.kind === 'add' ? '+' : l.kind === 'remove' ? '-' : ' ') + l.text).join('\n')); toast('已复制差异。'); }
    catch { toast('无法访问剪贴板，可在 Diff 中选择文本复制。'); }
  };
  let note = '', actions = '';
  if (t.status === 'pending') {
    note = '确认后写入草稿，不会应用到代理。';
    actions = `<button id="discard" class="secondary" ${s.busy ? 'disabled' : ''}>放弃</button><button id="confirm" class="primary" ${s.busy ? 'disabled' : ''}>确认到草稿</button>`;
  } else if (t.status === 'blocked') {
    note = '校验失败的候选不能确认。请调整指令后重新生成。';
    actions = '<button class="primary" disabled>确认到草稿</button>';
  } else if (t.status === 'confirmed') {
    note = canUndo(s, t.id) ? '已写入草稿 · 未应用代理' : '只能撤销最近一次确认。';
    actions = `<button id="undo" class="secondary" ${canUndo(s, t.id) ? '' : 'disabled'}>撤销此修改</button>`;
  } else {
    note = `${STATUS[t.status]} · 只读`;
  }
  $('review-actions').innerHTML = `<small>${escape(note)}</small><div class="action-group">${actions}</div>`;
  if ($('confirm')) $('confirm').onclick = () => { if (confirmTurn(s, t.id)) { render(); toast('已确认到草稿，尚未应用到代理。'); } };
  if ($('discard')) $('discard').onclick = () => { if (discardTurn(s, t.id)) { render(); toast('已放弃候选，草稿不变。'); } };
  if ($('undo')) $('undo').onclick = () => { if (undoTurn(s, t.id)) { render(); toast('已撤销草稿修改。'); } };
}

function renderService() {
  const banner = $('service-banner');
  banner.className = `service-banner${s.service === 'unavailable' ? ' down' : ''}`;
  banner.hidden = s.service === 'ready';
  banner.setAttribute('role', s.service === 'unavailable' ? 'alert' : 'status');
  banner.innerHTML = s.service === 'starting'
    ? '<span class="spinner" aria-hidden="true"></span>正在启动内置编辑服务…'
    : `${icon('alert')}<span>内置编辑服务已停止。草稿仍在内存中，未丢失。</span><button id="restart">重新启动服务</button>`;
  if ($('restart')) $('restart').onclick = () => { $('scenario').value = 'normal'; startService(); };
}

function render() {
  const timeline = $('timeline');
  const doc = s.doc;
  const unsaved = hasUnsavedChanges(s);
  const unknown = doc ? unknownRegions(s).length : 0;

  $('file-title').textContent = doc?.name ?? 'AI 工作台';
  $('file-title').title = doc?.name ?? '';
  $('file-status').innerHTML = doc
    ? `<span>${s.draft.length + 1} 条规则 · 未应用代理</span>${unsaved ? '<span class="unsaved">未导出</span>' : ''}`
    : '<span>仅编辑规则 · 不控制代理</span>';
  $('sidebar-file').innerHTML = doc
    ? `${escape(doc.name)}<small>${doc.source === 'url' ? '订阅' : '文件'} · ${doc.counts.nodes} 节点 · ${doc.groups.length} 策略组</small>`
    : '尚未导入';
  $('draft-nav').disabled = $('regions-nav').disabled = !doc;
  $('regions-badge').hidden = !unknown;
  $('regions-badge').textContent = unknown ? String(unknown) : '';
  $('regions-badge').setAttribute('aria-label', `${unknown} 个出口未指定地区`);
  $('ai-nav-state').textContent = { none: '未设置', session: '会话', saved: '已保存' }[s.key];

  renderService();
  $('landing').hidden = !!doc;
  const ready = s.service === 'ready' && !!doc;
  $('prompt').disabled = !ready || !!s.busy;
  $('prompt').placeholder = !doc ? '导入配置以开始' : s.service !== 'ready' ? '等待编辑服务…' : '描述你想修改的分流规则…（⌘↩ 发送）';
  document.querySelectorAll('input[name=mode]').forEach(el => { el.disabled = !ready || !!s.busy; el.checked = el.value === s.mode; });
  $('key-hint').hidden = !(doc && s.mode === 'ai' && s.key === 'none');
  $('send').innerHTML = icon(s.busy ? 'stop' : 'up');
  $('send').type = s.busy ? 'button' : 'submit';
  $('send').setAttribute('aria-label', s.busy ? '取消处理' : '发送指令');
  $('send').disabled = !s.busy && (!canSend(s) || !$('prompt').value.trim());
  $('work-status').textContent = s.busy ? '处理中…' : '';
  $('export').disabled = !doc || !!s.busy;
  $('review-toggle').disabled = !doc;
  $('review-toggle').setAttribute('aria-expanded', String(reviewOpen));
  $('review-toggle').setAttribute('aria-label', reviewOpen ? '关闭修改审阅' : '打开修改审阅');

  $('messages').innerHTML = !doc ? '' : s.turns.length ? s.turns.map(turnHTML).join('') : startHTML();
  $('review').hidden = !reviewOpen;
  document.body.classList.toggle('review-open', reviewOpen);
  renderReview();
  bindDynamic();

  if (timeline.getClientRects().length && following) timeline.scrollTop = timeline.scrollHeight;
  updateLatest();
}

function bindDynamic() {
  document.querySelectorAll('[data-review]').forEach(el => { el.onclick = () => { s.selected = Number(el.dataset.review); reviewTab = 'changes'; reviewOpen = true; render(); }; });
  document.querySelectorAll('[data-prompt]').forEach(el => { el.onclick = () => { $('prompt').value = el.dataset.prompt; render(); $('prompt').focus(); }; });
  document.querySelectorAll('[data-steps]').forEach(el => { el.ontoggle = () => { const t = s.turns.find(x => x.id === Number(el.dataset.steps)); if (t) t.open = el.open; }; });
  document.querySelectorAll('[data-retry]').forEach(el => { el.onclick = () => { const t = s.turns.find(x => x.id === Number(el.dataset.retry)); if (t && !s.busy) { $('prompt').value = t.prompt; send(); } }; });
  document.querySelectorAll('[data-region]').forEach(el => { el.onchange = () => changeRegion(el.dataset.region, el.value); });
  document.querySelectorAll('[data-open-export]').forEach(el => { el.onclick = openExport; });
}

function changeRegion(name, region) {
  const hadPending = s.turns.some(t => t.status === 'pending');
  if (!setRegion(s, name, region)) return;
  render();
  if ($('regions-dialog').open) { $('regions-content').innerHTML = regionEditor(); bindDynamic(); }
  toast(`已将“${name}”设为${REGIONS[region]}。${hadPending ? '未确认的候选已失效，请重新生成。' : ''}`);
}

function updateLatest() {
  const t = $('timeline');
  $('latest').hidden = !s.turns.length || !t.getClientRects().length || t.scrollHeight - t.clientHeight - t.scrollTop < 32;
}

/* ---------- actions ---------- */
function send() {
  const turn = startTurn(s, $('prompt').value);
  if (!turn) return;
  const run = scenario();
  $('prompt').value = '';
  following = true;
  render();
  later(700, () => { if (s.busy === turn.id) { turn.steps.push(turn.mode === 'ai' ? '等待 AI 返回结构化计划…' : '正在生成规则候选…'); render(); } });
  later(1600, () => {
    completeTurn(s, turn.id, run);
    if (turn.status === 'pending' || turn.status === 'blocked') { reviewTab = 'changes'; reviewOpen = following && innerWidth >= 1200; }
    render();
    if (turn.status === 'failed') toast('处理未完成，详情保留在对话中。');
  });
}

function cancel() {
  clearTimers();
  cancelTurn(s);
  render();
  toast('已取消，草稿未改变。');
}

function openImport() {
  if (s.busy) { toast('请先取消当前处理，再导入配置。'); return; }
  $('import-dialog').showModal();
}

function load(source) {
  if (hasUnsavedChanges(s) && !confirm('重新导入将替换当前草稿与撤销记录，未导出的修改会丢失。继续？')) return;
  clearTimers();
  disclosures.clear();
  importDocument(s, $('long-sample').checked ? 'long' : 'normal', source);
  reviewOpen = false; reviewTab = 'changes'; following = true;
  $('prompt').value = '';
  $('import-dialog').close();
  if (scenario() === 'service-down') s.service = 'unavailable';
  render();
  toast(unknownRegions(s).length ? '示例已载入。请先确认未指定地区的出口。' : '示例已载入，可开始对话。');
  $('prompt').focus();
}

function openExport() {
  if (!s.doc || s.busy) return;
  const lines = diffRules(s.exported, s.draft);
  const st = diffStats(lines);
  $('export-content').innerHTML = `<p>导出包含修改后 rules 的完整配置副本。节点、Provider、DNS 等字段保持原样，原文件 <strong>${escape(s.doc.name)}</strong> 不会被覆盖。</p>
    <div class="stat-row"><span class="plus">+${st.add} 条</span><span class="minus">−${st.remove} 条</span><span>相对上次导出</span></div>
    ${st.add + st.remove ? '' : '<p>草稿与上次导出相同；仍可再次导出。</p>'}
    <p>导出后请由代理客户端加载并校验。Veer 编辑器不启动或控制代理。</p>`;
  $('export-dialog').showModal();
}

$('export-confirm').onclick = () => {
  const name = s.doc.name.replace(/\.ya?ml$/i, '') + '-edited.yaml';
  const url = URL.createObjectURL(new Blob([`# 合成演示副本；不含真实节点，不能作为可用代理配置\n${toYaml(s.draft)}`], { type: 'text/yaml' }));
  const link = Object.assign(document.createElement('a'), { href: url, download: name });
  link.click();
  setTimeout(() => URL.revokeObjectURL(url), 1000);
  markExported(s);
  $('export-dialog').close();
  render();
  toast(`已导出 ${name}；原文件未覆盖。`);
};

/* ---------- wiring ---------- */
$('composer').onsubmit = e => { e.preventDefault(); if (!s.busy) send(); };
$('send').onclick = e => { if (s.busy) { e.preventDefault(); cancel(); } };
$('prompt').oninput = () => { $('send').disabled = !s.busy && (!canSend(s) || !$('prompt').value.trim()); };
$('prompt').onkeydown = e => { if ((e.metaKey || e.ctrlKey) && e.key === 'Enter') { e.preventDefault(); send(); } };
document.querySelectorAll('input[name=mode]').forEach(el => { el.onchange = () => { s.mode = el.value; render(); }; });
$('key-hint').onclick = () => openAiSettings();

$('import').onclick = openImport;
$('landing-import').onclick = openImport;
$('sample-file').onclick = () => load('file');
$('sample-url').onclick = () => load('url');
$('export').onclick = openExport;
$('review-toggle').onclick = () => { reviewOpen = !reviewOpen; render(); };
$('review-close').onclick = () => { reviewOpen = false; render(); $('prompt').focus(); };
$('tab-changes').onclick = () => { reviewTab = 'changes'; render(); };
$('tab-draft').onclick = () => { reviewTab = 'draft'; render(); };
document.querySelector('.tabs').addEventListener('keydown', e => {
  if (!['ArrowLeft', 'ArrowRight'].includes(e.key)) return;
  reviewTab = reviewTab === 'changes' ? 'draft' : 'changes';
  render();
  $(reviewTab === 'changes' ? 'tab-changes' : 'tab-draft').focus();
});
$('workbench').onclick = () => { reviewOpen = false; render(); };
$('draft-nav').onclick = () => { reviewTab = 'draft'; reviewOpen = true; render(); };
$('regions-nav').onclick = openRegions;
$('ai-nav').onclick = () => openAiSettings();

function openRegions() {
  if (!s.doc) return;
  $('regions-content').innerHTML = regionEditor();
  bindDynamic();
  $('regions-dialog').showModal();
}

function openAiSettings() {
  document.querySelectorAll('input[name=key]').forEach(el => { el.checked = el.value === s.key; });
  $('ai-dialog').showModal();
}
document.querySelectorAll('input[name=key]').forEach(el => {
  el.onchange = () => { s.key = el.value; render(); toast({ none: '已移除 Key。AI 理解不可用。', session: '已使用会话 Key（演示）；退出后清除。', saved: '已保存到钥匙串（演示）。' }[s.key]); };
});

document.querySelectorAll('[data-close]').forEach(el => { el.onclick = () => el.closest('dialog').close(); });
$('toast-close').onclick = () => { $('toast').hidden = true; clearTimeout(toastTimer); };

$('scenario').onchange = () => {
  if (scenario() === 'service-down') {
    if (s.busy) cancelTurn(s);
    clearTimers();
    s.service = 'unavailable';
    render();
  }
};
$('reset').onclick = () => {
  if (hasUnsavedChanges(s) && !confirm('清除本轮内容并回到首页？未导出的修改会丢失。')) return;
  clearTimers(); disclosures.clear();
  Object.assign(s, initialState(), { key: s.key });
  reviewOpen = false; following = true; $('prompt').value = '';
  startService();
};

$('mobile-menu').onclick = () => {
  $('info-title').textContent = '配置菜单';
  $('info-content').innerHTML = `<div class="region-list">
    <button class="nav-item" data-nav="draft-nav" ${s.doc ? '' : 'disabled'}>${icon('file')}规则稿</button>
    <button class="nav-item" data-nav="regions-nav" ${s.doc ? '' : 'disabled'}>${icon('globe')}出口地区</button>
    <button class="nav-item" data-nav="ai-nav">${icon('key')}AI 设置</button></div>`;
  $('info-content').querySelectorAll('[data-nav]').forEach(el => { el.onclick = () => { $('info-dialog').close(); $(el.dataset.nav).click(); }; });
  $('info-dialog').showModal();
};

const timeline = $('timeline');
timeline.addEventListener('wheel', () => { following = false; }, { passive: true });
timeline.addEventListener('touchstart', () => { following = false; }, { passive: true });
timeline.addEventListener('keydown', e => { if (['Home', 'End', 'PageUp', 'PageDown', 'ArrowUp', 'ArrowDown'].includes(e.key)) following = false; });
timeline.addEventListener('scroll', () => { if (timeline.scrollHeight - timeline.clientHeight - timeline.scrollTop < 32) following = true; updateLatest(); }, { passive: true });
$('latest').onclick = () => { following = true; timeline.scrollTop = timeline.scrollHeight; updateLatest(); };

document.addEventListener('keydown', e => {
  if ((e.metaKey || e.ctrlKey) && e.key.toLowerCase() === 'o' && !document.querySelector('dialog[open]')) { e.preventDefault(); openImport(); }
});

let dark = matchMedia('(prefers-color-scheme: dark)').matches;
function applyTheme() {
  document.documentElement.dataset.theme = dark ? 'dark' : 'light';
  $('theme').innerHTML = icon(dark ? 'sun' : 'moon');
  $('theme').setAttribute('aria-label', dark ? '切换浅色外观' : '切换深色外观');
}
$('theme').onclick = () => { dark = !dark; applyTheme(); };
applyTheme();
startService();
