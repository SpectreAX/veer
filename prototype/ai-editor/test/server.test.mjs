import test from 'node:test';
import assert from 'node:assert/strict';
import { readFile } from 'node:fs/promises';
import { createEditorServer } from '../server.mjs';
import { validateCore } from '../core/validator.mjs';
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
