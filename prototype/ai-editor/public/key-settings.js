const element = id => document.getElementById(id);
const key = element('api-key'), base = element('base-url'), info = element('key-status');
let version = 0, busy = false, restoreTimer;
function message(text, kind = '') { info.textContent = text; info.dataset.kind = kind; }
function controls() { element('save-key').disabled = busy || !key.value.trim(); element('remove-key').disabled = busy || key.dataset.saved !== 'true'; }
async function request(action, data) {
  const response = await fetch(`/api/key/${action}`, { method: 'POST', headers: { 'Content-Type': 'application/json' }, body: JSON.stringify(data) });
  const result = await response.json(); if (!response.ok) throw new Error(result.error || '钥匙串操作失败。'); return result;
}
async function restore() {
  const current = ++version, address = base.value; key.dataset.saved = 'false'; controls();
  try { const result = await request('status', { baseUrl: address }); if (current !== version) return; key.dataset.saved = String(result.saved); key.placeholder = result.saved ? '使用此 API 地址的已保存 Key；输入可临时替换' : '填写后点击保存到钥匙串'; message(result.saved ? '已恢复钥匙串 Key；无需再次填写。' : '此 API 地址尚未保存 Key。'); }
  catch (error) { if (current === version) message(error.message, 'error'); }
  controls();
}
base.addEventListener('input', () => { version++; key.dataset.saved = 'false'; key.value = ''; key.placeholder = 'API 地址已变更，请检查已保存 Key'; controls(); message('地址已变更，旧 Key 不会用于新地址。'); clearTimeout(restoreTimer); restoreTimer = setTimeout(restore, 300); });
base.addEventListener('change', () => { clearTimeout(restoreTimer); return restore(); });
key.addEventListener('input', controls);
element('save-key').addEventListener('click', async () => {
  const address = base.value, secret = key.value, current = ++version;
  busy = true; controls(); message('正在保存到 macOS 钥匙串…');
  try { await request('save', { baseUrl: address, apiKey: secret }); if (current !== version) return; key.dataset.saved = 'true'; if (key.value === secret) key.value = ''; key.placeholder = '使用此 API 地址的已保存 Key；输入可临时替换'; message('Key 已保存到 macOS 钥匙串。刷新或重启后仍可使用。', 'success'); }
  catch (error) { if (current === version) message(error.message, 'error'); }
  finally { busy = false; controls(); }
});
element('remove-key').addEventListener('click', async () => {
  const address = base.value, current = ++version; busy = true; controls();
  try { await request('remove', { baseUrl: address }); if (current !== version) return; key.dataset.saved = 'false'; key.value = ''; key.placeholder = '填写后点击保存到钥匙串'; message('此 API 地址的已保存 Key 已删除。'); }
  catch (error) { if (current === version) message(error.message, 'error'); }
  finally { busy = false; controls(); }
});
restore();
