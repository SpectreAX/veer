import { access, mkdtemp, rm } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { spawn } from 'node:child_process';
import { readConfig } from './editor.mjs';

const active = new Set();
const jobs = new Set();
let stopping = false;
export async function stopValidationProcesses() {
  stopping = true;
  await Promise.all([...active].map(child => new Promise(resolve => {
    if (child.exitCode !== null || child.signalCode !== null) return resolve();
    child.once('close', resolve);
    child.kill('SIGKILL');
  })));
  await Promise.allSettled([...jobs]);
}

export async function validateCore(yaml, binary) {
  const job = runValidation(yaml, binary);
  jobs.add(job);
  try { return await job; } finally { jobs.delete(job); }
}

async function runValidation(yaml, binary) {
  const { config } = readConfig(yaml);
  try { if (!binary) throw new Error(); await access(binary); }
  catch { return { status: 'unavailable', message: '已通过编辑器结构检查；未配置 Mihomo 校验器，尚未通过内核语义校验。' }; }
  const dir = await mkdtemp(join(tmpdir(), 'veer-editor-'));
  try {
    const result = await new Promise(resolve => {
      if (stopping) return resolve({ status: 'unavailable', message: '编辑服务正在退出，校验已取消。' });
      const child = spawn(binary, ['-t', '-d', dir, '-f', '-'], { env: { PATH: process.env.PATH, HOME: dir, TMPDIR: dir }, stdio: ['pipe', 'pipe', 'pipe'] });
      active.add(child);
      child.once('close', () => active.delete(child));
      let output = '', timedOut = false;
      const timer = setTimeout(() => { timedOut = true; child.kill('SIGKILL'); }, 20000);
      const collect = chunk => { output = (output + chunk.toString()).slice(-12000); };
      child.stdout.on('data', collect); child.stderr.on('data', collect);
      child.stdin.on('error', () => {});
      child.on('error', () => { clearTimeout(timer); resolve({ status: 'unavailable', message: '无法运行 Mihomo 校验器，请检查 MIHOMO_BIN。' }); });
      child.on('close', code => {
        clearTimeout(timer);
        if (timedOut) return resolve({ status: 'failed', message: '内核校验超过 20 秒。请检查 GEO/Provider 等资源依赖。' });
        if (code === 0) return resolve({ status: 'passed', message: '已通过 Mihomo 配置测试。网络可达性与服务解锁尚未验证。' });
        const secrets = [];
        const visited = new WeakSet();
        const walk = value => {
          if (!value || typeof value !== 'object' || visited.has(value)) return;
          visited.add(value);
          for (const [key, item] of Object.entries(value)) {
            if (/password|token|secret|uuid|private.?key|authorization|url|server/i.test(key) && typeof item === 'string' && item.length > 2) secrets.push(item);
            else walk(item);
          }
        };
        walk(config);
        for (const secret of secrets.sort((a, b) => b.length - a.length)) output = output.split(secret).join('[已隐藏]');
        output = output.replaceAll(dir, '[临时目录]').replace(/\x1b\[[0-9;]*m/g, '');
        resolve({ status: 'failed', message: `Mihomo 校验失败：${output.trim().slice(-1500) || '未返回错误说明。'}` });
      });
      child.stdin.end(yaml);
    });
    return result;
  } finally { await rm(dir, { recursive: true, force: true }); }
}
