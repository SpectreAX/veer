import { createServer } from 'node:http';
import { spawn } from 'node:child_process';
import { fileURLToPath } from 'node:url';
import { createEditorServer } from '../../../prototype/ai-editor/server.mjs';

const core = createEditorServer();
const fixture = createServer(async (req, res) => {
  let body = '';
  for await (const chunk of req) body += chunk;
  const rules = JSON.parse(body || '{}').rules;
  if (rules === 'redirect-test') { res.writeHead(307, { Location: '/unexpected-redirect' }); res.end(); }
  else if (rules === 'oversized-test') { res.writeHead(200); res.end('x'.repeat(1024 * 1024 + 1)); }
  else if (rules === 'invalid-json-test') { res.writeHead(200); res.end('private-upstream-body'); }
  else { res.writeHead(200, { 'Content-Type': 'application/json' }); res.end('{"count":0}'); }
});
try {
  await Promise.all([core, fixture].map(server => new Promise(resolve => server.listen(0, '127.0.0.1', resolve))));
  const child = spawn('swift', ['test'], {
    cwd: fileURLToPath(new URL('..', import.meta.url)), stdio: 'inherit',
    env: { ...process.env, VEER_TEST_PORT: String(core.address().port), VEER_FIXTURE_PORT: String(fixture.address().port) },
  });
  process.exitCode = await new Promise((resolve, reject) => { child.on('error', reject); child.on('exit', code => resolve(code ?? 1)); });
} finally { await Promise.all([core, fixture].map(server => new Promise(resolve => server.close(resolve)))); }
