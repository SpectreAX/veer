import test from 'node:test';
import assert from 'node:assert/strict';
import { applyPlan, buildSystemPrompt } from '../core/editor.mjs';
import { ruleSetSpec, verifyRuleSetUrls } from '../core/rule-sets.mjs';
import { createEditorServer } from '../server.mjs';

const source = `# 用户注释保持不变
mixed-port: 7890
proxies:
  - { name: hk-node, type: ss, server: hk.example.com, port: 443, cipher: aes-128-gcm, password: secret-pass }
proxy-groups:
  - name: 🚀 节点选择
    type: select
    proxies: [hk-node, DIRECT]
rule-providers:
  existing-cn:
    type: http
    behavior: domain
    format: mrs
    url: https://raw.githubusercontent.com/MetaCubeX/meta-rules-dat/meta/geo/geosite/cn.mrs
    path: ./rule_provider/existing-cn.mrs
    interval: 86400
rules:
  - RULE-SET,existing-cn,DIRECT
  - MATCH,🚀 节点选择
`;
const plan = operations => ({ schemaVersion: 1, operations });

test('规则集：新增 provider 与 RULE-SET 规则，其他字段逐字节保留', () => {
  const result = applyPlan(source, plan([{ kind: 'rule_set', source: 'metacubex-geosite', name: 'youtube', targetId: 'target-0' }]));
  assert.ok(result.candidate.startsWith('# 用户注释保持不变\nmixed-port: 7890\nproxies:\n  - { name: hk-node, type: ss, server: hk.example.com, port: 443, cipher: aes-128-gcm, password: secret-pass }'));
  assert.match(result.candidate, /  youtube:\n    type: http\n    behavior: domain\n    format: mrs\n    url: https:\/\/raw\.githubusercontent\.com\/MetaCubeX\/meta-rules-dat\/meta\/geo\/geosite\/youtube\.mrs\n    path: \.\/rule_provider\/youtube\.mrs\n    interval: 86400/);
  assert.match(result.candidate, /rules:\n  - RULE-SET,youtube,🚀 节点选择\n  - RULE-SET,existing-cn,DIRECT/);
  assert.equal(result.summaries[0].kind, 'rule_set');
  assert.equal(result.summaries[0].provider.reused, false);
});

test('规则集：相同地址复用已有 provider，名称冲突时自动改名，mrs 不接受混合规则', () => {
  const reused = applyPlan(source, plan([{ kind: 'rule_set', source: 'metacubex-geosite', name: 'cn', targetId: 'target-0' }]));
  assert.equal(reused.summaries[0].provider.reused, true);
  assert.match(reused.candidate, /RULE-SET,existing-cn,🚀 节点选择/);
  assert.equal((reused.candidate.match(/existing-cn:/g) ?? []).length, 1);
  const clash = source.replace('existing-cn:', 'youtube:').replaceAll('RULE-SET,existing-cn', 'RULE-SET,youtube');
  const renamed = applyPlan(clash, plan([{ kind: 'rule_set', source: 'metacubex-geosite', name: 'youtube', targetId: 'target-0' }]));
  assert.equal(renamed.summaries[0].provider.name, 'youtube-veer');
  assert.throws(() => ruleSetSpec({ kind: 'rule_set', url: 'https://raw.githubusercontent.com/x/y/main/a.mrs', behavior: 'classical', targetId: 't' }), /mrs/);
  assert.throws(() => ruleSetSpec({ kind: 'rule_set', url: 'https://evil.example.com/a.list', targetId: 't' }), /raw\.githubusercontent/);
  assert.throws(() => ruleSetSpec({ kind: 'rule_set', source: 'metacubex-geosite', name: '../../etc', targetId: 't' }), /名称无效/);
});

test('规则集：用户提供的地址按扩展名与目录推断格式和类型', () => {
  const geoip = ruleSetSpec({ kind: 'rule_set', url: 'https://raw.githubusercontent.com/MetaCubeX/meta-rules-dat/meta/geo/geoip/cn.mrs', targetId: 't' });
  assert.deepEqual({ ...geoip }, { url: 'https://raw.githubusercontent.com/MetaCubeX/meta-rules-dat/meta/geo/geoip/cn.mrs', behavior: 'ipcidr', format: 'mrs', key: 'cn-ip' });
  const list = ruleSetSpec({ kind: 'rule_set', url: 'https://raw.githubusercontent.com/blackmatrix7/ios_rule_script/master/rule/Clash/OneDrive/OneDrive.list', targetId: 't' });
  assert.equal(list.behavior, 'classical'); assert.equal(list.format, 'text'); assert.equal(list.key, 'OneDrive');
  assert.equal(ruleSetSpec({ kind: 'rule_set', source: 'acl4ssr', name: 'Ruleset/YouTube', targetId: 't' }).url, 'https://raw.githubusercontent.com/ACL4SSR/ACL4SSR/master/Clash/Ruleset/YouTube.list');
});

