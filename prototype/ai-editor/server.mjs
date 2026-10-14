import { createServer } from 'node:http';
import { readFile } from 'node:fs/promises';
import { fileURLToPath } from 'node:url';
import { resolve, join } from 'node:path';
import { EditorError, inspectConfig, readConfig, applyPlan, resolveLocal, MAX_CONFIG_BYTES } from './core/editor.mjs';
import { resolveAi } from './core/llm.mjs';
import { validateCore } from './core/validator.mjs';
import { readPrivateInput, anonymizePrompt, applyPrivatePlan, resolvePrivateLocal } from './core/private-editor.mjs';
import { createKeyStore } from './core/key-store.mjs';
import { openDocument, documentContext, applyDocumentPlan } from './core/document.mjs';
import { stringify } from 'yaml';

const root = fileURLToPath(new URL('.', import.meta.url));
const assets = new Map([['/', ['private.html', 'text/html']], ['/private', ['private.html', 'text/html']], ['/private.js', ['private.js', 'text/javascript']], ['/advanced', ['index.html', 'text/html']], ['/app.js', ['app.js', 'text/javascript']], ['/style.css', ['style.css', 'text/css']], ['/sample.yaml', ['sample.yaml', 'text/yaml']]]);
assets.set('/key-settings.js', ['key-settings.js', 'text/javascript']);

function send(res, status, data) {
  res.writeHead(status, { 'Content-Type': 'application/json; charset=utf-8' });
  res.end(JSON.stringify(data));
}

async function body(req) {
  let size = 0; const chunks = [];
  for await (const chunk of req) {
    size += chunk.length;
    if (size > MAX_CONFIG_BYTES * 2 + 100000) throw new EditorError('请求内容超过大小限制。');
    chunks.push(chunk);
  }
  try { return JSON.parse(Buffer.concat(chunks).toString()); } catch { throw new EditorError('请求格式无效。'); }
}

