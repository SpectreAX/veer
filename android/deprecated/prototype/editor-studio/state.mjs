// Pure, synthetic state for the Veer Editor Studio redesign. No I/O: the page
// never reads files, downloads subscriptions, calls AI or touches a keychain.

export const SERVICES = {
  Netflix: ['netflix.com', 'netflix.net', 'nflxvideo.net', 'nflximg.net', 'nflxso.net', 'nflxext.com'],
  ChatGPT: ['chatgpt.com', 'openai.com', 'oaistatic.com', 'oaiusercontent.com'],
  YouTube: ['youtube.com', 'youtu.be', 'googlevideo.com', 'ytimg.com'],
  Telegram: ['telegram.org', 't.me', 'telegram.me'],
};

export const REGIONS = { JP: '日本', US: '美国', HK: '香港', SG: '新加坡', TW: '台湾', UNKNOWN: '未指定地区' };
const REGION_WORDS = { JP: /日本|日区|\bjp\b|japan/i, US: /美国|美区|\bus\b|\busa\b|america/i, HK: /香港|港区|\bhk\b|hong\s*kong/i, SG: /新加坡|\bsg\b|singapore/i, TW: /台湾|台区|\btw\b|taiwan/i };
export const BUILTIN = ['DIRECT', 'REJECT'];

export const SAMPLES = {
  normal: {
    name: 'veer-demo.yaml',
    groups: [
      { name: '🇯🇵 日本 自动', region: 'JP' },
      { name: '🇺🇸 美国 流媒体', region: 'US' },
      { name: '香港 IPLC', region: 'HK' },
      { name: 'Auto 优选', region: 'UNKNOWN' },
    ],
    rules: ['DOMAIN-SUFFIX,Netflix.com,香港 IPLC', 'DOMAIN-KEYWORD,openai,🇺🇸 美国 流媒体', 'GEOSITE,cn,DIRECT', 'GEOIP,CN,DIRECT,no-resolve'],
    counts: { nodes: 42, providers: 2 },
  },
  long: {
    name: 'veer-demo-跨服务规则分流与超长出口名称审阅演示配置-for-narrow-window-testing.yaml',
    groups: [
      { name: '🇯🇵 日本 东京 IPLC 专线 流媒体解锁 自动选择 Premium-Streaming-Group-01', region: 'JP' },
      { name: '🇺🇸 United States Los Angeles Residential Streaming Selector', region: 'US' },
      { name: '香港 HKT 家宽 低倍率 备用线路 Backup-Line-With-Very-Long-Name', region: 'HK' },
      { name: 'Auto-Fallback-Global-Selector-Without-Region-Label', region: 'UNKNOWN' },
    ],
    rules: ['GEOSITE,cn,DIRECT', 'GEOIP,CN,DIRECT,no-resolve'],
    counts: { nodes: 318, providers: 6 },
  },
};

/* ---------- app and sessions ---------- */

export const initialApp = () => ({ service: 'ready', mode: 'local', key: 'none', sessions: [], activeId: null });

let seq = 0;
const newId = () => `s${Date.now().toString(36)}${(seq++).toString(36)}`;

export function createSession(app, sample = 'normal', source = 'file') {
  const doc = structuredClone(SAMPLES[sample]);
  const session = {
    id: newId(), doc: { ...doc, source }, draft: [...doc.rules], exported: [...doc.rules],
    snapshots: [], turns: [], busy: null, selected: null, updatedAt: Date.now(),
  };
  app.sessions.unshift(session);
  app.activeId = session.id;
  return session;
}

export const activeSession = app => app.sessions.find(s => s.id === app.activeId) ?? null;
export const anyBusy = app => app.sessions.some(s => s.busy);

export function switchSession(app, id) {
  if (anyBusy(app) || !app.sessions.some(s => s.id === id)) return false;
  app.activeId = id;
  return true;
}

export function deleteSession(app, id) {
  const session = app.sessions.find(s => s.id === id);
  if (!session || session.busy) return false;
  app.sessions = app.sessions.filter(s => s.id !== id);
  if (app.activeId === id) app.activeId = app.sessions[0]?.id ?? null;
  return true;
}

