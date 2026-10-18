const $ = id => document.getElementById(id);
const state = { groups: [], rules: $('rules').value, history: [], preview: null, revision: 0, requestVersion: 0, valid: false, busy: false, manual: false };
const regions = { JP: '日本', US: '美国', HK: '香港', SG: '新加坡', TW: '台湾', KR: '韩国', GB: '英国', DE: '德国', AUTO: '自动', UNKNOWN: '未指定地区' };
let timer;
const draft = () => ({ groups: state.groups.map(g => ({ ...g })), rules: state.rules });
function status(text, kind = '') { $('status').textContent = text; $('status').dataset.kind = kind; }
async function api(action, input) {
  const response = await fetch(`/api/private/${action}`, { method: 'POST', headers: { 'Content-Type': 'application/json' }, body: JSON.stringify(input) });
  const data = await response.json(); if (!response.ok) throw new Error(data.error || '请求失败。'); return data;
}
function controls() {
  for (const id of ['generate', 'validate', 'export']) $(id).disabled = state.busy || !state.valid || (id === 'generate' && !$('prompt').value.trim());
  $('undo').disabled = state.busy || !state.history.length;
  $('generate').textContent = state.busy ? '正在生成并检查…' : '生成修改预览';
}
function clearPreview() { state.preview = null; $('review-content').hidden = true; $('empty-review').hidden = false; $('review-count').textContent = ''; }
function changed() { state.revision++; state.requestVersion++; state.valid = false; clearPreview(); controls(); }
function remember() { state.history.push(draft()); if (state.history.length > 20) state.history.shift(); }
async function inspect() {
  const revision = state.revision;
  try { const data = await api('inspect', draft()); if (revision !== state.revision) return; state.valid = true; $('config-info').textContent = `${state.groups.length} 个手工登记策略组 · ${data.count} 条规则。真实节点未读取。`; }
  catch (error) { if (revision !== state.revision) return; state.valid = false; $('config-info').textContent = error.message; }
  controls();
}
function renderGroups() {
  $('groups').replaceChildren();
  state.groups.forEach((group, index) => {
    const item = document.createElement('li'), name = document.createElement('span'), remove = document.createElement('button');
    name.textContent = `${group.name} · 声明${regions[group.region]} `;
    remove.textContent = '移除'; remove.setAttribute('aria-label', `移除策略组 ${group.name}`);
    remove.addEventListener('click', () => { remember(); state.groups.splice(index, 1); changed(); renderGroups(); inspect(); });
    item.append(name, remove); $('groups').append(item);
  });
  $('cloud-context').textContent = state.groups.length ? `发给 AI 的出口标签：${state.groups.map((g, i) => `出口${i + 1}（${regions[g.region]}）`).join('、')}；另有 DIRECT / REJECT。` : '未登记出口；DIRECT / REJECT 始终可用。';
}
$('group-form').addEventListener('submit', async event => {
  event.preventDefault(); const revision = state.revision, group = { name: $('group-name').value.trim(), region: $('group-region').value };
  try { await api('inspect', { groups: [...state.groups, group], rules: state.rules }); if (revision !== state.revision) { status('规则稿已变化，请重新登记策略组。'); return; } remember(); state.groups.push(group); changed(); renderGroups(); await inspect(); $('group-name').value = ''; status('组名仅保留在本地，AI 使用匿名标签。', 'success'); }
  catch (error) { status(error.message, 'error'); }
});
$('sample').addEventListener('click', async () => {
  remember(); state.groups = [{ name: '日本出口', region: 'JP' }, { name: '美国出口', region: 'US' }]; changed(); renderGroups(); await inspect(); status('已登记演示组名，并非从真实客户端读取。请改为自己的实际组名。');
});
$('rules').addEventListener('input', () => { if (!state.manual) { remember(); state.manual = true; } state.rules = $('rules').value; changed(); clearTimeout(timer); timer = setTimeout(inspect, 250); });
$('rules').addEventListener('blur', () => { state.manual = false; });
$('prompt').addEventListener('input', () => { state.requestVersion++; clearPreview(); controls(); });
document.querySelectorAll('[data-prompt]').forEach(button => button.addEventListener('click', () => { $('prompt').value = button.dataset.prompt; $('prompt').dispatchEvent(new Event('input')); $('prompt').focus(); }));
$('mode').addEventListener('change', () => { $('ai-settings').hidden = $('mode').value !== 'ai'; state.requestVersion++; clearPreview(); controls(); });
$('generate').addEventListener('click', async () => {
  const version = state.requestVersion, base = draft(); state.busy = true; clearPreview(); controls(); status('正在生成匿名出口计划并检查规则…');
  try {
    const result = await api('plan', { ...base, prompt: $('prompt').value, mode: $('mode').value, settings: $('mode').value === 'ai' ? { baseUrl: $('base-url').value, model: $('model').value, apiKey: $('api-key').value, useSavedKey: $('api-key').dataset.saved === 'true' } : undefined });
    if (version !== state.requestVersion) { status('规则或指令已变化，旧结果已丢弃。'); return; }
    state.preview = { ...result, version }; $('changes').replaceChildren(); $('diff').replaceChildren();
    for (const change of result.summaries) { const li = document.createElement('li'); li.textContent = `${change.matchType} · ${change.match} → ${change.kind === 'route' ? change.target : '删除规则'}`; $('changes').append(li); }
    for (const part of result.diff) { const span = document.createElement('span'); span.className = part.kind; span.textContent = `${part.kind === 'add' ? '+ ' : part.kind === 'remove' ? '− ' : '  '}${part.text}`; $('diff').append(span); }
    $('review-count').textContent = `${result.summaries.length} 项操作`; $('validation-result').textContent = result.validation.message;
    $('confirm').disabled = result.validation.status === 'failed' || !result.changed; $('review-content').hidden = false; $('empty-review').hidden = true;
    status(result.validation.status === 'failed' ? '规则测试失败，不能确认。' : result.changed ? '预览已生成；确认只修改本页规则稿。' : '规则已存在，无需修改。', result.validation.status === 'failed' ? 'error' : 'success');
  } catch (error) { if (version === state.requestVersion) status(error.message, 'error'); }
  finally { state.busy = false; controls(); }
});
$('confirm').addEventListener('click', async () => { const preview = state.preview; if (!preview || preview.version !== state.requestVersion || preview.validation.status === 'failed') return; remember(); state.rules = preview.candidate; $('rules').value = state.rules; state.manual = false; changed(); await inspect(); status('已确认到规则稿，尚未应用到代理。', 'success'); });
$('discard').addEventListener('click', () => { clearPreview(); status('预览已放弃，规则稿未改变。'); });
$('undo').addEventListener('click', async () => { const previous = state.history.pop(); if (!previous) return; state.groups = previous.groups; state.rules = previous.rules; $('rules').value = state.rules; state.manual = false; changed(); renderGroups(); await inspect(); status('已撤销规则稿或策略组登记修改。'); });
$('validate').addEventListener('click', async () => { const revision = state.revision; state.busy = true; controls(); try { const result = await api('validate', draft()); if (revision === state.revision) status(result.message, result.status === 'failed' ? 'error' : ''); } catch (error) { if (revision === state.revision) status(error.message, 'error'); } finally { state.busy = false; controls(); } });
$('export').addEventListener('click', async () => {
  const revision = state.revision, base = draft();
  try { await api('inspect', base); if (revision !== state.revision) return; const url = URL.createObjectURL(new Blob([base.rules], { type: 'text/yaml;charset=utf-8' })); const link = document.createElement('a'); link.href = url; link.download = 'veer-rules-fragment.yaml'; document.body.append(link); link.click(); link.remove(); setTimeout(() => URL.revokeObjectURL(url), 1000); status('已导出 rules 片段；不要覆盖完整配置，请由客户端合并并校验。', 'success'); }
  catch (error) { status(error.message, 'error'); }
});
$('theme').addEventListener('change', event => { if (event.target.value === 'auto') delete document.documentElement.dataset.theme; else document.documentElement.dataset.theme = event.target.value; });
renderGroups(); controls(); inspect();
