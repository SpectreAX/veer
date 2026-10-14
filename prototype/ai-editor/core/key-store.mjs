import { spawn } from 'node:child_process';
import { createHash } from 'node:crypto';
import { EditorError } from './editor.mjs';

const SERVICE = 'com.yamax.veer.ai-editor.api-key';
export function keyAccount(baseUrl) {
  let url;
  try { url = new URL(baseUrl); } catch { throw new EditorError('API 地址无效，无法保存 Key。'); }
  if (url.username || url.password || url.search || url.hash || (url.protocol !== 'https:' && !(url.protocol === 'http:' && ['localhost', '127.0.0.1', '[::1]'].includes(url.hostname)))) throw new EditorError('保存 Key 需要有效的 HTTPS 或本机 API 地址。');
  return createHash('sha256').update(url.toString().replace(/\/+$/, '')).digest('hex');
}

function security(args, input) {
  return new Promise((resolve, reject) => {
    const child = spawn('/usr/bin/security', args, { stdio: ['pipe', 'pipe', 'pipe'] });
    let output = '', failed = false;
    const timeout = setTimeout(() => { failed = true; child.kill('SIGKILL'); }, 15000);
    child.stdout.on('data', chunk => { output += chunk; if (output.length > 20000) { failed = true; child.kill('SIGKILL'); } });
    // Never include subprocess diagnostics: they may contain credential data.
    child.stderr.resume(); child.stdin.on('error', () => {});
    child.on('error', () => { clearTimeout(timeout); reject(new EditorError('无法访问 macOS 钥匙串。')); });
    child.on('close', code => { clearTimeout(timeout); if (failed) reject(new EditorError('钥匙串访问超时，请解锁钥匙串后重试。')); else resolve({ code, output }); });
    child.stdin.end(input);
  });
}

export function createKeyStore({ platform = process.platform, run = security, service = SERVICE } = {}) {
  const check = () => { if (platform !== 'darwin') throw new EditorError('当前仅支持 macOS 钥匙串保存；其他系统请使用会话 Key。'); };
  return {
    async get(baseUrl) {
      check(); const result = await run(['find-generic-password', '-s', service, '-a', keyAccount(baseUrl), '-w']);
      if (result.code === 44) return null;
      if (result.code !== 0) throw new EditorError('钥匙串读取失败，请解锁并允许访问后重试。');
      return result.output.replace(/\r?\n$/, '');
    },
    async status(baseUrl) {
      check(); const result = await run(['find-generic-password', '-s', service, '-a', keyAccount(baseUrl)]);
      if (![0, 44].includes(result.code)) throw new EditorError('无法检查已保存 Key，请解锁钥匙串后重试。');
      return result.code === 0;
    },
    async save(baseUrl, key) {
      check(); if (typeof key !== 'string' || !key.trim() || key.length > 4096 || /[\x00-\x20\x7f]/.test(key) || /^(?:[<\[]redacted[>\]]|[•●*]+)$/i.test(key)) throw new EditorError('请输入真实 API Key，不能使用隐藏占位值、空格或控制字符。');
      const account = keyAccount(baseUrl);
      // Interactive stdin keeps credentials out of process argv; hex avoids command injection.
      const result = await run(['-i'], `add-generic-password -U -s ${service} -a ${account} -l "Veer AI API Key" -X ${Buffer.from(key).toString('hex')}\n`);
      if (result.code !== 0 || await this.get(baseUrl) !== key) throw new EditorError('Key 未成功保存到钥匙串，请检查访问权限。');
    },
    async remove(baseUrl) {
      check(); const result = await run(['delete-generic-password', '-s', service, '-a', keyAccount(baseUrl)]);
      if (![0, 44].includes(result.code)) throw new EditorError('无法删除已保存 Key，请检查钥匙串权限。');
    },
  };
}
