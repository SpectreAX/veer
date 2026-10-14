import { EditorError, buildSystemPrompt } from './editor.mjs';

export async function resolveAi(prompt, targets, settings, fetchImpl = fetch) {
  if (typeof settings?.apiKey !== 'string' || !settings.apiKey.trim()) throw new EditorError('请输入 AI API Key。Key 只用于本次请求。');
  if (typeof settings.model !== 'string' || !settings.model.trim()) throw new EditorError('请输入模型名称。');
  if (targets.length > 2500) throw new EditorError('出口数量超过原型的 AI 上下文限制（2500 个），请先缩小配置。');
  let url;
  try { url = new URL(settings.baseUrl); } catch { throw new EditorError('AI API 地址无效。'); }
  const local = ['localhost', '127.0.0.1', '[::1]'].includes(url.hostname);
  if ((url.protocol !== 'https:' && !(url.protocol === 'http:' && local)) || url.username || url.password || url.search || url.hash) throw new EditorError('API 地址须为 HTTPS，或本机 HTTP 地址；不能包含凭证或查询参数。');
  url.pathname = `${url.pathname.replace(/\/$/, '')}/chat/completions`;
  let response;
  try {
    response = await fetchImpl(url, {
      method: 'POST', redirect: 'error', signal: AbortSignal.timeout(60000),
      headers: { 'Content-Type': 'application/json', Authorization: `Bearer ${settings.apiKey}` },
      body: JSON.stringify({ model: settings.model, temperature: 0, stream: false, response_format: { type: 'json_object' }, messages: [{ role: 'system', content: buildSystemPrompt(targets) }, { role: 'user', content: prompt }] }),
    });
  } catch { throw new EditorError('无法连接 AI 服务或请求超时，请检查 API 地址与网络。'); }
  if (!response.ok) throw new EditorError(`AI 服务返回 HTTP ${response.status}，请检查 Key、模型和额度。`);
  let reply;
  const reader = response.body?.getReader();
  if (!reader) throw new EditorError('AI 服务返回了空响应。');
  try {
    let size = 0; const chunks = [];
    while (true) {
      const { value, done } = await reader.read();
      if (done) break;
      size += value.byteLength;
      if (size > 512 * 1024) throw new EditorError('AI 服务响应超过 512 KB 限制，请缩小指令后重试。');
      chunks.push(value);
    }
    reply = JSON.parse(Buffer.concat(chunks).toString('utf8'));
  } catch (error) {
    await reader.cancel().catch(() => {});
    if (error instanceof EditorError) throw error;
    throw new EditorError('AI 服务返回了无法读取的响应，请重试。');
  } finally { reader.releaseLock(); }
  const choice = reply?.choices?.[0];
  if (choice?.finish_reason && choice.finish_reason !== 'stop') throw new EditorError('AI 输出未完整结束，请缩小指令或检查模型设置后重试。');
  const content = choice?.message?.content;
  if (typeof content !== 'string' || content.length > 100000) throw new EditorError('AI 返回内容为空或超过限制。');
  let plan;
  try { plan = JSON.parse(content.trim().replace(/^```(?:json)?\s*/i, '').replace(/\s*```$/, '')); } catch { throw new EditorError('AI 没有返回有效的结构化计划，请重新表达指令。'); }
  if (typeof plan?.clarification === 'string') {
    if (Object.keys(plan).length !== 1 || !plan.clarification.trim()) throw new EditorError('AI 返回了混合或空澄清响应，请重新生成。');
    throw new EditorError(plan.clarification.slice(0, 500));
  }
  return plan;
}
