import test from 'node:test';
import assert from 'node:assert/strict';
import { parse, stringify } from 'yaml';
import { openDocument, mergeDocument } from '../core/document.mjs';
import { createEditorServer } from '../server.mjs';

const prefix = '# private fields must be byte-preserved\nproxies:\n  - { name: 日本私有节点, type: trojan, server: private.example, port: 443, password: private-test-secret }\nproxy-groups:\n  - { name: 日本出口, type: select, proxies: [日本私有节点] }\nrule-providers:\n  service: { type: http, behavior: classical, url: "https://example.invalid/rules?token=private-test-token", path: ./rules.yaml }\ndns: { enable: true, nameserver: [1.1.1.1] }\n';
const yaml = prefix + 'rules:\n  - RULE-SET,service,日本出口\n  - DOMAIN-SUFFIX,example.com,DIRECT\n  - MATCH,DIRECT\n';

test('完整配置导入仅返回规则和出口地区，不返回节点或凭证', () => {
  const draft = openDocument(yaml);
  assert.equal(draft.groups.find(g => g.name === '日本出口').region, 'JP');
  assert(draft.rules.includes('MATCH,DIRECT'));
  assert(!JSON.stringify(draft).includes('private-test-secret'));
  for (const invalid of ['', 'proxies: [', 'c3M6Ly9leGFtcGxl']) assert.throws(() => openDocument(invalid), /无法安全解析/);
});

test('规则合并、删除、撤销保留非规则字段逐字不变', () => {
  const draft = openDocument(yaml);
  assert.equal(mergeDocument(yaml, draft.rules), yaml);
  const rules = stringify({ rules: ['DOMAIN-SUFFIX,netflix.com,日本出口', 'RULE-SET,service,日本出口', 'MATCH,DIRECT'] });
  const merged = mergeDocument(yaml, rules);
  assert(merged.startsWith(prefix));
  assert.equal(parse(merged).proxies[0].password, 'private-test-secret');
  assert(!parse(merged).rules.some(r => r.includes('example.com')));
  assert.throws(() => mergeDocument(yaml, 'rules: []\nproxies: []'), /无法安全解析/);
  for (const source of ['rules: []\n', 'rules: [MATCH,DIRECT]\n', 'mode: rule\n', 'rules:\n    - MATCH,DIRECT\n']) {
    const merged = mergeDocument(source, 'rules:\n  - DOMAIN-SUFFIX,example.com,DIRECT\n');
    assert.deepEqual(parse(merged).rules, ['DOMAIN-SUFFIX,example.com,DIRECT']);
  }
});

test('原生完整配置链路：AI 匿名输入、预览未应用、完整导出及来源隔离', async t => {
  let calls = 0;
  const server = createEditorServer({ binary: '/missing', aiResolver: async (prompt, targets) => {
    calls++;
    const payload = JSON.stringify({ prompt, targets });
    for (const sensitive of ['日本出口', '日本私有节点', 'private-test-secret', 'private-test-token', 'private.example', 'RULE-SET']) assert(!payload.includes(sensitive));
    const target = targets.find(t => t.name.includes('日本'));
    return { schemaVersion: 1, operations: [{ kind: 'route', matchType: 'DOMAIN-SUFFIX', match: 'netflix.com', targetId: target.id }] };
  } });
  await new Promise(resolve => server.listen(0, '127.0.0.1', resolve));
  t.after(() => new Promise(resolve => server.close(resolve)));
  const base = `http://127.0.0.1:${server.address().port}`;
  const post = (path, data, origin = base) => fetch(`${base}/api/document/${path}`, { method: 'POST', headers: { 'Content-Type': 'application/json', Origin: origin }, body: JSON.stringify(data) });
  const draft = await (await post('import', { yaml })).json();
  const input = { yaml, ...draft, prompt: 'Netflix 走日本出口', mode: 'ai', settings: {} };
  const result = await (await post('plan', input)).json();
  assert.equal(result.changed, true);
  assert.equal(result.validation.status, 'unavailable');
  assert(result.candidate.includes('DOMAIN-SUFFIX,netflix.com,日本出口'));
  assert(result.candidate.includes('RULE-SET,service,日本出口'));
  const local = await (await post('plan', { ...input, mode: 'local', prompt: 'Netflix 走日本' })).json();
  assert.equal(local.summaries.length, 6);
  assert(local.summaries.every(s => s.target === '日本出口'));
  const exported = await (await post('export', { yaml, ...draft, rules: result.candidate })).json();
  assert(exported.yaml.startsWith(prefix));
  assert.equal((await post('import', { yaml }, 'https://evil.invalid')).status, 403);
  assert.equal((await post('plan', { ...input, rules: 'rules: [\nsecret: private-test-secret' })).status, 422);
  assert.equal(calls, 1);
  const unchanged = await (await post('export', { yaml, ...draft })).json();
  assert.equal(unchanged.yaml, yaml);
});
