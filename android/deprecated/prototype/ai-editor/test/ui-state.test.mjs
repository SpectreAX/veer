import test from 'node:test';
import assert from 'node:assert/strict';
import { readFile } from 'node:fs/promises';
import { runInNewContext } from 'node:vm';
import { inspectConfig } from '../core/editor.mjs';

const source = await readFile(new URL('../public/app.js', import.meta.url), 'utf8');
const sample = await readFile(new URL('../public/sample.yaml', import.meta.url), 'utf8');
const tick = () => new Promise(resolve => setImmediate(resolve));

function harness() {
  const elements = new Map(), requests = [];
  function element(id) {
    if (!elements.has(id)) elements.set(id, { value: '', disabled: false, hidden: false, dataset: {}, listeners: new Map(), addEventListener(type, fn) { this.listeners.set(type, fn); }, replaceChildren() {}, append() {}, focus() {}, dispatchEvent(event) { return this.listeners.get(event.type)?.({ ...event, target: this }); } });
    return elements.get(id);
  }
  const document = { getElementById: element, querySelectorAll: () => [], documentElement: { dataset: {} }, createElement: () => element(`created-${elements.size}`) };
  runInNewContext(source, { document, Option: function(text, value) { return { text, value }; }, Event: function(type) { return { type }; }, setTimeout, clearTimeout, fetch: (url, init) => new Promise(resolve => requests.push({ url, init, resolve })) });
  element('mode').value = 'local';
  return { element, requests };
}

test('配置解析在途时输入指令/切换模式，正确配置结果仍可用', async () => {
  const { element, requests } = harness();
  const file = element('file'); file.files = [{ name: 'config.yaml', size: sample.length, text: async () => sample }];
  const importing = file.dispatchEvent({ type: 'change' }); await tick();
  assert.equal(requests[0].url, '/api/inspect');
  element('prompt').value = 'Netflix 走日本'; element('prompt').dispatchEvent({ type: 'input' });
  element('mode').value = 'ai'; element('mode').dispatchEvent({ type: 'change' });
  requests[0].resolve(Response.json(inspectConfig(sample))); await importing;
  assert.equal(element('generate').disabled, false);
  assert.equal(element('export').disabled, false);
  assert.equal(element('validate').disabled, false);
});

test('生成期间改变指令，旧候选不能进入确认预览', async () => {
  const { element, requests } = harness();
  const file = element('file'); file.files = [{ name: 'config.yaml', size: sample.length, text: async () => sample }];
  const importing = file.dispatchEvent({ type: 'change' }); await tick();
  requests[0].resolve(Response.json(inspectConfig(sample))); await importing;
  element('prompt').value = 'Netflix 走日本'; element('prompt').dispatchEvent({ type: 'input' });
  const generating = element('generate').dispatchEvent({ type: 'click' });
  element('prompt').value = 'ChatGPT 走美国'; element('prompt').dispatchEvent({ type: 'input' });
  requests[1].resolve(Response.json({ candidate: 'stale candidate', changed: true })); await generating;
  assert.equal(element('review-content').hidden, true);
  assert.equal(element('yaml').value, sample);
  assert.match(element('status').textContent, /丢弃旧结果/);
  assert.equal(element('generate').disabled, false);
});

test('YAML textarea 保留原生键盘导航，不拦截 Tab', () => {
  const { element } = harness();
  for (const shiftKey of [false, true]) {
    let prevented = false;
    element('yaml').dispatchEvent({ type: 'keydown', key: 'Tab', shiftKey, preventDefault() { prevented = true; } });
    assert.equal(prevented, false);
  }
});
