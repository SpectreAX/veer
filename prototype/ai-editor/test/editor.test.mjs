import test from 'node:test';
import assert from 'node:assert/strict';
import { readFile } from 'node:fs/promises';
import { inspectConfig, readConfig, resolveLocal, applyPlan } from '../core/editor.mjs';

const sample = await readFile(new URL('../public/sample.yaml', import.meta.url), 'utf8');
const targets = inspectConfig(sample).targets;
const jp = targets.find(t => t.name === '日本出口').id;
const direct = targets.find(t => t.name === 'DIRECT').id;
const route = (match, targetId = jp, matchType = 'DOMAIN-SUFFIX') => ({ kind: 'route', match, matchType, targetId });
const plan = operations => ({ schemaVersion: 1, operations });

test('中文多服务指令解析到具体地区出口，规则位于兜底之前', () => {
  const result = applyPlan(sample, resolveLocal('Netflix 走日本，ChatGPT 走美国', targets));
  const config = readConfig(result.candidate).config;
  assert.equal(result.summaries.length, 10);
  assert.equal(config.rules[0], 'DOMAIN-SUFFIX,netflix.com,日本出口');
  assert(config.rules.includes('DOMAIN-SUFFIX,chatgpt.com,美国出口'));
  assert.equal(config.rules.at(-1), 'MATCH,默认代理');
  assert.equal(config.rules.filter(r => r.startsWith('DOMAIN-SUFFIX,netflix.com,')).length, 1);
  assert(result.candidate.includes('原有 Netflix 规则'));
});

test('复杂 Provider、DNS、未知字段、锚点与凭证保持原始语义', () => {
  const complex = `${sample}\nproxy-providers:\n  airport: { type: http, url: 'https://example.com/sub?token=private', path: ./airport.yaml }\nrule-providers:\n  stream: { type: http, behavior: classical, url: 'https://example.com/rules', path: ./stream.yaml }\nx-default: &resolver {nameserver: [https://example.com/dns-query]}\nx-copy: *resolver\nurl-rewrite: ['^http://example.com https://example.com 302']\n`;
  const before = readConfig(complex).config;
  const after = readConfig(applyPlan(complex, plan([route('example.com')])).candidate).config;
  delete before.rules; delete after.rules;
  assert.deepEqual(after, before);
});

test('YAML merge key 保留并解析继承名称', () => {
  const yaml = 'defaults: &defaults {type: trojan, server: example.com, port: 443, password: secret}\nproxies:\n  - <<: *defaults\n    name: Japan\nrules: [MATCH,DIRECT]\n';
  const result = applyPlan(yaml, plan([route('example.com', 'target-0')]));
  assert(result.candidate.includes('<<: *defaults'));
  assert.equal(readConfig(result.candidate).config.proxies[0].type, 'trojan');
});

test('不存在的目标与注入型规则值被拒绝', () => {
  assert.throws(() => applyPlan(sample, plan([route('example.com', 'missing')])), /不存在/);
  assert.throws(() => applyPlan(sample, plan([route('example.com,DIRECT')])), /不允许/);
  assert.throws(() => applyPlan(sample, plan([route('999.1.1.1/24', direct, 'IP-CIDR')])), /CIDR/);
  assert.throws(() => applyPlan(sample, plan([route('::1/129', direct, 'IP-CIDR6')])), /CIDR/);
});

test('冲突和未支持的计划不改变输入', () => {
  assert.throws(() => applyPlan(sample, plan([route('example.com'), route('example.com', direct)])), /冲突/);
  assert.throws(() => applyPlan(sample, plan([{ kind: 'set_dns' }])), /只支持/);
  assert.equal(readConfig(sample).config.rules.length, 3);
});

test('规则删除只删除指定项，未找到时明确拒绝', () => {
  const p = plan([{ kind: 'remove_rule', matchType: 'DOMAIN-SUFFIX', match: 'example.com' }]);
  assert.equal(readConfig(applyPlan(sample, p).candidate).config.rules.length, 2);
  assert.throws(() => applyPlan(sample, plan([{ ...p.operations[0], match: 'missing.com' }])), /没有删除/);
});

test('重复执行同一服务修改无新增重复项', () => {
  const p = resolveLocal('Netflix go jp', targets);
  const first = applyPlan(sample, p);
  const second = applyPlan(first.candidate, p);
  assert.equal(second.changed, false);
});

test('改出口时保留 no-resolve', () => {
  const yaml = `${sample.replace('  - MATCH,默认代理', '  - IP-CIDR,1.2.3.0/24,DIRECT,no-resolve\n  - MATCH,默认代理')}`;
  const out = applyPlan(yaml, plan([route('1.2.3.0/24', jp, 'IP-CIDR')]));
  assert(readConfig(out.candidate).config.rules.includes('IP-CIDR,1.2.3.0/24,日本出口,no-resolve'));
});

test('歧义、缺少地区和实时延迟请求不能猜测', () => {
  assert.throws(() => resolveLocal('Netflix 走日本', targets.filter(t => t.name !== '日本出口').concat({ id: 'other', name: 'JP Osaka Demo', kind: 'node' })), /多个/);
  assert.throws(() => resolveLocal('Netflix go hk', targets), /没有/);
  assert.throws(() => resolveLocal('Netflix 换最快节点', targets), /实时延迟/);
  assert.throws(() => resolveLocal('Netflix 走日本和美国', targets), /明确一个/);
});

