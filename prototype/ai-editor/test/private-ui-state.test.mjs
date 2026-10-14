import test from 'node:test';
import assert from 'node:assert/strict';
import { readFile } from 'node:fs/promises';
import { runInNewContext } from 'node:vm';
const source = await readFile(new URL('../public/private.js', import.meta.url), 'utf8');
const tick = () => new Promise(resolve => setImmediate(resolve));
function harness() {
  const elements = new Map(), requests = [];
  const element = id => {
    if (!elements.has(id)) elements.set(id, { value: '', dataset: {}, listeners: new Map(), addEventListener(type, fn) { this.listeners.set(type, fn); }, replaceChildren() {}, append() {}, setAttribute() {}, focus() {}, dispatch(event) { return this.listeners.get(event.type)?.({ ...event, target: this }); } });
    return elements.get(id);
  };
  element('rules').value = 'rules: []\n'; element('mode').value = 'local';
  const document = { getElementById: element, querySelectorAll: () => [], documentElement: { dataset: {} }, createElement: () => element(`generated-${elements.size}`) };
  runInNewContext(source, { document, setTimeout, clearTimeout, fetch: (url, init) => new Promise(resolve => requests.push({ url, input: JSON.parse(init.body), resolve })) });
  return { element, requests };
}
test('安全模式输入指令不会使在途规则检查失效；旧生成结果不能确认', async () => {
  const { element, requests } = harness();
  element('prompt').value = 'example.com 直连'; element('prompt').dispatch({ type: 'input' });
  requests[0].resolve(Response.json({ count: 0 })); await tick();
  assert.equal(element('generate').disabled, false);
  const generating = element('generate').dispatch({ type: 'click' });
  element('prompt').value = 'example.com 屏蔽'; element('prompt').dispatch({ type: 'input' });
  requests[1].resolve(Response.json({ candidate: 'invalid stale' })); await generating;
  assert.equal(element('review-content').hidden, true);
  assert.equal(element('rules').value, 'rules: []\n');
  assert.match(element('status').textContent, /旧结果已丢弃/);
});
test('安全模式只请求独立接口，检查失败禁止生成和导出', async () => {
  const { element, requests } = harness();
  assert.equal(requests[0].url, '/api/private/inspect');
  assert.deepEqual(Object.keys(requests[0].input).sort(), ['groups', 'rules']);
  requests[0].resolve(Response.json({ error: '只允许 rules' }, { status: 422 })); await tick();
  assert.equal(element('generate').disabled, true);
  assert.equal(element('export').disabled, true);
  for (const shiftKey of [false, true]) {
    let prevented = false;
    element('rules').dispatch({ type: 'keydown', key: 'Tab', shiftKey, preventDefault() { prevented = true; } });
    assert.equal(prevented, false);
  }
});
