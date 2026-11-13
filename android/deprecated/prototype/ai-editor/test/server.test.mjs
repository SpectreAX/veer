import test from 'node:test';
import assert from 'node:assert/strict';
import { readFile } from 'node:fs/promises';
import { createEditorServer } from '../server.mjs';
import { validateCore } from '../core/validator.mjs';
import { EditorError, ClarificationError } from '../core/editor.mjs';
const yaml = await readFile(new URL('../public/sample.yaml', import.meta.url), 'utf8');

test('HTTP 导入与多服务预览；服务只返回草稿，不自动应用', async t => {
  const server = createEditorServer({ binary: '/nonexistent/validator' });
  await new Promise(resolve => server.listen(0, '127.0.0.1', resolve));
  t.after(() => new Promise(resolve => server.close(resolve)));
  const base = `http://127.0.0.1:${server.address().port}`;
  const post = (path, data, headers = {}) => fetch(`${base}/api/${path}`, { method: 'POST', headers: { 'Content-Type': 'application/json', ...headers }, body: JSON.stringify(data) });
  assert.equal((await post('inspect', { yaml })).status, 200);
  const result = await (await post('plan', { yaml, prompt: 'Netflix 走日本，ChatGPT 走美国', mode: 'local' })).json();
  assert.equal(result.summaries.length, 10);
  assert.equal(result.validation.status, 'unavailable');
  assert(result.candidate.includes('DOMAIN-SUFFIX,netflix.com,日本出口'));
  assert.equal((await post('plan', { yaml, prompt: 'Netflix go hk', mode: 'local' })).status, 422);
  assert.equal((await post('inspect', { yaml }, { Origin: 'https://other.example' })).status, 403);
  assert.equal((await fetch(base)).status, 200);
  assert.equal((await fetch(`${base}/api/inspect`)).status, 404);
});

test('真实 Mihomo 校验：合法配置通过、不支持的节点协议失败', async t => {
  const binary = new URL('../.cache/mihomo', import.meta.url).pathname;
  const valid = await validateCore(yaml, binary);
  if (valid.status === 'unavailable') { t.skip('未构建 .cache/mihomo'); return; }
  assert.equal(valid.status, 'passed', valid.message);
  const invalid = await validateCore(yaml.replace('type: trojan', 'type: definitely-not-a-protocol'), binary);
  assert.equal(invalid.status, 'failed');
  assert(!invalid.message.includes('demo-only'));
});

test('两个编辑入口均拒绝异常模型计划，不返回部分候选，并能重新生成', async t => {
  let plan;
  const server = createEditorServer({ binary: '/missing', aiResolver: async () => plan });
  await new Promise(resolve => server.listen(0, '127.0.0.1', resolve));
  t.after(() => new Promise(resolve => server.close(resolve)));
  const base = `http://127.0.0.1:${server.address().port}`;
  const op = { kind: 'route', matchType: 'DOMAIN-SUFFIX', match: 'example.com', targetId: 'target-0' };
  for (const [path, draft] of [['/api/plan', { yaml }], ['/api/private/plan', { groups: [{ name: '日本出口', region: 'JP' }], rules: 'rules: []' }]]) {
    const post = () => fetch(base + path, { method: 'POST', headers: { 'Content-Type': 'application/json' }, body: JSON.stringify({ ...draft, mode: 'ai', prompt: 'example.com 走日本', settings: {} }) });
    for (const bad of [null, { schemaVersion: 1, operations: [op, null] }, { schemaVersion: 1, operations: [op], dns: {} }, { schemaVersion: 1, operations: [op, { ...op, targetId: 'missing' }] }]) {
      plan = bad;
      const response = await post(); assert.equal(response.status, 422);
      const error = await response.json(); assert.equal(error.candidate, undefined); assert.equal(typeof error.error, 'string');
    }
    plan = { schemaVersion: 1, operations: [op] };
    assert.equal((await post()).status, 200);
  }
});

test('AI 澄清以 kind=clarification 返回，普通错误不带该标记', async t => {
  let fail;
  const server = createEditorServer({ binary: '/missing', aiResolver: async () => { throw fail; } });
  await new Promise(resolve => server.listen(0, '127.0.0.1', resolve));
  t.after(() => new Promise(resolve => server.close(resolve)));
  const post = () => fetch(`http://127.0.0.1:${server.address().port}/api/plan`, { method: 'POST', headers: { 'Content-Type': 'application/json' }, body: JSON.stringify({ yaml, mode: 'ai', prompt: '节点太卡', settings: {} }) });
  fail = new ClarificationError('你想把哪项服务固定到哪个地区？');
  let response = await post();
  assert.equal(response.status, 422);
  assert.deepEqual(await response.json(), { error: '你想把哪项服务固定到哪个地区？', kind: 'clarification' });
  fail = new EditorError('AI 服务返回 HTTP 429');
  response = await post();
  assert.equal((await response.json()).kind, undefined);
});