test('直接网站、屏蔽指令和出口完整名称', () => {
  assert.equal(resolveLocal('example.com 直连', targets).operations[0].targetId, direct);
  assert.equal(resolveLocal('example.com 屏蔽', targets).operations[0].targetId, targets.find(t => t.name === 'REJECT').id);
  assert.equal(resolveLocal('Netflix 使用出口 日本出口', targets).operations[0].targetId, jp);
  assert.equal(resolveLocal('netflix.com 走日本', targets).operations.length, 1);
});

test('只替换 rules 源码片段，规则以外文字逐字保留', () => {
  const yaml = `${sample}\nx-trailing: {keep: 'exactly'} # tail comment\n`;
  const result = applyPlan(yaml, plan([route('example.com')]));
  assert.equal(result.candidate.split('rules:')[0], yaml.split('rules:')[0]);
  assert(result.candidate.endsWith("x-trailing: {keep: 'exactly'} # tail comment\n"));
});

test('保留自定义 rules 缩进、行内规则、无 rules 配置', () => {
  for (const rules of ['rules:\n    - MATCH,DIRECT\n', 'rules:\n- MATCH,DIRECT\n', 'rules: ["MATCH,DIRECT"]\n', '']) {
    const result = applyPlan(`mode: rule\n${rules}`, plan([route('example.com', 'target-0')]));
    assert.equal(readConfig(result.candidate).config.rules[0], 'DOMAIN-SUFFIX,example.com,DIRECT');
  }
});

test('单条规则使用锚点引用时仍可准确替换', () => {
  const yaml = 'x-rule: &old DOMAIN-SUFFIX,example.com,REJECT\nrules:\n  - *old\n  - MATCH,DIRECT\n';
  const out = applyPlan(yaml, plan([route('example.com', 'target-0')]));
  assert.equal(readConfig(out.candidate).config.rules.filter(r => r.startsWith('DOMAIN-SUFFIX,example.com,')).length, 1);
  assert(out.candidate.includes('x-rule: &old DOMAIN-SUFFIX,example.com,REJECT'));
});

test('重复 YAML 键、空配置与组引用循环被拒绝', () => {
  assert.throws(() => inspectConfig('mode: rule\nmode: global'), /YAML/);
  assert.throws(() => inspectConfig(''), /导入/);
  assert.throws(() => inspectConfig('proxy-groups:\n - {name: A, type: select, proxies: [B]}\n - {name: B, type: select, proxies: [A]}'), /循环/);
});

test('同名目标与 Provider 缺失引用被拒绝', () => {
  assert.throws(() => inspectConfig('proxies: [{name: A}, {name: A}]'), /重复/);
  assert.throws(() => inspectConfig('proxy-groups: [{name: A, type: select, use: [missing]}]'), /不存在的 Provider/);
});

test('计划只接受约定对象和字段，拒绝静默忽略模型扩展操作', () => {
  for (const invalid of [
    null, [], { ...plan([route('example.com')]), dns: { enable: false } },
    { ...plan([route('example.com')]), clarification: '不确定出口' },
    plan([null]), plan([[]]), plan([]), plan(Array(33).fill(route('example.com'))),
    plan([{ ...route('example.com'), noResolve: true }]),
    plan([{ kind: 'remove_rule', matchType: 'DOMAIN-SUFFIX', match: 'example.com', targetId: jp }]),
  ]) assert.throws(() => applyPlan(sample, invalid), error => error.name !== 'TypeError');
  assert.equal(applyPlan(sample, plan([route('example.com')])).summaries.length, 1);
});

test('本地解析拒绝否定、互斥动作和完整名称冲突，整批不返回部分计划', () => {
  for (const prompt of ['example.com 不要直连', 'example.com do not block', 'example.com 直连或屏蔽', 'Netflix 日本出口或美国出口', 'Netflix 直连或走日本', '删除 example.com 并直连', 'Netflix 走日本，example.com 不要直连']) {
    assert.throws(() => resolveLocal(prompt, targets), /否定|多个动作/);
  }
  assert.equal(resolveLocal('Netflix 走日本，example.com 直连', targets).operations.length, 7);
});

test('大小写不同的同一匹配被替换或删除，而不是留下重复规则', () => {
  const config = 'proxy-groups:\n  - name: 日本出口\n    type: select\n    proxies: [DIRECT]\nrules:\n  - DOMAIN-SUFFIX,Netflix.COM,DIRECT\n  - MATCH,DIRECT\n';
  const target = inspectConfig(config).targets.find(t => t.name === '日本出口').id;
  const routed = applyPlan(config, plan([route('netflix.com', target)]));
  assert.deepEqual(readConfig(routed.candidate).config.rules, ['DOMAIN-SUFFIX,netflix.com,日本出口', 'MATCH,DIRECT']);
  assert.deepEqual(routed.summaries[0].before, ['DOMAIN-SUFFIX,Netflix.COM,DIRECT']);
  const removed = applyPlan(config, plan([{ kind: 'remove_rule', matchType: 'DOMAIN-SUFFIX', match: 'netflix.com' }]));
  assert.deepEqual(readConfig(removed.candidate).config.rules, ['MATCH,DIRECT']);
  assert.throws(() => applyPlan(config, plan([route('netflix.com', target), route('NETFLIX.com', target)])), /重复或冲突/);
});
