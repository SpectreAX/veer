import { createEditorServer } from './server.mjs';
import { stopValidationProcesses } from './core/validator.mjs';
import { stopKeyStoreProcesses } from './core/key-store.mjs';
import { fileURLToPath } from 'node:url';

// The parent owns stdin. EOF also shuts down after a parent crash; no token in argv/env/files.
let server, stopping = false, input = '';
async function stop(code = 0) {
  if (stopping) return;
  stopping = true;
  server?.closeAllConnections();
  server?.close();
  await Promise.all([stopValidationProcesses(), stopKeyStoreProcesses()]);
  process.exit(code);
}
process.stdin.on('end', () => void stop());
process.on('SIGTERM', () => void stop());
process.on('SIGINT', () => void stop());
const timer = setTimeout(() => void stop(1), 5000);
process.stdin.on('data', chunk => {
  if (server || stopping) return;
  input += chunk.toString();
  if (input.length > 1024) return void stop(1);
  if (!input.includes('\n')) return;
  clearTimeout(timer);
  let token;
  try { token = JSON.parse(input).token; } catch { return void stop(1); }
  input = '';
  if (!/^[a-fA-F0-9]{64}$/.test(token)) return void stop(1);
  server = createEditorServer({ authToken: token, binary: fileURLToPath(new URL('./bin/mihomo', import.meta.url)) });
  server.on('error', () => void stop(1));
  server.listen(0, '127.0.0.1', () => {
    if (!stopping) process.stdout.write(JSON.stringify({ protocol: 1, port: server.address().port }) + '\n');
  });
});