export function filterSessions(app, query) {
  const q = query.trim().toLowerCase();
  if (!q) return app.sessions;
  return app.sessions.filter(s => s.doc.name.toLowerCase().includes(q) || s.turns.some(t => t.prompt.toLowerCase().includes(q)));
}

const touch = s => { s.updatedAt = Date.now(); };
export const unknownRegions = s => (s?.doc.groups ?? []).filter(g => g.region === 'UNKNOWN');
export const hasUnsavedChanges = s => !!s && s.draft.join('\n') !== s.exported.join('\n');
const supersedePending = s => s.turns.forEach(t => { if (t.status === 'pending') t.status = 'superseded'; });

export function setRegion(s, name, region) {
  const group = s?.doc.groups.find(g => g.name === name);
  if (!group || s.busy || !Object.hasOwn(REGIONS, region) || group.region === region) return false;
  group.region = region;
  supersedePending(s);
  touch(s);
  return true;
}

/* ---------- persistence (prototype: per-browser localStorage) ---------- */

export function serialize(app) {
  return JSON.stringify({ v: 1, mode: app.mode, key: app.key === 'saved' ? 'saved' : 'none', activeId: app.activeId, sessions: app.sessions });
}

export function restore(text) {
  const app = initialApp();
  try {
    const data = JSON.parse(text);
    if (data?.v !== 1 || !Array.isArray(data.sessions)) return app;
    app.mode = data.mode === 'ai' ? 'ai' : 'local';
    // A session key lives in memory only; it never survives a relaunch.
    app.key = data.key === 'saved' ? 'saved' : 'none';
    app.sessions = data.sessions.map(s => ({
      ...s, busy: null,
      turns: s.turns.map(t => t.status === 'running' ? { ...t, status: 'cancelled', steps: [...t.steps, '应用重新打开，此请求未完成。'] } : t),
    }));
    app.activeId = app.sessions.some(s => s.id === data.activeId) ? data.activeId : app.sessions[0]?.id ?? null;
  } catch { /* Corrupt or missing storage starts empty. */ }
  return app;
}

/* ---------- composer: / commands and @ mentions ---------- */

export const COMMANDS = [
  { id: 'route', label: '路由', hint: '服务 走 出口', insert: '走 ' },
  { id: 'direct', label: '直连', hint: '不经代理', insert: '直连' },
  { id: 'block', label: '屏蔽', hint: '拒绝连接', insert: '屏蔽' },
  { id: 'remove', label: '删除', hint: '移除已有规则', insert: '删除 ' },
  { id: 'check', label: '检查', hint: '在检查器中测试域名', action: 'check' },
];

export function mentionItems(s) {
  const services = Object.keys(SERVICES).map(name => ({ kind: 'service', label: name, hint: `${SERVICES[name].length} 个域名`, insert: name }));
  const exits = (s?.doc.groups ?? []).map(g => ({ kind: 'exit', label: g.name, hint: REGIONS[g.region], insert: g.name }));
  const builtins = BUILTIN.map(name => ({ kind: 'exit', label: name, hint: name === 'DIRECT' ? '直连' : '屏蔽', insert: name }));
  return [...services, ...exits, ...builtins];
}

// The trigger token immediately before the caret, e.g. "@日" or "/".
export function triggerAt(text, caret) {
  const match = text.slice(0, caret).match(/(^|\s)([/@])([^\s/@]*)$/);
  if (!match) return null;
  return { char: match[2], query: match[3], start: caret - match[3].length - 1, end: caret };
}

export function menuItems(s, trigger) {
  if (!trigger) return [];
  const q = trigger.query.toLowerCase();
  const items = trigger.char === '/' ? COMMANDS.map(c => ({ ...c, kind: 'command' })) : mentionItems(s);
  return items.filter(item => item.label.toLowerCase().includes(q) || (item.hint ?? '').toLowerCase().includes(q)).slice(0, 8);
}

export function applyMenuItem(text, trigger, item) {
  const insert = item.insert ?? '';
  const before = text.slice(0, trigger.start);
  const after = text.slice(trigger.end);
  const spaced = insert && !insert.endsWith(' ') ? `${insert} ` : insert;
  return { text: before + spaced + after, caret: before.length + spaced.length };
}

/* ---------- parsing and candidates ---------- */

