// Circular with editor.mjs on purpose: EditorError is only used at call time.
import { EditorError } from './editor.mjs';

// Rule sets Veer may add as Mihomo `rule-providers`. The model names a source and a
// file stem; Veer builds the URL itself, so it can never invent an arbitrary address.
export const RULE_SET_SOURCES = {
  'metacubex-geosite': { behavior: 'domain', format: 'mrs', name: /^[a-z0-9@!._-]{1,64}$/, url: name => `https://raw.githubusercontent.com/MetaCubeX/meta-rules-dat/meta/geo/geosite/${name}.mrs`, key: name => name },
  'metacubex-geoip': { behavior: 'ipcidr', format: 'mrs', name: /^[a-z0-9._-]{1,64}$/, url: name => `https://raw.githubusercontent.com/MetaCubeX/meta-rules-dat/meta/geo/geoip/${name}.mrs`, key: name => `${name}-ip` },
  // Some ACL4SSR lists live one level down, e.g. Ruleset/Google.
  acl4ssr: { behavior: 'classical', format: 'text', name: /^(Ruleset\/)?[A-Za-z0-9_-]{1,64}$/, url: name => `https://raw.githubusercontent.com/ACL4SSR/ACL4SSR/master/Clash/${name}.list`, key: name => name.split('/').pop() },
  blackmatrix7: { behavior: 'classical', format: 'text', name: /^[A-Za-z0-9_-]{1,64}$/, url: name => `https://raw.githubusercontent.com/blackmatrix7/ios_rule_script/master/rule/Clash/${name}/${name}.list`, key: name => name },
};

const EXTENSION = { mrs: 'mrs', text: 'list', yaml: 'yaml' };
const BEHAVIORS = new Set(['domain', 'ipcidr', 'classical']);

export const FIND_RULE_SET_HELP = '请在以下仓库找到对应文件，复制 Raw 地址后发给我：MetaCubeX（推荐，meta 分支 → geo → geosite 或 geoip；.mrs 是二进制文件，请右键 Raw 选择“复制链接地址”）https://github.com/MetaCubeX/meta-rules-dat ；ACL4SSR https://github.com/ACL4SSR/ACL4SSR/tree/master/Clash ；blackmatrix7 https://github.com/blackmatrix7/ios_rule_script/tree/master/rule/Clash';

function fail(message) { throw new EditorError(message); }

// Infer format from the extension and behavior from the repository layout, as the
// rule-provider docs describe. A user-supplied URL must be a public raw file.
function fromUrl(raw, declared) {
  let url;
  try { url = new URL(raw); } catch { fail('规则集地址无效。'); }
  if (url.protocol !== 'https:' || url.username || url.password || url.search || url.hash || !['raw.githubusercontent.com', 'cdn.jsdelivr.net'].includes(url.hostname)) fail('规则集地址须为 raw.githubusercontent.com 或 cdn.jsdelivr.net 上的 HTTPS 文件。');
  const extension = url.pathname.split('.').pop().toLowerCase();
  const format = { mrs: 'mrs', list: 'text', txt: 'text', yaml: 'yaml', yml: 'yaml' }[extension];
  if (!format) fail('规则集文件须为 .mrs、.list 或 .yaml。');
  const behavior = /\/geosite\//.test(url.pathname) ? 'domain' : /\/geoip\//.test(url.pathname) ? 'ipcidr' : format === 'text' ? 'classical' : declared;
  if (!BEHAVIORS.has(behavior)) fail('无法从地址判断规则集类型，请说明它是域名、IP 段还是混合规则。');
  const stem = decodeURIComponent(url.pathname.split('/').pop()).replace(/\.[^.]+$/, '');
  return { url: url.toString(), behavior, format, key: behavior === 'ipcidr' && /\/geoip\//.test(url.pathname) ? `${stem}-ip` : stem };
}

export function ruleSetSpec(op) {
  const fields = ['kind', 'targetId', ...(op.url !== undefined ? ['url', 'behavior'] : ['source', 'name'])];
  if (Object.keys(op).some(k => !fields.includes(k))) fail('规则集操作包含未支持字段，请重新生成。');
  let spec;
  if (op.url !== undefined) {
    if (typeof op.url !== 'string') fail('规则集地址无效。');
    spec = fromUrl(op.url, op.behavior);
  } else {
    const source = RULE_SET_SOURCES[op.source];
    if (!source) fail(`不支持的规则集来源：${op.source}`);
    if (typeof op.name !== 'string' || !source.name.test(op.name)) fail(`规则集名称无效：${op.name}`);
    spec = { url: source.url(op.name), behavior: source.behavior, format: source.format, key: source.key(op.name) };
  }
  if (spec.format === 'mrs' && spec.behavior === 'classical') fail('mrs 格式只支持域名或 IP 段规则集，不支持混合规则。');
  spec.key = spec.key.replace(/[^A-Za-z0-9@!._-]/g, '-').slice(0, 64);
  return spec;
}

/// Reuse an existing provider with the same URL; otherwise pick a free name.
export function placeRuleSet(spec, providers) {
  const existing = Object.entries(providers ?? {}).find(([, value]) => value?.url === spec.url);
  if (existing) return { key: existing[0], reused: true };
  let key = spec.key;
  for (let n = 1; Object.hasOwn(providers ?? {}, key); n++) key = `${spec.key}-veer${n > 1 ? n : ''}`;
  return { key, reused: false, provider: { type: 'http', behavior: spec.behavior, format: spec.format, url: spec.url, path: `./rule_provider/${key}.${EXTENSION[spec.format]}`, interval: 86400 } };
}

/// HEAD each new URL. 404 means the address is wrong and the plan is rejected;
/// a network failure only marks it unverified so the user can check it.
export async function verifyRuleSetUrls(urls, fetchImpl = fetch) {
  const results = new Map();
  await Promise.all([...new Set(urls)].map(async url => {
    try {
      const response = await fetchImpl(url, { method: 'HEAD', redirect: 'follow', signal: AbortSignal.timeout(8000) });
      results.set(url, response.ok ? 'verified' : response.status === 404 ? 'missing' : 'unverified');
    } catch { results.set(url, 'unverified'); }
  }));
  const missing = [...results].filter(([, status]) => status === 'missing').map(([url]) => url);
  if (missing.length) fail(`规则集地址不存在（404）：${missing.join('、')}。不会使用推测的地址。${FIND_RULE_SET_HELP}`);
  return results;
}
