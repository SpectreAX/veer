import test from 'node:test';
import assert from 'node:assert/strict';
import { readFile } from 'node:fs/promises';
import { runInNewContext } from 'node:vm';
const source = await readFile(new URL('../public/key-settings.js', import.meta.url), 'utf8');
const tick = () => new Promise(resolve => setImmediate(resolve));
function harness() {
  const elements = new Map(), requests = [];
  const element = id => {
    if (!elements.has(id)) elements.set(id, { value: '', dataset: {}, listeners: new Map(), addEventListener(type, fn) { this.listeners.set(type, fn); }, dispatch(type) { return this.listeners.get(type)?.(); } });
    return elements.get(id);
  };
  element('base-url').value = 'https://api.example.com';
  runInNewContext(source, { document: { getElementById: element }, setTimeout: () => 0, clearTimeout() {}, fetch: (url, init) => new Promise(resolve => requests.push({ url, input: JSON.parse(init.body), resolve })) });
  return { element, requests };
}
test('刷新恢复已保存状态而非秘密；改变地址立即清空会话 Key并忽略旧状态', async () => {
  const { element, requests } = harness();
  requests[0].resolve(Response.json({ saved: true })); await tick();
  assert.equal(element('api-key').dataset.saved, 'true');
  assert.equal(element('api-key').value, '');
  element('api-key').value = 'test-session-key';
  element('base-url').value = 'https://other.example'; element('base-url').dispatch('input');
  assert.equal(element('api-key').value, ''); assert.equal(element('api-key').dataset.saved, 'false');
  const restoring = element('base-url').dispatch('change');
  element('base-url').value = 'https://third.example'; element('base-url').dispatch('input');
  requests[1].resolve(Response.json({ saved: true })); await restoring;
  assert.equal(element('api-key').dataset.saved, 'false');
});
test('保存后清除输入，保存失败不丢失输入且按钮可重试', async () => {
  const { element, requests } = harness();
  requests[0].resolve(Response.json({ saved: false })); await tick();
  element('api-key').value = 'test-only'; element('api-key').dispatch('input');
  const saving = element('save-key').dispatch('click');
  requests[1].resolve(Response.json({ error: '钥匙串锁定' }, { status: 422 })); await saving;
  assert.equal(element('api-key').value, 'test-only'); assert.equal(element('save-key').disabled, false);
  const retry = element('save-key').dispatch('click');
  requests[2].resolve(Response.json({ saved: true })); await retry;
  assert.equal(element('api-key').value, ''); assert.equal(element('api-key').dataset.saved, 'true');
});