export function createEditorServer({ binary = process.env.MIHOMO_BIN || join(root, '.cache/mihomo'), aiResolver = resolveAi, keyStore = createKeyStore(), saveLegacySessionKeys = false, authToken } = {}) {
  return createServer(async (req, res) => {
    res.setHeader('Cache-Control', 'no-store');
    res.setHeader('X-Content-Type-Options', 'nosniff');
    res.setHeader('Content-Security-Policy', "default-src 'self'; script-src 'self'; style-src 'self'; connect-src 'self'; img-src 'self' data:; base-uri 'none'; frame-ancestors 'none'; form-action 'none'");
    try {
      const port = req.socket.localPort;
      const validHosts = [`127.0.0.1:${port}`, `localhost:${port}`];
      if (!validHosts.includes(req.headers.host)) return send(res, 403, { error: '仅允许本机访问。' });
      if (authToken && req.headers.authorization !== `Bearer ${authToken}`) return send(res, 403, { error: '本机编辑服务认证失败。请重新启动应用。' });
      const path = new URL(req.url, `http://${req.headers.host}`).pathname;
      if (req.method === 'GET' && assets.has(path)) {
        const [file, type] = assets.get(path);
        res.writeHead(200, { 'Content-Type': `${type}; charset=utf-8` });
        res.end(await readFile(join(root, 'public', file))); return;
      }
      if (req.method !== 'POST' || !path.startsWith('/api/')) return send(res, 404, { error: '页面不存在。' });
      if (!req.headers['content-type']?.startsWith('application/json') || (req.headers.origin && req.headers.origin !== `http://${req.headers.host}`)) return send(res, 403, { error: '请求来源无效，请从编辑器页面操作。' });
      const input = await body(req);
      if (!input || typeof input !== 'object') throw new EditorError('请求格式无效。');
      if (path.startsWith('/api/key/')) {
        if (req.headers.origin !== `http://${req.headers.host}`) return send(res, 403, { error: '钥匙串操作须从编辑器页面发起。' });
        if (path === '/api/key/status') return send(res, 200, { saved: await keyStore.status(input.baseUrl) });
        if (path === '/api/key/save') { await keyStore.save(input.baseUrl, input.apiKey); return send(res, 200, { saved: true }); }
        if (path === '/api/key/remove') { await keyStore.remove(input.baseUrl); return send(res, 200, { saved: false }); }
        return send(res, 404, { error: '接口不存在。' });
      }
      if (path.startsWith('/api/private/')) {
        if (Object.keys(input).some(k => !['groups', 'rules', 'prompt', 'mode', 'settings'].includes(k))) throw new EditorError('独立规则接口不接收完整配置或节点字段。');
        const draft = { groups: input.groups, rules: input.rules };
        const context = readPrivateInput(draft);
        if (path === '/api/private/inspect') return send(res, 200, { count: context.rules.length });
        if (path === '/api/private/validate') {
          const validation = await validateCore(context.synthetic, binary);
          return send(res, 200, privateValidation(validation));
        }
        if (path !== '/api/private/plan') return send(res, 404, { error: '接口不存在。' });
        if (typeof input.prompt !== 'string' || !input.prompt.trim() || input.prompt.length > 8000 || !['local', 'ai'].includes(input.mode)) throw new EditorError('请填写有效指令并选择解析模式。');
        const prompt = anonymizePrompt(input.prompt, context.targets, context.anonymousTargets);
        const plan = input.mode === 'ai' ? await aiResolver(prompt, context.anonymousTargets, await aiSettings(input.settings, keyStore, saveLegacySessionKeys)) : resolvePrivateLocal(input.prompt, context);
        const { synthetic, ...result } = applyPrivatePlan(draft, plan);
        const validation = privateValidation(await validateCore(synthetic, binary));
        return send(res, 200, { ...result, validation, mode: input.mode });
      }
      if (path.startsWith('/api/document/')) {
        if (req.headers.origin !== `http://${req.headers.host}`) return send(res, 403, { error: '配置操作仅允许从本机编辑器发起。' });
        if (path === '/api/document/import') return send(res, 200, openDocument(input.yaml));
        const context = documentContext(input);
        const validation = { status: 'unavailable', message: '规则 YAML 与修改范围检查通过；完整配置尚未经过 Mihomo 语义校验，导出后请由代理客户端检查。' };
        if (path === '/api/document/inspect') return send(res, 200, { count: context.config.rules?.length ?? 0 });
        if (path === '/api/document/validate') return send(res, 200, validation);
        if (path === '/api/document/export') return send(res, 200, { yaml: context.yaml });
        if (path !== '/api/document/plan') return send(res, 404, { error: '接口不存在。' });
        if (typeof input.prompt !== 'string' || !input.prompt.trim() || input.prompt.length > 8000 || !['local', 'ai'].includes(input.mode)) throw new EditorError('请填写有效指令并选择解析模式。');
        const prompt = anonymizePrompt(input.prompt, context.targets, context.anonymousTargets);
        const plan = input.mode === 'ai' ? await aiResolver(prompt, context.anonymousTargets, await aiSettings(input.settings, keyStore, false)) : resolveLocal(prompt, context.anonymousTargets);
        const result = applyDocumentPlan(input, context, plan);
        // Test only changed rules against placeholders. Never load real providers or secrets into a running core.
        const synthetic = stringify({ 'proxy-groups': context.targets.filter(t => t.kind !== 'builtin').map(t => ({ name: t.name, type: 'select', proxies: ['DIRECT'] })), rules: result.summaries.flatMap(s => s.after ? [s.after] : []) });
        const checked = await validateCore(synthetic, binary);
        return send(res, 200, { ...result, validation: { ...checked, message: `${checked.message} 此检查仅覆盖修改规则的占位出口，不验证原配置、Provider 或实际网络。` } });
      }
      if (path === '/api/inspect') return send(res, 200, inspectConfig(input.yaml));
      if (path === '/api/validate') return send(res, 200, await validateCore(input.yaml, binary));
      if (path !== '/api/plan') return send(res, 404, { error: '接口不存在。' });
      if (typeof input.prompt !== 'string' || !input.prompt.trim() || input.prompt.length > 8000) throw new EditorError('指令须为 1–8000 个字符。');
      const { targets } = readConfig(input.yaml);
      if (!['local', 'ai'].includes(input.mode)) throw new EditorError('请选择本地解析或 AI 模式。');
      const plan = input.mode === 'ai' ? await aiResolver(input.prompt, targets, await aiSettings(input.settings, keyStore, saveLegacySessionKeys)) : resolveLocal(input.prompt, targets);
      const result = applyPlan(input.yaml, plan);
      const validation = await validateCore(result.candidate, binary);
      send(res, 200, { ...result, validation, mode: input.mode });
    } catch (error) {
      send(res, error instanceof EditorError ? 422 : 500, { error: error instanceof EditorError ? error.message : '编辑器处理失败，请检查配置后重试。' });
    }
  });
}

async function aiSettings(settings, keyStore, saveLegacySessionKeys) {
  if (!settings || typeof settings !== 'object') return settings;
  // Older open pages lack save controls: migrate on their next AI request, never read the password DOM.
  if (saveLegacySessionKeys && settings.useSavedKey === undefined && settings.apiKey && process.platform === 'darwin') await keyStore.save(settings.baseUrl, settings.apiKey);
  if (!settings.apiKey && settings.useSavedKey === true) {
    const key = await keyStore.get(settings.baseUrl);
    if (!key) throw new EditorError('此 API 地址没有已保存 Key，请重新填写。');
    return { baseUrl: settings.baseUrl, model: settings.model, apiKey: key };
  }
  return settings;
}

function privateValidation(result) {
  return { ...result, message: `${result.status === 'passed' ? '规则已通过占位策略组的 Mihomo 测试。' : result.message} 未读取真实节点；真实组名、网络及合并顺序须由代理客户端验证。` };
}

if (process.argv[1] && resolve(process.argv[1]) === fileURLToPath(import.meta.url)) {
  const port = Number(process.env.VEER_EDITOR_PORT || 4317);
  const server = createEditorServer({ saveLegacySessionKeys: true });
  server.on('error', error => { console.error(error.code === 'EADDRINUSE' ? `端口 ${port} 已被占用。可设置 VEER_EDITOR_PORT。` : '编辑器无法启动。'); process.exitCode = 1; });
  server.listen(port, '127.0.0.1', () => console.log(`Veer AI Editor: http://127.0.0.1:${port}`));
}