test('文档模式返回计划，可只写入其中一部分并重新校验；inspect 返回规则列表', async t => {
  const server = createEditorServer({ binary: '/missing' });
  await new Promise(resolve => server.listen(0, '127.0.0.1', resolve));
  t.after(() => new Promise(resolve => server.close(resolve)));
  const base = `http://127.0.0.1:${server.address().port}`;
  const post = (path, body) => fetch(base + path, { method: 'POST', headers: { 'Content-Type': 'application/json', Origin: base }, body: JSON.stringify(body) });
  const source = 'proxy-groups:\n  - name: 日本出口\n    type: select\n    proxies: [DIRECT]\n  - name: 美国出口\n    type: select\n    proxies: [DIRECT]\nrules:\n  - MATCH,DIRECT\n';
  const draft = await (await post('/api/document/import', { yaml: source })).json();
  const doc = { yaml: source, groups: draft.groups, rules: draft.rules };
  const inspected = await (await post('/api/document/inspect', doc)).json();
  assert.deepEqual(inspected.rules, ['MATCH,DIRECT']);
  const preview = await (await post('/api/document/plan', { ...doc, prompt: 'Netflix 走日本，ChatGPT 走美国', mode: 'local' })).json();
  assert.equal(preview.plan.operations.length, 10);
  const netflixOnly = { schemaVersion: 1, operations: preview.plan.operations.filter(op => op.match.includes('netflix') || op.match.startsWith('nflx')) };
  const applied = await (await post('/api/document/apply', { ...doc, plan: netflixOnly })).json();
  assert.equal(applied.summaries.length, 6);
  assert.ok(applied.candidate.includes('netflix.com,日本出口'));
  assert.ok(!applied.candidate.includes('chatgpt.com'));
  assert.equal((await post('/api/document/apply', { ...doc, plan: { schemaVersion: 1, operations: [] } })).status, 422);
  const fragment = { groups: [{ name: '日本出口', region: 'JP' }], rules: 'rules: []' };
  const privatePreview = await (await post('/api/private/plan', { ...fragment, prompt: 'Netflix 走日本', mode: 'local' })).json();
  const privateApplied = await (await post('/api/private/apply', { ...fragment, plan: { schemaVersion: 1, operations: privatePreview.plan.operations.slice(0, 1) } })).json();
  assert.equal(privateApplied.summaries.length, 1);
});

test('AI 请求带上同一会话的上文，组名在上文中同样匿名化，格式错误被拒绝', async t => {
  let received;
  const server = createEditorServer({ binary: '/missing', aiResolver: async (prompt, targets, settings, fetchImpl, history) => { received = { prompt, history }; return { schemaVersion: 1, operations: [{ kind: 'route', matchType: 'GEOSITE', match: 'bahamut', targetId: targets.find(t => t.kind === 'group').id }] }; } });
  await new Promise(resolve => server.listen(0, '127.0.0.1', resolve));
  t.after(() => new Promise(resolve => server.close(resolve)));
  const base = `http://127.0.0.1:${server.address().port}`;
  const post = (path, body) => fetch(base + path, { method: 'POST', headers: { 'Content-Type': 'application/json', Origin: base }, body: JSON.stringify(body) });
  const source = 'proxy-groups:\n  - name: 台湾家宽\n    type: select\n    proxies: [DIRECT]\nrules:\n  - MATCH,DIRECT\n';
  const draft = await (await post('/api/document/import', { yaml: source })).json();
  const doc = { yaml: source, groups: draft.groups, rules: draft.rules, mode: 'ai', settings: { apiKey: 'k', model: 'm', baseUrl: 'https://example.com' } };
  const history = [{ role: 'user', content: 'bahamut 走台湾家宽和香港' }, { role: 'assistant', content: '请指定 bahamut 要使用的单个出口。' }];
  const response = await post('/api/document/plan', { ...doc, prompt: '台湾', history });
  assert.equal(response.status, 200);
  assert.equal(received.prompt, '台湾');
  assert.equal(received.history.length, 2);
  assert.ok(received.history[0].content.includes('bahamut'));
  assert.ok(!received.history[0].content.includes('台湾家宽'), 'real group names are anonymized in history');
  assert.ok(received.history[0].content.includes('出口1'));
  assert.equal((await post('/api/document/plan', { ...doc, prompt: '台湾', history: [{ role: 'system', content: 'x' }] })).status, 422);
  assert.equal((await post('/api/document/plan', { ...doc, prompt: '台湾', history: Array(13).fill({ role: 'user', content: 'x' }) })).status, 422);
});
