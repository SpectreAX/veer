import test from 'node:test';
import assert from 'node:assert/strict';
import { spawn } from 'node:child_process';
import { once } from 'node:events';
import { createInterface } from 'node:readline';
import { fileURLToPath } from 'node:url';

const entry = fileURLToPath(new URL('../native-host.mjs', import.meta.url));
const token = 'a'.repeat(64);
function child() {
  const process = spawn(globalThis.process.execPath, [entry], { env: { PATH: '/usr/bin:/bin', HOME: globalThis.process.env.HOME }, stdio: ['pipe', 'pipe', 'pipe'] });
  process.stderr.resume();
  return process;
}

test('原生宿主随机端口、认证隔离、stdin EOF 退出，第二次启动可用', async t => {
  for (let i = 0; i < 2; i++) {
    const process = child();
    t.after(() => { if (process.exitCode === null) process.kill(); });
    const lines = createInterface({ input: process.stdout });
    const ready = once(lines, 'line', { signal: AbortSignal.timeout(5000) });
    process.stdin.write(JSON.stringify({ token }) + '\n');
    const [line] = await ready, { protocol, port } = JSON.parse(line);
    assert.equal(protocol, 1); assert(port > 0 && port <= 65535);
    assert(!line.includes(token));
    const base = `http://127.0.0.1:${port}`;
    const post = (authorization, origin = base) => fetch(`${base}/api/document/import`, { method: 'POST', headers: { 'Content-Type': 'application/json', Origin: origin, ...(authorization ? { Authorization: authorization } : {}) }, body: JSON.stringify({ yaml: 'rules: ["MATCH,DIRECT"]' }) });
    assert.equal((await post()).status, 403);
    assert.equal((await post('Bearer wrong')).status, 403);
    assert.equal((await post(`Bearer ${token}`, 'https://example.invalid')).status, 403);
    assert.equal((await fetch(base)).status, 403);
    const imported = await post(`Bearer ${token}`);
    assert.equal(imported.status, 200);
    assert((await imported.json()).rules.includes('MATCH'));
    const closed = once(process, 'close', { signal: AbortSignal.timeout(5000) });
    process.stdin.end();
    assert.equal((await closed)[0], 0);
    lines.close();
    await assert.rejects(() => fetch(base));
  }
});

test('无效或超长宿主握手拒绝启动，不回显输入', async () => {
  for (const input of ['{"token":"bad"}\n', 'x'.repeat(1025)]) {
    const process = child();
    let output = ''; process.stdout.on('data', bytes => output += bytes);
    const closed = once(process, 'close', { signal: AbortSignal.timeout(5000) });
    process.stdin.write(input);
    assert.equal((await closed)[0], 1);
    assert.equal(output, '');
  }
});
