import {initialState,importDemo,startTurn,completeTurn,cancelTurn,confirmTurn,undoTurn,yaml,diffLines,services} from './state.mjs';
const $=id=>document.getElementById(id);
const escape=s=>String(s).replace(/[&<>"']/g,c=>({'&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;',"'":'&#39;'}[c]));
const paths={plus:'M12 4v16M4 12h16',up:'M12 20V4m-6 6 6-6 6 6',down:'M12 4v16m-6-6 6 6 6-6',right:'m9 5 7 7-7 7',close:'m6 6 12 12M6 18 18 6',file:'M14 2H5v20h14V7Zm0 0v5h5M8 12h8M8 16h8',chat:'M4 4h16v12H9l-5 4Zm4 4h8M8 12h5',route:'M4 5h7v6H4Zm9 8h7v6h-7ZM7 11v5h6',settings:'M4 6h16M4 12h16M4 18h16M8 3v6m8 0v6m-6 0v6',export:'M12 15V3m-4 4 4-4 4 4M5 10v11h14V10',panel:'M3 4h18v16H3Zm11 0v16',moon:'M20 15A8 8 0 0 1 9 4a8 8 0 1 0 11 11',sun:'M12 7a5 5 0 1 0 0 10 5 5 0 0 0 0-10M12 2v2m0 16v2M2 12h2m16 0h2M5 5l1 1m12 12 1 1M5 19l1-1M18 6l1-1',check:'m5 12 4 4L19 6',stop:'M6 6h12v12H6Z'};
const icon=name=>`<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.6" stroke-linecap="round" stroke-linejoin="round" aria-hidden="true"><path d="${paths[name]??paths.file}"/></svg>`;
const fillIcons=()=>document.querySelectorAll('[data-icon]').forEach(el=>el.innerHTML=icon(el.dataset.icon));fillIcons();
const labels={running:'处理中 · 演示',pending:'候选修改 · 尚未写入',confirmed:'已确认到草稿',undone:'已撤销',superseded:'已被后续操作取代',cancelled:'已取消',failed:'未完成',discarded:'已放弃'};
const s=initialState();let reviewOpen=false,following=true,chatTop=0,timers=[],toastTimer;
const reviewDisclosures=new Map();
const clearTimers=()=>{timers.forEach(clearTimeout);timers=[];};
function toast(text){clearTimeout(toastTimer);$('toast-text').textContent=text;$('toast').hidden=false;toastTimer=setTimeout(()=>$('toast').hidden=true,4000);}
$('toast-close').onclick=()=>{$('toast').hidden=true;clearTimeout(toastTimer);};
const selected=()=>s.turns.find(t=>t.id===s.selected);
const showReview=id=>{s.selected=id;reviewOpen=true;render();};
function routeHTML(r){return `<div class="routing-line"><strong>${escape(r.name)}</strong>${icon('right')}<span>${escape(r.target)}</span></div>`;}
function messageHTML(t){
  const done=t.status==='confirmed'?'已写入草稿，尚未应用到代理。':t.status==='undone'?'已撤销此次修改，草稿恢复到上一快照。':t.status==='pending'?`已准备 ${t.routes.reduce((n,r)=>n+services[r.name].length,0)} 条规则，等待你审阅。`:t.status==='superseded'?'保留此轮变更供查看，不再允许确认。':t.status==='cancelled'?'操作已取消，草稿未改变。':t.status==='discarded'?'已放弃此次候选，草稿未改变。':'正在处理指令。此处是合成状态演示。';
  return `<article class="turn" id="turn-${t.id}"><div class="user-row"><div class="user-message">${escape(t.prompt)}</div></div><details class="steps" data-steps="${t.id}" ${t.open?'open':''}><summary>${escape(t.status==='running'?'处理中 · 演示':t.status==='failed'?'处理未完成':t.status==='cancelled'?'已取消':'处理完成')} · ${t.steps.length} 个步骤</summary><ul class="step-list">${t.steps.map(text=>`<li><span>·</span>${escape(text)}</li>`).join('')}</ul></details>${t.status==='failed'?`<p class="error-text" role="alert">${escape(t.error)}</p><button class="text-button" data-retry="${t.id}">重试此指令</button>`:`<p class="assistant-text">${escape(done)}</p>`}${t.routes.length?`<div class="routing-list">${t.routes.map(routeHTML).join('')}</div><button class="file-change" data-review="${t.id}"><span class="file-label">${icon('file')}<strong>${escape(s.file)}</strong></span><small>${escape(labels[t.status])} ${icon('right')}</small></button><p class="limits">${escape(t.status==='pending'?'确认前草稿不变。':'')}地区来自合成示例，未实测。未应用到代理。</p>`:''}</article>`;
}
function renderReview(){
  const t=selected();$('review-state').textContent=t?labels[t.status]:'尚无候选';
  if(!t?.routes.length){$('review-content').innerHTML='<p>发送一条分流指令后，在这里审阅服务出口与 YAML 差异。</p>';$('review-actions').innerHTML='';return;}
  $('review-content').innerHTML=`<div class="review-file">${icon('file')}<div><strong>${escape(s.file)}</strong><p class="limits">仅修改 rules · 合成演示</p></div></div><h3>流量出口</h3>${t.routes.map(r=>`<section class="review-route"><strong>${escape(r.name)}</strong><div>${icon('right')}<span>${escape(r.target)}</span></div><p>${escape(r.region)} · 未实测</p><details><summary>${services[r.name].length} 条规则 · 匹配范围</summary><ul>${services[r.name].map(d=>`<li>${d}</li>`).join('')}</ul></details></section>`).join('')}<div class="diff-title"><h3>YAML Diff</h3><button id="copy-diff">复制差异</button></div><div class="diff" aria-label="YAML 差异，可横向滚动"><pre>${diffLines(t).map((line,i)=>`<span class="diff-line ${line.startsWith('+')?'add':''}"><span class="line-number">${i+1}</span>${escape(line)}</span>`).join('')}</pre></div><p class="limits">+ 新增 / − 删除。仅演示规则校验状态，未运行真实内核检查；不代表网络可达或服务解锁。</p>`;
  $('review-content').querySelectorAll('.review-route details').forEach((el,index)=>{
    const key=`${t.id}:${t.routes[index].name}`;
    el.open=reviewDisclosures.get(key)??false;
    el.ontoggle=()=>reviewDisclosures.set(key,el.open);
  });
  const canUndo=t.status==='confirmed'&&s.snapshots.at(-1)?.id===t.id&&!s.busy;
  $('review-actions').innerHTML=`<small>${t.status==='pending'?'确认到草稿，不会应用代理。':escape(labels[t.status])+' · 未应用代理'}</small><div class="action-group">${t.status==='pending'?`<button id="discard" class="secondary" ${s.busy?'disabled':''}>放弃</button><button id="confirm" class="primary" ${s.busy?'disabled':''}>确认修改</button>`:t.status==='confirmed'?`<button id="undo" class="secondary" ${canUndo?'':'disabled'}>撤销此修改</button>`:''}</div>`;
  $('copy-diff').onclick=async()=>{try{await navigator.clipboard.writeText(diffLines(t).join('\n'));toast('已复制演示差异。');}catch{toast('无法访问剪贴板，可在 Diff 中选择文本复制。');}};
  if($('confirm'))$('confirm').onclick=()=>{if(confirmTurn(s,t.id)){render();toast('已确认到演示草稿，未应用到代理。');}};
  if($('discard'))$('discard').onclick=()=>{if(!s.busy&&t.status==='pending'){t.status='discarded';render();toast('已放弃候选，草稿不变。');}};
  if($('undo'))$('undo').onclick=()=>{if(undoTurn(s,t.id)){render();toast('已撤销演示草稿修改。');}};
}
function render(){
  if($('timeline').getClientRects().length)chatTop=$('timeline').scrollTop;
  $('file-title').textContent=s.file||'AI 工作台';$('file-title').title=s.file;$('sidebar-file').textContent=s.file||'尚未导入';
  $('file-status').textContent=s.file?`合成示例 · ${s.draft.length} 条草稿规则 · 未应用代理`:'仅编辑规则 · 不控制代理';
  $('landing').hidden=!!s.file;$('prompt').disabled=!s.file||!!s.busy;$('mode').disabled=!s.file||!!s.busy;$('export').disabled=!s.file||!!s.busy;
  $('prompt').placeholder=s.file?'描述你想修改的分流规则…':'导入配置文件或订阅链接以开始';
  $('send').innerHTML=icon(s.busy?'stop':'up');$('send').type=s.busy?'button':'submit';$('send').disabled=!s.file||(!s.busy&&!$('prompt').value.trim());$('send').setAttribute('aria-label',s.busy?'取消处理':'发送指令');
  $('work-status').textContent=s.busy?'处理中 · 演示':'';
  $('messages').innerHTML=s.file&&!s.turns.length?'<div class="start-conversation"><h1>想如何调整分流？</h1><p>告诉 Veer 服务与出口，确认前规则稿不会改变。</p><div class="example-buttons"><button data-prompt="Netflix 走日本，ChatGPT 走美国">Netflix 走日本，ChatGPT 走美国</button><button data-prompt="Netflix 走香港">Netflix 走香港</button></div></div>':s.turns.map(messageHTML).join('');
  $('review-toggle').disabled=!s.file;$('review-toggle').setAttribute('aria-expanded',String(reviewOpen));$('review-toggle').setAttribute('aria-label',reviewOpen?'关闭修改审阅':'打开修改审阅');
  $('review').hidden=!reviewOpen;document.body.classList.toggle('review-open',reviewOpen);renderReview();
  document.querySelectorAll('[data-review]').forEach(el=>el.onclick=()=>showReview(Number(el.dataset.review)));
  document.querySelectorAll('[data-prompt]').forEach(el=>el.onclick=()=>{$('prompt').value=el.dataset.prompt;$('prompt').dispatchEvent(new Event('input'));$('prompt').focus();});
  document.querySelectorAll('[data-steps]').forEach(el=>el.ontoggle=()=>{const t=s.turns.find(t=>t.id===Number(el.dataset.steps));if(t)t.open=el.open;});
  document.querySelectorAll('[data-retry]').forEach(el=>el.onclick=()=>{const t=s.turns.find(t=>t.id===Number(el.dataset.retry));if(t&&!s.busy){$('prompt').value=t.prompt;send();}});
  if($('timeline').getClientRects().length){
    $('timeline').scrollTop=following?$('timeline').scrollHeight:chatTop;
    chatTop=$('timeline').scrollTop;
  }
  updateLatest();
}
function updateLatest(){$('latest').hidden=!s.turns.length||!$('timeline').getClientRects().length||$('timeline').scrollHeight-$('timeline').clientHeight-$('timeline').scrollTop<32;}
$('timeline').addEventListener('wheel',()=>following=false,{passive:true});$('timeline').addEventListener('touchstart',()=>following=false,{passive:true});
$('timeline').addEventListener('keydown',e=>{if(['Home','End','PageUp','PageDown','ArrowUp','ArrowDown'].includes(e.key))following=false;});
$('timeline').addEventListener('scroll',()=>{if(!$('timeline').getClientRects().length)return;chatTop=$('timeline').scrollTop;if($('timeline').scrollHeight-$('timeline').clientHeight-chatTop<32)following=true;updateLatest();},{passive:true});
$('latest').onclick=()=>{following=true;$('timeline').scrollTop=$('timeline').scrollHeight;updateLatest();};
function send(){
  const turn=startTurn(s,$('prompt').value);if(!turn)return;
  const scenario=$('scenario').value;$('prompt').value='';following=true;render();
  timers.push(setTimeout(()=>{if(s.busy===turn.id){turn.steps.push('正在等待演示结果；不是模型思维链。');render();}},700));
  timers.push(setTimeout(()=>{completeTurn(s,turn.id,scenario);if(turn.status==='pending')reviewOpen=true;render();if(turn.status==='failed')toast('演示处理失败，详情保留在对话中。');},1600));
}
$('composer').onsubmit=e=>{e.preventDefault();send();};$('send').onclick=()=>{if(s.busy){clearTimers();cancelTurn(s);render();toast('已取消，草稿未改变。');}};
$('prompt').oninput=()=>{$('send').disabled=!s.file||(!$('prompt').value.trim()&&!s.busy);};
$('prompt').onkeydown=e=>{if((e.metaKey||e.ctrlKey)&&e.key==='Enter'){e.preventDefault();send();}};
function openImport(){if(s.busy){toast('请先取消当前处理，再导入配置。');return;}$('import-dialog').showModal();}
$('import').onclick=openImport;$('landing-import').onclick=openImport;$('import-close').onclick=()=>$('import-dialog').close();
function load(subscription){if(s.turns.length&&!confirm('重新导入将清除本轮演示对话与草稿。继续？'))return;clearTimers();reviewDisclosures.clear();importDemo(s,subscription,$('scenario').value==='long');reviewOpen=false;following=true;chatTop=0;$('prompt').value='';$('import-dialog').close();render();toast('示例已载入，可开始对话。未读取真实配置。');$('prompt').focus();}
$('sample-file').onclick=()=>load(false);$('sample-url').onclick=()=>load(true);
$('review-toggle').onclick=()=>{reviewOpen=!reviewOpen;render();};$('review-close').onclick=()=>{reviewOpen=false;render();$('prompt').focus();};$('workbench').onclick=()=>{reviewOpen=false;render();};
$('reset').onclick=()=>{if(s.turns.length&&!confirm('清除本轮演示内容并回到首页？'))return;clearTimers();reviewDisclosures.clear();Object.assign(s,initialState());reviewOpen=false;following=true;chatTop=0;$('prompt').value='';render();};
let dark=matchMedia('(prefers-color-scheme:dark)').matches;
function applyTheme(){document.documentElement.dataset.theme=dark?'dark':'light';$('theme').innerHTML=icon(dark?'sun':'moon');$('theme').setAttribute('aria-label',dark?'切换浅色外观':'切换深色外观');}applyTheme();$('theme').onclick=()=>{dark=!dark;applyTheme();};
function info(title,html){$('info-title').textContent=title;$('info-content').innerHTML=html;$('info-dialog').showModal();}
$('info-close').onclick=()=>$('info-dialog').close();
$('draft-nav').onclick=()=>info('规则稿 · 合成演示',s.file?`<p>只展示当前已确认的演示草稿，候选不计入。未应用到代理。</p><pre>${escape(yaml(s.draft))}</pre>`:'<p>请先导入内置示例配置。</p>');
$('groups-nav').onclick=()=>info('策略组 · 合成演示','<p>日本出口 · 日本<br>美国出口 · 美国<br>香港出口 · 香港</p><p>全部来自内置示例，不代表真实节点、地区或服务解锁。</p>');
$('settings').onclick=()=>info('AI 设置','<p>原型不接入 AI 服务，不提供 API Key 输入，也不会读取已保存的 Key。</p><p>SwiftUI 落地时沿用现有系统钥匙串与匿名请求边界。</p>');
$('mobile-menu').onclick=()=>{info('配置菜单','<div class="inline-actions"><button data-nav="draft-nav">规则稿</button><button data-nav="groups-nav">策略组</button><button data-nav="settings">AI 设置</button></div>');document.querySelectorAll('[data-nav]').forEach(el=>el.onclick=()=>{$('info-dialog').close();$(el.dataset.nav).click();});};
$('export').onclick=()=>{const link=document.createElement('a');const url=URL.createObjectURL(new Blob(['# 合成演示配置；不含节点，不代表可用代理\n'+yaml(s.draft)],{type:'text/yaml'}));link.href=url;link.download='veer-demo-edited.yaml';link.click();setTimeout(()=>URL.revokeObjectURL(url),1000);toast('已导出合成示例，不含真实配置。');};
document.addEventListener('keydown',e=>{if((e.metaKey||e.ctrlKey)&&e.key.toLowerCase()==='o'){e.preventDefault();if(!$('import-dialog').open&&!$('info-dialog').open)openImport();}});
render();
