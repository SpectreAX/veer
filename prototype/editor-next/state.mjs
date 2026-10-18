// Pure, synthetic state for the next macOS editor iteration. No I/O: the page
// never reads files, downloads subscriptions, calls AI or touches a keychain.

export const SERVICES = {
  Netflix: ['netflix.com', 'netflix.net', 'nflxvideo.net', 'nflximg.net', 'nflxso.net', 'nflxext.com'],
  ChatGPT: ['chatgpt.com', 'openai.com', 'oaistatic.com', 'oaiusercontent.com'],
  YouTube: ['youtube.com', 'youtu.be', 'googlevideo.com', 'ytimg.com'],
  Telegram: ['telegram.org', 't.me', 'telegram.me'],
};

export const REGIONS = { JP: '日本', US: '美国', HK: '香港', SG: '新加坡', TW: '台湾', UNKNOWN: '未指定地区' };

const REGION_WORDS = { JP: /日本|日区|\bjp\b|japan/i, US: /美国|美区|\bus\b|\busa\b|america/i, HK: /香港|港区|\bhk\b|hong\s*kong/i, SG: /新加坡|\bsg\b|singapore/i, TW: /台湾|台区|\btw\b|taiwan/i };

export const SAMPLES = {
  normal: {
    name: 'veer-demo.yaml',
    groups: [
      { name: '🇯🇵 日本 自动', region: 'JP' },
      { name: '🇺🇸 美国 流媒体', region: 'US' },
      { name: '香港 IPLC', region: 'HK' },
      { name: 'Auto 优选', region: 'UNKNOWN' },
    ],
    rules: ['DOMAIN-SUFFIX,Netflix.com,香港 IPLC', 'GEOSITE,cn,DIRECT', 'GEOIP,CN,DIRECT,no-resolve'],
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

export const initialState = () => ({
  service: 'ready', // starting | ready | unavailable
  doc: null,
  draft: [],
  exported: [],
  snapshots: [],
  turns: [],
  busy: null,
  selected: null,
  mode: 'local', // local | ai
  key: 'none', // none | session | saved
});

const clone = value => structuredClone(value);
const supersedePending = s => s.turns.forEach(t => { if (t.status === 'pending') t.status = 'superseded'; });

export function importDocument(s, sample = 'normal', source = 'file') {
  const doc = clone(SAMPLES[sample]);
  Object.assign(s, { doc: { ...doc, source }, draft: [...doc.rules], exported: [...doc.rules], snapshots: [], turns: [], busy: null, selected: null });
}

export const unknownRegions = s => (s.doc?.groups ?? []).filter(g => g.region === 'UNKNOWN');
export const hasUnsavedChanges = s => !!s.doc && s.draft.join('\n') !== s.exported.join('\n');

export function setRegion(s, name, region) {
  const group = s.doc?.groups.find(g => g.name === name);
  if (!group || s.busy || !Object.hasOwn(REGIONS, region) || group.region === region) return false;
  group.region = region;
  // A candidate was generated against the old labels; keep it readable but not confirmable.
  supersedePending(s);
  return true;
}

export const canSend = s => s.service === 'ready' && !!s.doc && !s.busy && (s.mode === 'local' || s.key !== 'none');

export function startTurn(s, prompt) {
  const text = prompt.trim();
  if (!text || !canSend(s)) return null;
  supersedePending(s);
  const anonymous = s.doc.groups.length;
  const turn = {
    id: s.turns.length + 1, prompt: text, mode: s.mode, status: 'running', changes: [], open: false,
    steps: [s.mode === 'ai'
      ? `已匿名化上下文：${anonymous} 个出口编号与地区标签；节点、组名与密钥不发送。`
      : '已在本机解析指令；不访问网络。'],
  };
  s.turns.push(turn);
  s.busy = turn.id;
  return turn;
}

// Local and simulated-AI parsing share one grammar. AI mode turns refusals into
// a clarification question instead of an error, like the real service.
export function parsePrompt(prompt, groups, mode) {
  const ask = (local, ai, suggestions = []) => mode === 'ai' ? { clarification: ai, suggestions } : { error: local };
  const ops = [];
  for (const clause of prompt.split(/[\n;；，,]|\s+and\s+|同时|并且/i).map(c => c.trim()).filter(Boolean)) {
    if (/延迟|太卡|最快|测速|latency|slow|fastest/i.test(clause)) {
      return ask('离线编辑器没有实时延迟数据，无法判断哪个出口更快。请指定出口或地区。', '我无法测速，也不会判断哪个出口更快。你想把哪项服务固定到哪个地区？', ['Netflix 走日本', 'ChatGPT 走美国']);
    }
    if (/不要|不走|别走|别用|除了|except|don't/i.test(clause)) {
      return ask('本地解析不支持否定或例外条件。请改用明确的正向指令，或切换到 AI 理解。', '“不走某个出口”没有说明应改走哪里。请告诉我替代出口，例如“Netflix 走美国”。', ['Netflix 走美国', 'Netflix 直连']);
    }
    const services = Object.keys(SERVICES).filter(name => clause.toLowerCase().includes(name.toLowerCase()));
    const domains = clause.match(/\b(?:[a-z0-9-]+\.)+[a-z]{2,}\b/gi) ?? [];
    if (!services.length && !domains.length) return ask('本地解析只支持 Netflix、ChatGPT、YouTube、Telegram 和明确域名。', '我没有识别到具体服务或域名。你想调整哪项服务？', ['YouTube 走香港', 'Telegram 走新加坡']);
    // "netflix.com 走日本" names both the service and a domain; keep each domain once.
    const seen = new Set();
    const items = [...services.map(name => ({ label: name, domains: SERVICES[name] })), ...domains.map(d => ({ label: d.toLowerCase(), domains: [d.toLowerCase()] }))]
      .map(item => ({ ...item, domains: item.domains.filter(d => !seen.has(d) && seen.add(d)) }))
      .filter(item => item.domains.length);
    let action, target;
    if (/删除|移除|remove|delete/i.test(clause)) action = 'remove';
    else if (/直连|\bdirect\b/i.test(clause)) { action = 'route'; target = 'DIRECT'; }
    else if (/屏蔽|拒绝|阻止|\bblock\b|\breject\b/i.test(clause)) { action = 'route'; target = 'REJECT'; }
    else {
      const regions = Object.entries(REGION_WORDS).filter(([, re]) => re.test(clause)).map(([code]) => code);
      if (regions.length !== 1) return ask('请明确一个出口，例如“Netflix 走日本”或“example.com 直连”。', `请只选一个地区作为 ${items[0].label} 的出口。`, [`${items[0].label} 走日本`, `${items[0].label} 走美国`]);
      const pool = groups.filter(g => g.region === regions[0]);
      if (pool.length !== 1) {
        const missing = `当前配置没有登记为${REGIONS[regions[0]]}的出口。可在“出口地区”中更正未指定地区的组。`;
        return pool.length ? { error: `有多个${REGIONS[regions[0]]}出口：${pool.map(g => g.name).join('、')}。请指定完整名称。` } : { error: missing };
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
  failed: { status: 'failed', message: 'Mihomo 校验失败：rules[0] 引用的出口在占位配置中不存在。此候选不能确认。' },
  unavailable: { status: 'unavailable', message: '规则结构检查通过；内置校验器不可用，尚未经过 Mihomo 语义测试。' },
};

export function completeTurn(s, id, scenario = 'normal') {
  const t = s.turns.find(turn => turn.id === id);
  if (!t || s.busy !== id || t.status !== 'running') return;
  s.busy = null;
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
  t.changes = changes; t.before = [...s.draft]; t.after = after;
  t.validation = VALIDATION[scenario === 'validation-failed' ? 'failed' : scenario === 'validator-unavailable' ? 'unavailable' : 'passed'];
  t.steps.push(`已生成 ${changes.length} 项修改。`, `校验：${t.validation.message}`);
  if (after.join('\n') === s.draft.join('\n')) t.status = 'unchanged';
  else t.status = t.validation.status === 'failed' ? 'blocked' : 'pending';
  s.selected = id;
}

export function cancelTurn(s) {
  const t = s.turns.find(turn => turn.id === s.busy);
  if (t) { t.status = 'cancelled'; t.steps.push('已取消，草稿未改变。'); }
  s.busy = null;
}

export function confirmTurn(s, id) {
  const t = s.turns.find(turn => turn.id === id);
  if (s.busy || !t || t.status !== 'pending') return false;
  s.snapshots.push({ id, draft: [...s.draft] });
  s.draft = [...t.after];
  t.status = 'confirmed';
  return true;
}

export function discardTurn(s, id) {
  const t = s.turns.find(turn => turn.id === id);
  if (s.busy || !t || t.status !== 'pending') return false;
  t.status = 'discarded';
  return true;
}

export function undoTurn(s, id) {
  const top = s.snapshots.at(-1);
  if (s.busy || !top || top.id !== id) return false;
  s.draft = s.snapshots.pop().draft;
  s.turns.find(t => t.id === id).status = 'undone';
  supersedePending(s);
  return true;
}

export const canUndo = (s, id) => !s.busy && s.snapshots.at(-1)?.id === id;

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

export function markExported(s) { s.exported = [...s.draft]; }
