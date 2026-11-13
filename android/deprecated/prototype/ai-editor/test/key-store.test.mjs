import test from 'node:test';
import assert from 'node:assert/strict';
import { createKeyStore, keyAccount } from '../core/key-store.mjs';
import { createEditorServer } from '../server.mjs';

test('钥匙串地址规范化隔离，保存使用 stdin 而非 argv，错误不输出秘密', async () => {
  assert.equal(keyAccount('https://api.example.com/'), keyAccount('https://api.example.com'));
  assert.notEqual(keyAccount('https://api.example.com'), keyAccount('https://api.example.com/v1'));
  assert.throws(() => keyAccount('http://external.example.com'));
  assert.throws(() => keyAccount('https://user:secret@example.com'));
  const secret = 'test-only-not-real', calls = [];
  const store = createKeyStore({ platform: 'darwin', run: async (args, input) => {
    calls.push({ args, input });
    return { code: 0, output: args.includes('-w') ? `${secret}\n` : '' };
  } });
  await store.save('https://api.example.com', secret);
  assert(!JSON.stringify(calls[0].args).includes(secret));
  assert(calls[0].input.includes(Buffer.from(secret).toString('hex')));
  assert(!calls[0].input.includes('-A'));
  await assert.rejects(() => store.save('https://api.example.com', 'key\nquit'), /控制字符/);
  await assert.rejects(() => store.save('https://api.example.com', '<redacted>'), /占位/);
  const denied = createKeyStore({ platform: 'darwin', run: async () => ({ code: 1, output: secret }) });
  await assert.rejects(() => denied.get('https://api.example.com'), error => !error.message.includes(secret));
  assert.equal(await createKeyStore({ platform: 'darwin', run: async () => ({ code: 44 }) }).get('https://api.example.com'), null);
  await assert.rejects(() => createKeyStore({ platform: 'linux' }).save('https://api.example.com', secret), /macOS/);
});

test('HTTP 保存状态不返回 Key；重建服务后可调用已保存 Key；来源隔离', async t => {
  const entries = new Map();
  const keyStore = { status: async url => entries.has(keyAccount(url)), get: async url => entries.get(keyAccount(url)), save: async (url, key) => entries.set(keyAccount(url), key), remove: async url => entries.delete(keyAccount(url)) };
  const create = async () => {
    const server = createEditorServer({ binary: '/missing', keyStore, aiResolver: async (_prompt, _targets, settings) => {
      assert.equal(settings.apiKey, 'test-only-not-real');
      return { schemaVersion: 1, operations: [{ kind: 'route', matchType: 'DOMAIN-SUFFIX', match: 'example.com', targetId: 'target-0' }] };
    } });
    await new Promise(resolve => server.listen(0, '127.0.0.1', resolve));
    return server;
  };
  let server = await create();
  const post = (path, input, origin = true) => { const base = `http://127.0.0.1:${server.address().port}`; return fetch(`${base}/api/${path}`, { method: 'POST', headers: { 'Content-Type': 'application/json', ...(origin ? { Origin: base } : {}) }, body: JSON.stringify(input) }); };
  const baseUrl = 'https://api.example.com';
  assert.equal((await post('key/save', { baseUrl, apiKey: 'test-only-not-real' }, false)).status, 403);
  assert.deepEqual(await (await post('key/save', { baseUrl, apiKey: 'test-only-not-real' })).json(), { saved: true });
  await new Promise(resolve => server.close(resolve)); server = await create();
  t.after(() => new Promise(resolve => server.close(resolve)));
  assert.deepEqual(await (await post('key/status', { baseUrl })).json(), { saved: true });
  const payload = { groups: [], rules: 'rules: []', prompt: 'example.com 直连', mode: 'ai', settings: { baseUrl, model: 'model', apiKey: '', useSavedKey: true } };
  assert.equal((await post('private/plan', payload)).status, 200);
  assert.equal((await post('private/plan', { ...payload, settings: { ...payload.settings, baseUrl: 'https://other.example' } })).status, 422);
  assert.deepEqual(await (await post('key/remove', { baseUrl })).json(), { saved: false });
  assert.equal((await post('private/plan', payload)).status, 422);
});

test('旧版页面首次 AI 调用迁移会话 Key，新版显式会话请求不自动保存', async t => {
  if (process.platform !== 'darwin') { t.skip('旧页钥匙串迁移仅用于 macOS'); return; }
  const saves = [];
  const server = createEditorServer({ binary: '/missing', saveLegacySessionKeys: true, keyStore: { save: async (url, key) => saves.push({ url, key }) }, aiResolver: async () => ({ schemaVersion: 1, operations: [{ kind: 'route', matchType: 'DOMAIN-SUFFIX', match: 'example.com', targetId: 'target-0' }] }) });
  await new Promise(resolve => server.listen(0, '127.0.0.1', resolve));
  t.after(() => new Promise(resolve => server.close(resolve)));
  const payload = { groups: [], rules: 'rules: []', prompt: 'example.com 直连', mode: 'ai', settings: { apiKey: 'test-only', baseUrl: 'https://api.example.com', model: 'test-model' } };
  const post = data => fetch(`http://127.0.0.1:${server.address().port}/api/private/plan`, { method: 'POST', headers: { 'Content-Type': 'application/json' }, body: JSON.stringify(data) });
  assert.equal((await post(payload)).status, 200);
  assert.deepEqual(saves, [{ url: 'https://api.example.com', key: 'test-only' }]);
  assert.equal((await post({ ...payload, settings: { ...payload.settings, useSavedKey: false } })).status, 200);
  assert.equal(saves.length, 1);
});
