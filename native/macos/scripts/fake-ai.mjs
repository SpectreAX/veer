// Test-only OpenAI-compatible endpoint on loopback. It answers a bare region with a
// plan only when earlier session messages name the service, so a test can prove
// that follow-ups carry context. Usage: node scripts/fake-ai.mjs <port>
import { createServer } from 'node:http';

const port = Number(process.argv[2] || 0);
const reply = content => ({ choices: [{ finish_reason: 'stop', message: { content: JSON.stringify(content) } }] });
createServer(async (req, res) => {
  let body = '';
  for await (const chunk of req) body += chunk;
  const { messages } = JSON.parse(body || '{}');
  const latest = messages.at(-1).content;
  const earlier = messages.slice(1, -1).map(m => m.content).join('\n');
  const target = (messages[0].content.match(/"id":"(target-\d+)","label":"[^"]*台湾/) ?? [])[1];
  let answer;
  if (/bahamut/i.test(latest)) answer = { clarification: '请指定 bahamut 要使用的单个出口：台湾或香港。' };
  else if (/台湾/.test(latest) && /bahamut/i.test(earlier) && target) answer = { schemaVersion: 1, operations: [{ kind: 'route', matchType: 'GEOSITE', match: 'bahamut', targetId: target }] };
  else answer = { clarification: '请明确要为哪个域名或服务添加规则。' };
  res.writeHead(200, { 'Content-Type': 'application/json' });
  res.end(JSON.stringify(reply(answer)));
}).listen(port, '127.0.0.1', function () { console.log(this.address().port); });
