import test from 'node:test';
import assert from 'node:assert/strict';
import { mkdtemp, writeFile, readFile, rm, readdir } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { validateCore, stopValidationProcesses } from '../core/validator.mjs';

test('关闭服务清理进行中的校验器，禁止退出期间新增子进程', async () => {
  const root = await mkdtemp(join(tmpdir(), 'veer-shutdown-test-'));
  const binary = join(root, 'validator'), marker = join(root, 'pid');
  try {
    await writeFile(binary, `#!${process.execPath}\nrequire('node:fs').writeFileSync(${JSON.stringify(marker)}, String(process.pid));process.stdin.resume();setInterval(() => {},1000);`, { mode: 0o700 });
    const pending = validateCore('rules: ["MATCH,DIRECT"]', binary);
    let pid;
    for (let i = 0; i < 100; i++) {
      try { pid = Number(await readFile(marker, 'utf8')); break; } catch {}
      await new Promise(resolve => setTimeout(resolve, 10));
    }
    assert(pid);
    const racing = validateCore('rules: ["MATCH,DIRECT"]', binary);
    await stopValidationProcesses();
    await pending;
    assert.equal((await racing).status, 'unavailable');
    assert.throws(() => process.kill(pid, 0));
    assert.equal((await validateCore('rules: ["MATCH,DIRECT"]', binary)).status, 'unavailable');
    assert.deepEqual((await readdir(root)).sort(), ['pid', 'validator']);
  } finally { await rm(root, { recursive: true, force: true }); }
});