test('地址验证：404 拒绝并给出查找指引；网络失败只标记未验证', async () => {
  const fake = status => async () => { if (status === 'offline') throw new Error('offline'); return new Response(null, { status }); };
  await assert.rejects(() => verifyRuleSetUrls(['https://raw.githubusercontent.com/a/b/c.mrs'], fake(404)), error => /404/.test(error.message) && /meta-rules-dat/.test(error.message));
  assert.equal((await verifyRuleSetUrls(['https://x/a.mrs'], fake(200))).get('https://x/a.mrs'), 'verified');
  assert.equal((await verifyRuleSetUrls(['https://x/a.mrs'], fake('offline'))).get('https://x/a.mrs'), 'unverified');
});

test('系统指令面向 Veer 客户端：没有 OpenClash 步骤，要求未指定出口时澄清', () => {
  const prompt = buildSystemPrompt([{ id: 'target-0', name: '出口1（日本）', kind: 'group' }]);
  assert.doesNotMatch(prompt, /OpenClash|ruby_merge_hash|LuCI|覆写脚本|OpenWrt/);
  assert.match(prompt, /rule_set/);
  assert.match(prompt, /走代理/);
  assert.match(prompt, /never construct or modify a URL/);
});

test('文档模式：规则集随草稿保留，导出包含 provider；独立片段拒绝规则集', async t => {
  let answer;
  const checked = [];
  const server = createEditorServer({ binary: '/missing', aiResolver: async () => answer, ruleSetFetch: async (url, init) => { checked.push([url, init.method]); return new Response(null, { status: 200 }); } });
  await new Promise(resolve => server.listen(0, '127.0.0.1', resolve));
  t.after(() => new Promise(resolve => server.close(resolve)));
  const base = `http://127.0.0.1:${server.address().port}`;
  const post = (path, body) => fetch(base + path, { method: 'POST', headers: { 'Content-Type': 'application/json', Origin: base }, body: JSON.stringify(body) });
  const draft = await (await post('/api/document/import', { yaml: source })).json();
  const doc = { yaml: source, groups: draft.groups, rules: draft.rules, mode: 'ai', settings: { apiKey: 'k', model: 'm', baseUrl: 'https://example.com' } };
  answer = { schemaVersion: 1, operations: [{ kind: 'rule_set', source: 'metacubex-geosite', name: 'youtube', targetId: 'target-0' }] };
  const preview = await (await post('/api/document/plan', { ...doc, prompt: 'YouTube 走节点选择' })).json();
  assert.deepEqual(checked, [['https://raw.githubusercontent.com/MetaCubeX/meta-rules-dat/meta/geo/geosite/youtube.mrs', 'HEAD']]);
  assert.equal(preview.summaries[0].provider.verified, true);
  assert.equal(preview.validation.status, 'unavailable');
  assert.match(preview.candidate, /rule-providers:\n  youtube:/);
  assert.ok(!preview.candidate.includes('existing-cn:'), 'only providers Veer added travel in the draft');
  const exported = await (await post('/api/document/export', { ...doc, rules: preview.candidate })).json();
  assert.match(exported.yaml, /  youtube:\n    type: http/);
  assert.match(exported.yaml, /existing-cn:/);
  assert.match(exported.yaml, /password: secret-pass/);
  const inspected = await (await post('/api/document/inspect', { ...doc, rules: preview.candidate })).json();
  assert.equal(inspected.rules[0], 'RULE-SET,youtube,🚀 节点选择');
  const fragment = await post('/api/private/plan', { groups: [{ name: '日本出口', region: 'JP' }], rules: 'rules: []', prompt: 'YouTube 规则集', mode: 'ai', settings: { apiKey: 'k', model: 'm', baseUrl: 'https://example.com' } });
  assert.equal(fragment.status, 422);
  assert.match((await fragment.json()).error, /独立规则片段不能添加规则集/);
});
