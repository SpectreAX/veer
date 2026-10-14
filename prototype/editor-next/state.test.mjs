import assert from 'node:assert/strict';
import { test } from 'node:test';
import {
  initialState, importDocument, setRegion, unknownRegions, hasUnsavedChanges, canSend, startTurn, completeTurn,
  cancelTurn, confirmTurn, discardTurn, undoTurn, canUndo, diffRules, diffStats, markExported, parsePrompt, SAMPLES,
} from './state.mjs';

const ready = () => { const s = initialState(); importDocument(s); return s; };
const run = (s, prompt, scenario) => { const t = startTurn(s, prompt); completeTurn(s, t.id, scenario); return t; };

test('候选不改变草稿；确认、撤销只作用于栈顶', () => {
  const s = ready();
  const t = run(s, 'Netflix 走日本，ChatGPT 走美国');
  assert.equal(t.status, 'pending');
  assert.deepEqual(s.draft, SAMPLES.normal.rules);
  assert.ok(confirmTurn(s, t.id));
  assert.equal(s.draft.filter(r => r.endsWith('🇯🇵 日本 自动')).length, 6);
  assert.ok(hasUnsavedChanges(s));
  assert.equal(confirmTurn(s, t.id), false);
  assert.ok(undoTurn(s, t.id));
  assert.deepEqual(s.draft, SAMPLES.normal.rules);
});

test('大小写不同的已有规则被替换而非重复，删除生成移除行', () => {
  const s = ready();
  const t = run(s, 'Netflix 走日本');
  assert.deepEqual(t.changes[0].before, ['DOMAIN-SUFFIX,Netflix.com,香港 IPLC']);
  assert.equal(t.after.filter(r => /netflix\.com,/i.test(r)).length, 1);
  confirmTurn(s, t.id);
  const removal = run(s, '删除 Netflix 规则');
  assert.equal(removal.status, 'pending');
  assert.equal(diffStats(diffRules(removal.before, removal.after)).remove, 6);
});

test('服务名与域名同时出现时每个域名只生成一条规则', () => {
  const s = ready();
  const t = run(s, 'netflix.com 走日本');
  assert.equal(t.after.filter(r => r.startsWith('DOMAIN-SUFFIX,netflix.com,')).length, 1);
});

test('校验失败的候选被阻止；校验器不可用仍可确认但如实说明', () => {
  const s = ready();
  const blocked = run(s, 'Netflix 走日本', 'validation-failed');
  assert.equal(blocked.status, 'blocked');
  assert.equal(confirmTurn(s, blocked.id), false);
  const unverified = run(s, 'Netflix 走日本', 'validator-unavailable');
  assert.equal(unverified.status, 'pending');
  assert.equal(unverified.validation.status, 'unavailable');
});

test('本地模式拒绝模糊指令；AI 模式改为澄清，均不生成候选', () => {
  for (const mode of ['local', 'ai']) {
    const s = ready(); s.mode = mode; s.key = 'saved';
    const t = run(s, '节点太卡了');
    assert.equal(t.status, mode === 'ai' ? 'clarify' : 'failed');
    assert.deepEqual(t.changes, []);
    assert.equal(confirmTurn(s, t.id), false);
  }
});

test('AI 模式没有 Key 或服务不可用时不能发送', () => {
  const s = ready(); s.mode = 'ai';
  assert.equal(canSend(s), false);
  s.key = 'session';
  assert.equal(canSend(s), true);
  s.service = 'unavailable';
  assert.equal(startTurn(s, 'Netflix 走日本'), null);
});

test('更正未指定地区后可路由，并使旧候选失效', () => {
  const s = ready();
  assert.equal(unknownRegions(s).length, 1);
  assert.equal(run(s, 'YouTube 走新加坡').status, 'failed');
  const old = run(s, 'Netflix 走日本');
  assert.ok(setRegion(s, 'Auto 优选', 'SG'));
  assert.equal(old.status, 'superseded');
  const t = run(s, 'YouTube 走新加坡');
  assert.ok(t.after.every(r => !r.startsWith('DOMAIN-SUFFIX,youtube') || r.endsWith(',Auto 优选')));
});

test('取消后迟到结果被忽略；放弃不改变草稿；导出清除未保存标记', () => {
  const s = ready();
  const t = startTurn(s, 'Netflix 走日本');
  cancelTurn(s); completeTurn(s, t.id);
  assert.equal(t.status, 'cancelled');
  const next = run(s, 'Netflix 走日本');
  assert.ok(discardTurn(s, next.id));
  assert.deepEqual(s.draft, SAMPLES.normal.rules);
  const kept = run(s, 'ChatGPT 直连');
  confirmTurn(s, kept.id);
  assert.ok(canUndo(s, kept.id));
  markExported(s);
  assert.equal(hasUnsavedChanges(s), false);
});

test('多个同地区出口时要求指定完整名称', () => {
  const groups = [{ name: 'A', region: 'JP' }, { name: 'B', region: 'JP' }];
  assert.match(parsePrompt('Netflix 走日本', groups, 'local').error, /多个日本出口/);
});
