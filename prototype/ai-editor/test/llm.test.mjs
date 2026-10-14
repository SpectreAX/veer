import test from 'node:test';
import assert from 'node:assert/strict';
import { readFile } from 'node:fs/promises';
import { inspectConfig } from '../core/editor.mjs';
import { resolveAi } from '../core/llm.mjs';
const yaml = await readFile(new URL('../public/sample.yaml', import.meta.url), 'utf8');
const targets = inspectConfig(yaml).targets;
const settings = { apiKey: 'test-only-not-real', baseUrl: 'https://example.com/v1', model: 'test-model' };

test('AI 请求只包含出口信息，不包含配置与凭证；计划从代码围栏读取', async () => {
  const result = await resolveAi('Netflix 走日本', targets, settings, async (url, request) => {
    assert.equal(url.toString(), 'https://example.com/v1/chat/completions');
    assert.equal(request.headers.Authorization, 'Bearer test-only-not-real');
    const body = JSON.parse(request.body);
    assert(!request.body.includes('demo-only'));
    assert(!request.body.includes('jp.example.com'));
    assert(!request.body.includes('nameserver'));
    assert(body.messages[0].content.includes('日本出口'));
    return Response.json({ choices: [{ message: { content: '```json\n{"schemaVersion":1,"operations":[{"kind":"route","matchType":"DOMAIN-SUFFIX","match":"netflix.com","targetId":"target-0"}]}\n```' } }] });
  });
  assert.equal(result.operations[0].match, 'netflix.com');
});

test('澄清、HTTP 错误和格式错误不泄露 API 返回正文', async () => {
  await assert.rejects(() => resolveAi('Netflix', targets, settings, async () => Response.json({ choices: [{ message: { content: '{"clarification":"请选择出口"}' } }] })), /请选择出口/);
  await assert.rejects(() => resolveAi('Netflix', targets, settings, async () => new Response('sensitive-response', { status: 401 })), error => error.message.includes('401') && !error.message.includes('sensitive-response'));
  await assert.rejects(() => resolveAi('Netflix', targets, settings, async () => Response.json({ choices: [{ message: { content: 'yaml: invalid' } }] })), /结构化/);
});

test('外部 HTTP、内嵌认证和缺失 Key 被拒绝', async () => {
  await assert.rejects(() => resolveAi('x', targets, { ...settings, baseUrl: 'http://example.com' }), /HTTPS/);
  await assert.rejects(() => resolveAi('x', targets, { ...settings, baseUrl: 'https://user:pass@example.com' }), /凭证/);
  await assert.rejects(() => resolveAi('x', targets, { ...settings, apiKey: '' }), /Key/);
});

test('模型超限响应被中途取消，断流和未完成输出不接受', async () => {
  let cancelled = false;
  const oversized = new ReadableStream({ pull(controller) { controller.enqueue(new Uint8Array(300000)); }, cancel() { cancelled = true; } });
  await assert.rejects(() => resolveAi('x', targets, settings, async () => new Response(oversized)), /512 KB/);
  assert.equal(cancelled, true);
  const broken = new ReadableStream({ start(controller) { controller.error(new Error('secret-upstream-body')); } });
  await assert.rejects(() => resolveAi('x', targets, settings, async () => new Response(broken)), error => /无法读取/.test(error.message) && !error.message.includes('secret-upstream-body'));
  for (const finish_reason of ['length', 'content_filter', 'tool_calls']) {
    await assert.rejects(() => resolveAi('x', targets, settings, async () => Response.json({ choices: [{ finish_reason, message: { content: '{"schemaVersion":1,"operations":[]}' } }] })), /未完整/);
  }
});

test('分块合法响应可读取，混合及空澄清响应拒绝', async () => {
  const content = JSON.stringify({ schemaVersion: 1, operations: [{ kind: 'route', matchType: 'DOMAIN-SUFFIX', match: 'example.com', targetId: 'target-0' }] });
  const bytes = Buffer.from(JSON.stringify({ choices: [{ finish_reason: 'stop', message: { content } }] }));
  const stream = new ReadableStream({ start(controller) { controller.enqueue(bytes.subarray(0, 30)); controller.enqueue(bytes.subarray(30)); controller.close(); } });
  assert.equal((await resolveAi('x', targets, settings, async () => new Response(stream))).operations.length, 1);
  for (const plan of [{ clarification: '' }, { clarification: '有歧义', schemaVersion: 1, operations: [] }]) {
    await assert.rejects(() => resolveAi('x', targets, settings, async () => Response.json({ choices: [{ message: { content: JSON.stringify(plan) } }] })), /混合或空/);
  }
});