export const canSend = (app, s) => app.service === 'ready' && !!s && !s.busy && (app.mode === 'local' || app.key !== 'none');

// Local and simulated-AI parsing share one grammar. AI mode turns refusals into
// a clarification question instead of an error, like the real service.
export function parsePrompt(prompt, groups, mode) {
  const ask = (local, ai, suggestions = []) => mode === 'ai' ? { clarification: ai, suggestions } : { error: local };
  const ops = [];
  const names = [...groups.map(g => g.name), ...BUILTIN].sort((a, b) => b.length - a.length);
  for (const raw of prompt.split(/[\n;；，,]|\s+and\s+|同时|并且/i).map(c => c.trim()).filter(Boolean)) {
    // Mentions are plain text; a leading @ is only a completion aid.
    let clause = raw.replace(/@/g, '');
    let explicit = null;
    for (const name of names) if (clause.includes(name)) { explicit = name; clause = clause.split(name).join(' '); break; }
    if (/延迟|太卡|最快|测速|latency|slow|fastest/i.test(clause)) {
      return ask('离线编辑器没有实时延迟数据，无法判断哪个出口更快。请指定出口或地区。', '我无法测速，也不会判断哪个出口更快。你想把哪项服务固定到哪个出口？', ['Netflix 走日本', 'ChatGPT 走美国']);
    }
    if (/不要|不走|别走|别用|除了|except|don't/i.test(clause)) {
      return ask('本地解析不支持否定或例外条件。请改用明确的正向指令，或切换到 AI 理解。', '“不走某个出口”没有说明应改走哪里。请告诉我替代出口。', ['Netflix 走美国', 'Netflix 直连']);
    }
    const services = Object.keys(SERVICES).filter(name => clause.toLowerCase().includes(name.toLowerCase()));
    const domains = (clause.match(/\b(?:[a-z0-9-]+\.)+[a-z]{2,}\b/gi) ?? []).map(d => d.toLowerCase());
    const seen = new Set();
    const items = [...services.map(name => ({ label: name, domains: SERVICES[name] })), ...domains.map(d => ({ label: d, domains: [d] }))]
      .map(item => ({ ...item, domains: item.domains.filter(d => !seen.has(d) && seen.add(d)) }))
      .filter(item => item.domains.length);
    if (!items.length) return ask('本地解析只支持 Netflix、ChatGPT、YouTube、Telegram 和明确域名。', '我没有识别到具体服务或域名。你想调整哪项服务？', ['YouTube 走香港', 'Telegram 走新加坡']);
    let action, target;
    if (/删除|移除|remove|delete/i.test(clause)) action = 'remove';
    else if (explicit) { action = 'route'; target = explicit; }
    else if (/直连|\bdirect\b/i.test(clause)) { action = 'route'; target = 'DIRECT'; }
    else if (/屏蔽|拒绝|阻止|\bblock\b|\breject\b/i.test(clause)) { action = 'route'; target = 'REJECT'; }
    else {
      const regions = Object.entries(REGION_WORDS).filter(([, re]) => re.test(clause)).map(([code]) => code);
      if (regions.length !== 1) return ask('请明确一个出口，例如“Netflix 走日本”，或用 @ 选择出口。', `请只选一个出口作为 ${items[0].label} 的目标。`, [`${items[0].label} 走日本`, `${items[0].label} 走美国`]);
      const pool = groups.filter(g => g.region === regions[0]);
      if (pool.length !== 1) {
        return { error: pool.length ? `有多个${REGIONS[regions[0]]}出口：${pool.map(g => g.name).join('、')}。请用 @ 选择完整名称。` : `当前配置没有登记为${REGIONS[regions[0]]}的出口。可在开始页或“出口地区”中更正未指定地区的组。` };
      }
      action = 'route'; target = pool[0].name;
    }
    for (const item of items) ops.push({ action, label: item.label, domains: item.domains, target });
  }
  return { ops };
}

const ruleKey = rule => rule.split(',').slice(0, 2).join(',').toLowerCase();

