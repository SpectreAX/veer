import { parseDocument, stringify, isSeq } from 'yaml';
import { isDeepStrictEqual } from 'node:util';
import { diffLines } from 'diff';
import { EditorError, readConfig, applyPlan } from './editor.mjs';
import { REGIONS } from './private-editor.mjs';

const invalid = () => new EditorError('无法安全解析配置或规则。请使用有效的 Mihomo YAML（最大 2 MB），不支持节点列表或 Base64 订阅。');
export function openDocument(yaml) {
  try {
    const context = readConfig(yaml);
    const patterns = { JP: /日本|东京|大阪|\bjp\b|japan|🇯🇵/i, US: /美国|洛杉矶|纽约|\bus\b|usa|🇺🇸/i, HK: /香港|\bhk\b|🇭🇰/i, SG: /新加坡|\bsg\b|🇸🇬/i, TW: /台湾|\btw\b|🇹🇼/i, KR: /韩国|\bkr\b|🇰🇷/i, GB: /英国|\buk\b|🇬🇧/i, DE: /德国|\bde\b|🇩🇪/i };
    const groups = context.targets.filter(t => t.kind !== 'builtin').map(t => {
      const matches = Object.entries(patterns).filter(([, pattern]) => pattern.test(t.name));
      return { name: t.name, region: matches.length === 1 ? matches[0][0] : 'UNKNOWN' };
    });
    return { groups, rules: stringify({ rules: context.config.rules ?? [] }) };
  } catch { throw invalid(); }
}

// Replace only the rules value; never serialize private node/provider fields.
export function mergeDocument(yaml, rules) {
  try {
    const { doc, config } = readConfig(yaml);
    if (typeof rules !== 'string' || Buffer.byteLength(rules) > 1024 * 1024) throw invalid();
    const draft = parseDocument(rules, { uniqueKeys: true });
    const data = draft.toJS({ maxAliasCount: 0 });
    if (draft.errors.length || !data || Object.keys(data).length !== 1 || !Array.isArray(data.rules) || data.rules.some(r => typeof r !== 'string')) throw invalid();
    if (isDeepStrictEqual(data.rules, config.rules ?? [])) return yaml;
    const seq = doc.get('rules', true);
    if (seq && !isSeq(seq)) throw invalid();
    const range = seq?.range;
    const indent = range && !seq.flow ? range[0] - yaml.lastIndexOf('\n', range[0] - 1) - 1 : 2;
    doc.set('rules', doc.createNode(data.rules));
    if (seq?.flow) doc.get('rules', true).flow = true;
    const rendered = doc.toString({ lineWidth: 0, indent: Math.max(1, Math.min(indent, 8)), indentSeq: indent !== 0 });
    const next = parseDocument(rendered, { merge: true });
    const nextRange = next.get('rules', true).range;
    let candidate;
    if (range) {
      let value = rendered.slice(nextRange[0], nextRange[2]);
      const nextIndent = nextRange[0] - rendered.lastIndexOf('\n', nextRange[0] - 1) - 1;
      value = value.split('\n').map((line, i) => i && line ? ' '.repeat(indent) + line.slice(nextIndent) : line).join('\n');
      candidate = yaml.slice(0, range[0]) + value + yaml.slice(range[2]);
    } else {
      const pair = next.contents.items.find(p => p.key.value === 'rules');
      candidate = yaml + (yaml.endsWith('\n') ? '' : '\n') + rendered.slice(pair.key.range[0], nextRange[2]);
    }
    const after = readConfig(candidate).config;
    const beforeOther = { ...config }, afterOther = { ...after };
    delete beforeOther.rules; delete afterOther.rules;
    if (!isDeepStrictEqual(data.rules, after.rules) || !isDeepStrictEqual(beforeOther, afterOther)) throw invalid();
    return candidate;
  } catch { throw invalid(); }
}

export function documentContext(input) {
  const yaml = mergeDocument(input.yaml, input.rules);
  const context = readConfig(yaml);
  if (!Array.isArray(input.groups) || input.groups.length > 2500) throw invalid();
  const seen = new Set();
  for (const group of input.groups) {
    if (!group || seen.has(group.name) || !context.targets.some(t => t.kind !== 'builtin' && t.name === group.name) || !Object.hasOwn(REGIONS, group.region)) throw invalid();
    seen.add(group.name);
  }
  const anonymousTargets = context.targets.map((t, i) => ({ id: t.id, kind: t.kind, name: t.kind === 'builtin' ? t.name : `出口${i + 1}（${REGIONS[input.groups.find(g => g.name === t.name)?.region ?? 'UNKNOWN']}）` }));
  return { ...context, yaml, anonymousTargets };
}

export function applyDocumentPlan(input, context, plan) {
  const result = applyPlan(context.yaml, plan);
  const candidate = stringify({ rules: readConfig(result.candidate).config.rules });
  return { ...result, candidate, diff: (diffLines(input.rules, candidate, { timeout: 1500 }) ?? [{ value: input.rules, removed: true }, { value: candidate, added: true }]).map(p => ({ kind: p.added ? 'add' : p.removed ? 'remove' : 'same', text: p.value })) };
}
