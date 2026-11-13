import test from 'node:test';
import assert from 'node:assert/strict';
import { parse } from 'yaml';
import { readPrivateInput, anonymizePrompt, applyPrivatePlan, resolvePrivateLocal } from '../core/private-editor.mjs';
import { createEditorServer } from '../server.mjs';
import { resolveAi } from '../core/llm.mjs';
import { validateCore } from '../core/validator.mjs';
const groups = [{ name: 'Secret Airport [A].* JP', region: 'JP' }, { name: 'Private US Pool', region: 'US' }];
const input = { groups, rules: 'rules: []\n' };

test('独立规则只接收组名地区及 rules，拒绝节点配置、扩展字段、未知出口和锚点', () => {
  for (const invalid of [
    { ...input, yaml: 'password: forbidden' },
    { ...input, groups: [{ ...groups[0], password: 'forbidden' }] },
    { ...input, groups: [{ ...groups[0], region: 'INVALID' }] },
    { ...input, groups: [groups[0], groups[0]] },
    { ...input, rules: 'proxies: [{name: x, password: forbidden}]\nrules: []' },
    { ...input, rules: 'rules: [DOMAIN-SUFFIX,example.com,UNKNOWN]' },
    { ...input, rules: 'rules: ["MATCH,DIRECT"]' },
    { ...input, rules: 'rules: ["DOMAIN-SUFFIX,example.com,DIRECT,no-resolve"]' },
    { ...input, rules: 'rules: [&a "DOMAIN-SUFFIX,example.com,DIRECT", *a]' },
  ]) assert.throws(() => readPrivateInput(invalid));
});

test('出口名在模型上下文和指令中匿名化，编号在本地恢复原组名', () => {
  const context = readPrivateInput(input);
  const prompt = anonymizePrompt(`Netflix 走 ${groups[0].name}，ChatGPT 走 ${groups[1].name}`, context.targets, context.anonymousTargets);
  for (const g of groups) assert(!prompt.includes(g.name));
  assert.match(prompt, /出口1（日本）/);
  const result = applyPrivatePlan(input, resolvePrivateLocal('Netflix 走日本，ChatGPT 走美国', context));
  const output = parse(result.candidate);
  assert.deepEqual(Object.keys(output), ['rules']);
  assert.equal(output.rules.length, 10);
  assert(output.rules.includes(`DOMAIN-SUFFIX,netflix.com,${groups[0].name}`));
  assert(!result.candidate.includes('proxies:'));
  assert.throws(() => applyPrivatePlan(input, { schemaVersion: 1, operations: [{ kind: 'route', matchType: 'DOMAIN-SUFFIX', match: 'example.com', targetId: 'invented' }] }));
});

test('无节点的独立规则支持直连、屏蔽、删除与重复执行', () => {
  const empty = { groups: [], rules: 'rules: []\n' };
  const context = readPrivateInput(empty);
  const result = applyPrivatePlan(empty, resolvePrivateLocal('example.com 屏蔽', context));
  const updated = { ...empty, rules: result.candidate };
  assert(parse(result.candidate).rules.includes('DOMAIN-SUFFIX,example.com,REJECT'));
  assert.equal(applyPrivatePlan(updated, resolvePrivateLocal('example.com 屏蔽', readPrivateInput(updated))).changed, false);
  assert.deepEqual(parse(applyPrivatePlan(updated, resolvePrivateLocal('删除 example.com 规则', readPrivateInput(updated))).candidate), { rules: [] });
});

test('HTTP 独立模式到真实 AI 适配层的请求无真实组名或规则稿，额外字段在模型前拒绝', async t => {
  let wire, called = 0;
  const server = createEditorServer({ binary: '/missing', aiResolver: (prompt, targets, settings) => {
    called++;
    return resolveAi(prompt, targets, settings, async (_url, init) => {
      wire = JSON.parse(init.body);
      return Response.json({ choices: [{ message: { content: JSON.stringify({ schemaVersion: 1, operations: [{ kind: 'route', matchType: 'DOMAIN-SUFFIX', match: 'netflix.com', targetId: 'target-0' }] }) } }] });
    });
  } });
  await new Promise(resolve => server.listen(0, '127.0.0.1', resolve));
  t.after(() => new Promise(resolve => server.close(resolve)));
  const base = `http://127.0.0.1:${server.address().port}`;
  const post = data => fetch(`${base}/api/private/plan`, { method: 'POST', headers: { 'Content-Type': 'application/json' }, body: JSON.stringify(data) });
  const payload = { ...input, rules: 'rules: ["DOMAIN-SUFFIX,private-rule.example,DIRECT"]', mode: 'ai', prompt: `Netflix 走 ${groups[0].name}`, settings: { apiKey: 'test-only', model: 'model', baseUrl: 'https://api.example.com' } };
  const response = await post(payload); assert.equal(response.status, 200);
  const result = await response.json();
  assert(result.candidate.includes(groups[0].name)); assert.equal(result.synthetic, undefined);
  const sent = JSON.stringify(wire);
  for (const group of groups) assert(!sent.includes(group.name));
  assert(!sent.includes('private-rule.example'));
  assert.equal((await post({ ...payload, yaml: 'secret' })).status, 422);
  assert.equal(called, 1);
  assert((await (await fetch(base)).text()).includes('/private.js'));
  assert((await (await fetch(`${base}/advanced`)).text()).includes('/app.js'));
});

test('占位策略组可通过本机 Mihomo 检查，但导出不含占位组', async t => {
  const result = applyPrivatePlan(input, resolvePrivateLocal('Netflix 走日本', readPrivateInput(input)));
  const validation = await validateCore(result.synthetic, new URL('../.cache/mihomo', import.meta.url).pathname);
  if (validation.status === 'unavailable') { t.skip('未构建核心'); return; }
  assert.equal(validation.status, 'passed', validation.message);
  assert.deepEqual(Object.keys(parse(result.candidate)), ['rules']);
});