export function applyOps(draft, ops) {
  let after = [...draft];
  const added = [];
  const changes = ops.map(op => {
    const keys = new Set(op.domains.map(d => `domain-suffix,${d}`));
    const before = after.filter(rule => keys.has(ruleKey(rule)));
    after = after.filter(rule => !keys.has(ruleKey(rule)));
    const rules = op.action === 'route' ? op.domains.map(d => `DOMAIN-SUFFIX,${d},${op.target}`) : [];
    added.push(...rules);
    return { ...op, before, after: rules };
  });
  return { after: [...added, ...after], changes };
}

export const VALIDATION = {
  passed: { status: 'passed', message: '已通过 Mihomo 占位出口测试。仅覆盖修改的规则，不验证网络可达或服务解锁。' },
  failed: { status: 'failed', message: 'Mihomo 校验失败：rules[0] 引用的出口在占位配置中不存在。此候选不能写入。' },
  unavailable: { status: 'unavailable', message: '规则结构检查通过；内置校验器不可用，尚未经过 Mihomo 语义测试。' },
};

export function startTurn(app, s, prompt) {
  const text = prompt.trim();
  if (!text || !canSend(app, s)) return null;
  supersedePending(s);
  const turn = {
    id: s.turns.length + 1, prompt: text, mode: app.mode, status: 'running', changes: [], open: true,
    steps: [app.mode === 'ai'
      ? `已匿名化上下文：${s.doc.groups.length} 个出口编号与地区标签；节点、组名与密钥不发送。`
      : '已在本机解析指令；不访问网络。'],
  };
  s.turns.push(turn);
  s.busy = turn.id;
  touch(s);
  return turn;
}

export function completeTurn(s, id, scenario = 'normal') {
  const t = s.turns.find(turn => turn.id === id);
  if (!t || s.busy !== id || t.status !== 'running') return;
  s.busy = null;
  t.open = false;
  touch(s);
  if (scenario === 'request-failed') {
    t.status = 'failed';
    t.error = t.mode === 'ai' ? 'AI 服务返回 HTTP 429，请检查额度后重试。草稿没有变化。' : '本机编辑服务没有响应，请重试。草稿没有变化。';
    return;
  }
  const parsed = parsePrompt(t.prompt, s.doc.groups, t.mode);
  if (parsed.error) { t.status = 'failed'; t.error = parsed.error; return; }
  if (parsed.clarification) {
    t.status = 'clarify'; t.question = parsed.clarification; t.suggestions = parsed.suggestions;
    t.steps.push('AI 请求澄清；没有生成候选。');
    return;
  }
  const { after, changes } = applyOps(s.draft, parsed.ops);
  t.ops = parsed.ops;
  t.base = [...s.draft];
  t.changes = changes.map(c => ({ ...c, decision: 'accepted' }));
  t.validation = VALIDATION[scenario === 'validation-failed' ? 'failed' : scenario === 'validator-unavailable' ? 'unavailable' : 'passed'];
  t.steps.push(`已生成 ${changes.length} 项修改。`, `校验：${t.validation.message}`);
  if (after.join('\n') === s.draft.join('\n')) t.status = 'unchanged';
  else t.status = t.validation.status === 'failed' ? 'blocked' : 'pending';
  s.selected = id;
}

/* ---------- per-change approval ---------- */

export function setDecision(s, id, index, decision) {
  const t = s.turns.find(turn => turn.id === id);
  if (s.busy || !t || t.status !== 'pending' || !t.changes[index] || !['accepted', 'rejected'].includes(decision)) return false;
  t.changes[index].decision = decision;
  return true;
}

export const acceptedCount = t => t.changes.filter(c => c.decision === 'accepted').length;

// The rules this turn would produce from only the accepted changes.
export function candidateRules(t) {
  if (!t.base) return [];
  return applyOps(t.base, t.ops.filter((_, i) => ['accepted', 'applied'].includes(t.changes[i].decision))).after;
}

export function applyTurn(s, id) {
  const t = s.turns.find(turn => turn.id === id);
  if (s.busy || !t || t.status !== 'pending' || !acceptedCount(t)) return false;
  if (t.base.join('\n') !== s.draft.join('\n')) { t.status = 'superseded'; return false; }
  s.snapshots.push({ id, draft: [...s.draft] });
  s.draft = candidateRules(t);
  t.status = 'confirmed';
  t.changes.forEach(c => { c.decision = c.decision === 'accepted' ? 'applied' : 'rejected'; });
  touch(s);
  return true;
}

