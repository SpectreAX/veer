import assert from 'node:assert/strict';
import { test } from 'node:test';
import {
  SAMPLES, initialApp, createSession, activeSession, switchSession, deleteSession, filterSessions, serialize, restore,
  setRegion, unknownRegions, hasUnsavedChanges, canSend, startTurn, completeTurn, cancelTurn, setDecision, acceptedCount,
  candidateRules, applyTurn, rejectTurn, undoTurn, canUndo, triggerAt, menuItems, applyMenuItem, matchDomain, searchRules,
  diffRules, diffStats, markExported,
} from './state.mjs';

const setup = () => { const app = initialApp(); const s = createSession(app); return { app, s }; };
const run = (app, s, prompt, scenario) => { const t = startTurn(app, s, prompt); completeTurn(s, t.id, scenario); return t; };

test('逐项审批：只写入接受的修改，拒绝项不进入草稿', () => {
  const { app, s } = setup();
  const t = run(app, s, 'Netflix 走日本，ChatGPT 走美国');
  assert.equal(t.status, 'pending');
  assert.deepEqual(s.draft, SAMPLES.normal.rules);
  assert.ok(setDecision(s, t.id, 1, 'rejected'));
  assert.equal(acceptedCount(t), 1);
  assert.ok(!candidateRules(t).some(r => r.startsWith('DOMAIN-SUFFIX,chatgpt.com')));
  assert.ok(applyTurn(s, t.id));
  assert.equal(s.draft.filter(r => r.endsWith(',🇯🇵 日本 自动')).length, 6);
  assert.ok(!s.draft.some(r => r.startsWith('DOMAIN-SUFFIX,chatgpt.com')));
  assert.deepEqual(t.changes.map(c => c.decision), ['applied', 'rejected']);
  assert.equal(setDecision(s, t.id, 1, 'accepted'), false);
  assert.ok(hasUnsavedChanges(s));
});

test('全部拒绝时不能写入；拒绝整轮不改变草稿；撤销恢复快照', () => {
  const { app, s } = setup();
  const t = run(app, s, 'Netflix 走日本');
  setDecision(s, t.id, 0, 'rejected');
  assert.equal(applyTurn(s, t.id), false);
  assert.ok(rejectTurn(s, t.id));
  assert.equal(t.status, 'discarded');
  const next = run(app, s, 'Netflix 走日本');
  applyTurn(s, next.id);
  assert.ok(canUndo(s, next.id));
  assert.ok(undoTurn(s, next.id));
  assert.deepEqual(s.draft, SAMPLES.normal.rules);
});

test('@ 选择的完整出口名优先于地区推断，且多个同地区出口时仍可指定', () => {
  const { app, s } = setup();
  s.doc.groups.push({ name: '日本 备用', region: 'JP' });
  assert.equal(run(app, s, 'Netflix 走日本').status, 'failed');
  const t = run(app, s, '@Netflix 走 @日本 备用');
  assert.equal(t.status, 'pending');
  assert.ok(candidateRules(t).includes('DOMAIN-SUFFIX,netflix.com,日本 备用'));
  const direct = run(app, s, '@YouTube 走 @DIRECT');
  assert.ok(candidateRules(direct).every(r => !r.startsWith('DOMAIN-SUFFIX,youtube') || r.endsWith(',DIRECT')));
});

test('/ 与 @ 触发：识别光标前的记号，插入后光标落在补全之后', () => {
  const { s } = setup();
  const text = 'Netflix @日';
  const trigger = triggerAt(text, text.length);
  assert.deepEqual(trigger, { char: '@', query: '日', start: 8, end: 10 });
  const items = menuItems(s, trigger);
  assert.equal(items[0].label, '🇯🇵 日本 自动');
  const next = applyMenuItem(text, trigger, items[0]);
  assert.equal(next.text, 'Netflix 🇯🇵 日本 自动 ');
  assert.equal(next.caret, next.text.length);
  assert.equal(triggerAt('a@b', 3), null);
  assert.deepEqual(menuItems(s, triggerAt('/', 1)).map(i => i.label), ['路由', '直连', '屏蔽', '删除', '检查']);
});

test('域名测试：按顺序找到首条命中规则，跳过需要内核数据的规则', () => {
  const rules = SAMPLES.normal.rules;
  const netflix = matchDomain(rules, 'https://www.netflix.com/browse');
  assert.equal(netflix.index, 1);
  assert.equal(netflix.target, '香港 IPLC');
  const openai = matchDomain(rules, 'api.openai.com');
  assert.equal(openai.target, '🇺🇸 美国 流媒体');
  const other = matchDomain(rules, 'example.org');
  assert.equal(other.rule, 'MATCH,DIRECT');
  assert.deepEqual(other.skipped.map(s => s.rule), ['GEOSITE,cn,DIRECT', 'GEOIP,CN,DIRECT,no-resolve']);
  assert.ok(matchDomain(rules, 'not a domain').error);
  assert.equal(searchRules(rules, 'geo').length, 2);
});

test('会话：新建、切换、搜索、删除；忙碌时不能切换', () => {
  const { app, s } = setup();
  const second = createSession(app, 'long', 'url');
  assert.equal(activeSession(app), second);
  const t = startTurn(app, second, 'Netflix 走日本');
  assert.equal(switchSession(app, s.id), false);
  cancelTurn(second);
  assert.ok(switchSession(app, s.id));
  assert.equal(filterSessions(app, 'Netflix').length, 1);
  assert.equal(filterSessions(app, 'veer-demo').length, 2);
  assert.ok(deleteSession(app, s.id));
  assert.equal(app.activeId, second.id);
  assert.equal(t.status, 'cancelled');
});

test('持久化：会话 Key 不恢复，进行中的请求恢复为已取消', () => {
  const { app, s } = setup();
  app.mode = 'ai'; app.key = 'session';
  startTurn(app, s, 'Netflix 走日本');
  const restored = restore(serialize(app));
  assert.equal(restored.key, 'none');
  assert.equal(restored.mode, 'ai');
  assert.equal(restored.sessions[0].turns[0].status, 'cancelled');
  assert.equal(restored.sessions[0].busy, null);
  assert.deepEqual(restore('not json').sessions, []);
});

test('AI 澄清、校验失败阻止写入、未指定地区可更正', () => {
  const { app, s } = setup();
  app.mode = 'ai';
  assert.equal(canSend(app, s), false);
  app.key = 'saved';
  assert.equal(run(app, s, '节点太卡了').status, 'clarify');
  app.mode = 'local';
  const blocked = run(app, s, 'Netflix 走日本', 'validation-failed');
  assert.equal(blocked.status, 'blocked');
  assert.equal(applyTurn(s, blocked.id), false);
  assert.equal(unknownRegions(s).length, 1);
  const pending = run(app, s, 'Netflix 走日本');
  assert.ok(setRegion(s, 'Auto 优选', 'SG'));
  assert.equal(pending.status, 'superseded');
  assert.equal(run(app, s, 'YouTube 走新加坡').status, 'pending');
  const lines = diffRules(s.exported, s.draft);
  assert.equal(diffStats(lines).add, 0);
  markExported(s);
  assert.equal(hasUnsavedChanges(s), false);
});
