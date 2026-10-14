const $ = id => document.getElementById(id);
const state = { yaml: '', filename: 'config.yaml', inspected: null, preview: null, history: [], revision: 0, requestVersion: 0, busy: false, manualSession: false };
let inspectTimer;
function status(message, kind = '') { $('status').textContent = message; $('status').dataset.kind = kind; }
async function api(path, body) {
  const response = await fetch(`/api/${path}`, { method: 'POST', headers: { 'Content-Type': 'application/json' }, body: JSON.stringify(body) });
  const data = await response.json(); if (!response.ok) throw new Error(data.error || '请求失败。'); return data;
}
function controls() {
  $('generate').disabled = state.busy || !state.inspected || !$('prompt').value.trim();
  $('validate').disabled = state.busy || !state.inspected;
  $('export').disabled = state.busy || !state.inspected;
  $('undo').disabled = state.busy || !state.history.length;
  $('generate').textContent = state.busy ? '正在生成并检查…' : '生成修改预览';
}
function clearPreview() {
  state.preview = null; $('review-content').hidden = true; $('empty-review').hidden = false; $('review-count').textContent = '';
}
function invalidate() { state.revision++; state.requestVersion++; state.inspected = null; clearPreview(); controls(); }
async function inspect(revision = state.revision) {
  try {
    const result = await api('inspect', { yaml: state.yaml });
    if (revision !== state.revision) return;
    state.inspected = result;
    const c = result.counts;
    $('config-info').textContent = `${c.nodes} 个节点 · ${c.groups} 个策略组 · ${c.rules} 条规则 · ${c.providers} 个 Provider${result.warnings.length ? `。${result.warnings.join(' ')}` : ''}`;
    $('target').replaceChildren(new Option('选择后插入指令', ''), ...result.targets.map(t => new Option(t.name, t.name)));
    $('target').disabled = false;
    controls();
  } catch (error) {
    if (revision !== state.revision) return;
    state.inspected = null; $('config-info').textContent = error.message; $('target').disabled = true; controls();
  }
}
function remember() { state.history.push({ yaml: state.yaml, filename: state.filename }); if (state.history.length > 20) state.history.shift(); }
async function load(yaml, filename) {
  state.yaml = yaml; state.filename = filename; state.history = []; state.manualSession = false;
  $('yaml').value = yaml; $('filename').textContent = filename;
  invalidate(); await inspect();
  status(state.inspected ? '配置已导入。输入分流指令，或先检查配置。' : '请修正配置后再生成预览。', state.inspected ? 'success' : 'error');
}
function showPreview(result, baseYaml, revision) {
  state.preview = { ...result, baseYaml, revision };
  $('changes').replaceChildren();
  for (const change of result.summaries) {
    const item = document.createElement('li');
    const code = document.createElement('code'); code.textContent = `${change.matchType} · ${change.match}`;
    const destination = document.createElement('span'); destination.className = 'destination'; destination.textContent = change.kind === 'route' ? ` → ${change.target}` : ' → 删除规则';
    const previous = document.createElement('span'); previous.className = 'previous'; previous.textContent = change.before.length ? `原规则：${change.before.join('；')}` : '新增规则，排在已有规则之前。';
    item.append(code, destination, previous); $('changes').append(item);
  }
  $('diff').replaceChildren();
  for (const part of result.diff) {
    const lines = part.text.replace(/\n$/, '').split('\n');
    const visible = part.kind === 'same' && lines.length > 8 ? [...lines.slice(0, 3), `… ${lines.length - 6} 行未修改 …`, ...lines.slice(-3)] : lines;
    for (const line of visible) {
      const row = document.createElement('span'); row.className = part.kind;
      row.textContent = `${part.kind === 'add' ? '+ ' : part.kind === 'remove' ? '− ' : '  '}${line}`; $('diff').append(row);
    }
  }
  $('review-count').textContent = `${result.summaries.length} 项修改`;
  $('validation-result').textContent = result.validation.message;
  $('confirm').disabled = result.validation.status === 'failed' || !result.changed;
  $('review-content').hidden = false; $('empty-review').hidden = true;
}
$('import').addEventListener('click', () => $('file').click());
$('file').addEventListener('change', async event => {
  const file = event.target.files[0]; if (!file) return;
  if (file.size > 2 * 1024 * 1024) { status('文件超过 2 MB，请先拆分。', 'error'); event.target.value = ''; return; }
  try { await load(await file.text(), file.name); } catch { status('文件无法读取，请重新选择。', 'error'); }
  event.target.value = '';
});
$('sample').addEventListener('click', async () => {
  try { await load(await (await fetch('/sample.yaml')).text(), 'demo.yaml'); status('已载入演示配置。节点不可用于真实代理。', 'success'); }
  catch { status('无法载入演示配置。', 'error'); }
});
$('yaml').addEventListener('input', () => {
  if (!state.manualSession) { remember(); state.manualSession = true; }
  state.yaml = $('yaml').value; invalidate(); $('config-info').textContent = '正在解析编辑稿…';
  clearTimeout(inspectTimer); inspectTimer = setTimeout(() => inspect(), 250);
  status('编辑稿已改变，旧预览已清除。');
});
$('yaml').addEventListener('blur', () => { state.manualSession = false; });
$('prompt').addEventListener('input', () => { clearPreview(); state.requestVersion++; controls(); });
document.querySelectorAll('[data-prompt]').forEach(button => button.addEventListener('click', () => { $('prompt').value = button.dataset.prompt; $('prompt').dispatchEvent(new Event('input')); $('prompt').focus(); }));
$('target').addEventListener('change', event => {
  if (!event.target.value) return;
  $('prompt').value = `${$('prompt').value.trim()} ${event.target.value}`.trim(); $('prompt').dispatchEvent(new Event('input')); event.target.value = ''; $('prompt').focus();
});
$('mode').addEventListener('change', () => {
  const ai = $('mode').value === 'ai'; $('ai-settings').hidden = !ai; $('ai-settings').open = ai; $('local-note').hidden = ai;
  clearPreview(); state.requestVersion++; controls();
});
$('generate').addEventListener('click', async () => {
  const revision = state.revision, requestVersion = state.requestVersion, baseYaml = state.yaml;
  state.busy = true; clearPreview(); controls(); status('正在理解指令并校验候选配置…');
  try {
    const result = await api('plan', { yaml: baseYaml, prompt: $('prompt').value, mode: $('mode').value, settings: $('mode').value === 'ai' ? { baseUrl: $('base-url').value, model: $('model').value, apiKey: $('api-key').value, useSavedKey: $('api-key').dataset.saved === 'true' } : undefined });
    if (requestVersion !== state.requestVersion) { status('配置或指令已改变，已丢弃旧结果。'); return; }
    showPreview(result, baseYaml, revision);
    status(result.validation.status === 'failed' ? '候选配置未通过内核检查，不能确认。' : result.changed ? '预览已生成。请检查匹配项和出口后确认。' : '这些规则已经存在，无需修改。', result.validation.status === 'failed' ? 'error' : 'success');
  } catch (error) { if (requestVersion === state.requestVersion) status(error.message, 'error'); }
  finally { state.busy = false; controls(); }
});
$('confirm').addEventListener('click', async () => {
  const preview = state.preview;
  if (!preview || preview.validation.status === 'failed' || preview.revision !== state.revision || preview.baseYaml !== state.yaml) { clearPreview(); status('预览已过期，请重新生成。', 'error'); return; }
  remember(); state.yaml = preview.candidate; $('yaml').value = state.yaml; state.manualSession = false;
  invalidate(); await inspect(); status('修改已确认到编辑稿。可撤销或导出；尚未应用到代理。', 'success');
});
$('discard').addEventListener('click', () => { clearPreview(); status('已放弃预览，编辑稿未改变。'); });
$('undo').addEventListener('click', async () => {
  const previous = state.history.pop(); if (!previous) return;
  state.yaml = previous.yaml; state.filename = previous.filename; state.manualSession = false; $('yaml').value = state.yaml; $('filename').textContent = state.filename;
  invalidate(); if (state.yaml.trim()) await inspect(); else $('config-info').textContent = '等待导入配置。';
  status('已撤销上次编辑。'); controls();
});
$('validate').addEventListener('click', async () => {
  const revision = state.revision; state.busy = true; controls(); status('正在检查当前编辑稿…');
  try { const result = await api('validate', { yaml: state.yaml }); if (revision === state.revision) status(result.message, result.status === 'failed' ? 'error' : result.status === 'passed' ? 'success' : ''); }
  catch (error) { if (revision === state.revision) status(error.message, 'error'); }
  finally { state.busy = false; controls(); }
});
$('export').addEventListener('click', async () => {
  const revision = state.revision, text = state.yaml;
  try {
    await api('inspect', { yaml: text }); if (revision !== state.revision) return;
    const url = URL.createObjectURL(new Blob([text], { type: 'text/yaml;charset=utf-8' }));
    const link = document.createElement('a'); link.href = url; link.download = state.filename.replace(/\.(ya?ml|txt)$/i, '') + '-veer.yaml'; document.body.append(link); link.click(); link.remove(); setTimeout(() => URL.revokeObjectURL(url), 1000);
    status('已导出编辑稿。请在代理客户端中导入并验证实际分流。', 'success');
  } catch (error) { status(error.message, 'error'); }
});
$('theme').addEventListener('change', event => { if (event.target.value === 'auto') delete document.documentElement.dataset.theme; else document.documentElement.dataset.theme = event.target.value; });
controls();