export function rejectTurn(s, id) {
  const t = s.turns.find(turn => turn.id === id);
  if (s.busy || !t || t.status !== 'pending') return false;
  t.status = 'discarded';
  t.changes.forEach(c => { c.decision = 'rejected'; });
  touch(s);
  return true;
}

export function cancelTurn(s) {
  const t = s.turns.find(turn => turn.id === s.busy);
  if (t) { t.status = 'cancelled'; t.open = false; t.steps.push('已取消，草稿未改变。'); }
  s.busy = null;
}

export function undoTurn(s, id) {
  const top = s.snapshots.at(-1);
  if (s.busy || !top || top.id !== id) return false;
  s.draft = s.snapshots.pop().draft;
  const t = s.turns.find(turn => turn.id === id);
  t.status = 'undone';
  t.changes.forEach(c => { if (c.decision === 'applied') c.decision = 'accepted'; });
  supersedePending(s);
  touch(s);
  return true;
}

export const canUndo = (s, id) => !s.busy && s.snapshots.at(-1)?.id === id;

/* ---------- inspector ---------- */

// Line diff over rule arrays (LCS). Rules are short lists, so O(n·m) is fine.
export function diffRules(before, after) {
  const n = before.length, m = after.length;
  const lcs = Array.from({ length: n + 1 }, () => new Array(m + 1).fill(0));
  for (let i = n - 1; i >= 0; i--) for (let j = m - 1; j >= 0; j--) {
    lcs[i][j] = before[i] === after[j] ? lcs[i + 1][j + 1] + 1 : Math.max(lcs[i + 1][j], lcs[i][j + 1]);
  }
  const lines = [{ kind: 'same', text: 'rules:' }];
  let i = 0, j = 0;
  while (i < n || j < m) {
    if (i < n && j < m && before[i] === after[j]) { lines.push({ kind: 'same', text: `  - ${before[i]}` }); i++; j++; }
    else if (j < m && (i === n || lcs[i][j + 1] >= lcs[i + 1][j])) lines.push({ kind: 'add', text: `  - ${after[j++]}` });
    else lines.push({ kind: 'remove', text: `  - ${before[i++]}` });
  }
  lines.push({ kind: 'same', text: '  - MATCH,DIRECT' });
  return lines;
}

export const diffStats = lines => ({ add: lines.filter(l => l.kind === 'add').length, remove: lines.filter(l => l.kind === 'remove').length });
export const toYaml = rules => `rules:\n${[...rules, 'MATCH,DIRECT'].map(r => `  - ${r}`).join('\n')}\n`;
export function markExported(s) { s.exported = [...s.draft]; touch(s); }

export function searchRules(rules, query) {
  const q = query.trim().toLowerCase();
  return [...rules, 'MATCH,DIRECT'].map((rule, index) => ({ index: index + 1, rule })).filter(r => !q || r.rule.toLowerCase().includes(q));
}

// First rule a domain hits, in order. GEOSITE and IP rules need core data or
// DNS, so they are reported as skipped instead of guessed.
export function matchDomain(rules, input) {
  const domain = input.trim().toLowerCase().replace(/^https?:\/\//, '').replace(/[/:?#].*$/, '');
  if (!/^(?:[a-z0-9-]+\.)+[a-z]{2,}$/.test(domain)) return { error: '请输入有效域名，例如 www.netflix.com。' };
  const skipped = [];
  const all = [...rules, 'MATCH,DIRECT'];
  for (const [index, rule] of all.entries()) {
    const [type, value = '', target] = rule.split(',');
    const v = value.toLowerCase();
    const hit = type === 'DOMAIN' ? domain === v
      : type === 'DOMAIN-SUFFIX' ? domain === v || domain.endsWith(`.${v}`)
      : type === 'DOMAIN-KEYWORD' ? domain.includes(v)
      : type === 'MATCH';
    if (['GEOSITE', 'GEOIP', 'IP-CIDR', 'IP-CIDR6'].includes(type)) { skipped.push({ index: index + 1, rule }); continue; }
    if (hit) return { domain, index: index + 1, rule, target: type === 'MATCH' ? value : target, skipped };
  }
  return { domain, skipped };
}
