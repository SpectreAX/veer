import { parseDocument, stringify } from 'yaml';
import { diffLines } from 'diff';
import { EditorError, readConfig, applyPlan, resolveLocal } from './editor.mjs';

export const REGIONS = { JP: '日本', US: '美国', HK: '香港', SG: '新加坡', TW: '台湾', KR: '韩国', GB: '英国', DE: '德国', AUTO: '自动', UNKNOWN: '未指定地区' };
const allowedTypes = new Set(['DOMAIN', 'DOMAIN-SUFFIX', 'DOMAIN-KEYWORD', 'IP-CIDR', 'IP-CIDR6', 'GEOSITE', 'GEOIP']);
function fail(message) { throw new EditorError(message); }
export function readPrivateInput(input) {
  if (!input || typeof input !== 'object' || Array.isArray(input) || Object.keys(input).some(k => !['groups', 'rules'].includes(k))) fail('独立规则模式只接收 groups 和 rules，不接收完整配置。');
  if (!Array.isArray(input.groups) || input.groups.length > 100) fail('请提供最多 100 个允许使用的策略组。');
  const names = new Set(['DIRECT', 'REJECT', 'REJECT-DROP', 'PASS', 'COMPATIBLE']);
  for (const group of input.groups) {
    if (!group || typeof group !== 'object' || Array.isArray(group) || Object.keys(group).some(k => !['name', 'region'].includes(k)) || typeof group.name !== 'string' || !group.name.trim() || group.name !== group.name.trim() || group.name.length > 120 || /[\r\n,\x00-\x1f]/.test(group.name) || names.has(group.name) || !Object.hasOwn(REGIONS, group.region)) fail('策略组必须有唯一名称和支持的地区；不能包含节点字段、逗号或控制字符。');
    names.add(group.name);
  }
  if (typeof input.rules !== 'string' || Buffer.byteLength(input.rules) > 128 * 1024) fail('规则稿须为不超过 128 KB 的 rules YAML 片段。');
  const doc = parseDocument(input.rules, { uniqueKeys: true });
  if (doc.errors.length) fail('规则 YAML 无法解析，请检查格式。');
  let data;
  try { data = doc.toJS({ maxAliasCount: 0 }); } catch { fail('独立规则模式不接受 YAML 锚点。'); }
  if (!data || typeof data !== 'object' || Array.isArray(data) || Object.keys(data).length !== 1 || !Array.isArray(data.rules) || data.rules.length > 2000) fail('只允许 rules 数组。请勿粘贴完整配置、节点或密钥。');
  const base = { mode: 'rule', 'proxy-groups': input.groups.map(({ name }) => ({ name, type: 'select', proxies: ['DIRECT'] })), rules: data.rules };
  const synthetic = stringify(base);
  const { targets } = readConfig(synthetic);
  for (const rule of data.rules) {
    if (typeof rule !== 'string') fail('每条规则必须是字符串。');
    const [matchType, match, target, flag, extra] = rule.split(',');
    if (!allowedTypes.has(matchType) || !targets.some(t => t.name === target) || extra !== undefined || (flag !== undefined && (!['IP-CIDR', 'IP-CIDR6', 'GEOIP'].includes(matchType) || flag !== 'no-resolve'))) fail('规则片段仅支持指定匹配类型及已登记出口，不支持 MATCH 或其他配置。');
    applyPlan(stringify({ ...base, rules: [] }), { schemaVersion: 1, operations: [{ kind: 'route', matchType, match, targetId: targets.find(t => t.name === target).id }] });
  }
  const anonymousTargets = targets.map((target, i) => ({ id: target.id, kind: target.kind, name: target.kind === 'builtin' ? target.name : `出口${i + 1}（${REGIONS[input.groups[i].region]}）` }));
  return { synthetic, targets, anonymousTargets, rules: data.rules };
}

export function anonymizePrompt(prompt, targets, anonymousTargets) {
  const map = new Map(targets.filter(t => t.kind !== 'builtin').map(t => [t.name, anonymousTargets.find(a => a.id === t.id).name]));
  if (!map.size) return prompt;
  const escaped = [...map.keys()].sort((a, b) => b.length - a.length).map(name => name.replace(/[.*+?^${}()|[\]\\]/g, '\\$&'));
  return prompt.replace(new RegExp(escaped.join('|'), 'g'), name => map.get(name));
}

export function applyPrivatePlan(input, plan) {
  // A rules-only fragment has nowhere to declare rule-providers.
  if (plan?.operations?.some?.(op => op?.kind === 'rule_set')) fail('独立规则片段不能添加规则集。请导入完整配置后再添加。');
  const context = readPrivateInput(input);
  const result = applyPlan(context.synthetic, plan);
  const candidate = stringify({ rules: readConfig(result.candidate).config.rules });
  return { ...result, candidate, synthetic: result.candidate, changed: candidate !== stringify({ rules: context.rules }), diff: diffLines(input.rules, candidate).map(p => ({ kind: p.added ? 'add' : p.removed ? 'remove' : 'same', text: p.value })) };
}

export function resolvePrivateLocal(prompt, context) {
  return resolveLocal(anonymizePrompt(prompt, context.targets, context.anonymousTargets), context.anonymousTargets);
}
