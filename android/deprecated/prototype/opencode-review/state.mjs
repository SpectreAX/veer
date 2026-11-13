export const services = {
  Netflix: ['netflix.com','netflix.net','nflxvideo.net','nflximg.net','nflxso.net','nflxext.com'],
  ChatGPT: ['chatgpt.com','openai.com','oaistatic.com','oaiusercontent.com'],
};
export const initialState = () => ({file:'',turns:[],draft:[],snapshots:[],busy:null,selected:null});
export function importDemo(s, subscription=false, long=false) {
  Object.assign(s, initialState(), {file:subscription?'订阅配置.yaml':long?'veer-demo-跨服务规则分流与长出口名称审阅演示配置.yaml':'veer-demo.yaml'});
}
export function startTurn(s, prompt) {
  if(!s.file || s.busy || !prompt.trim()) return null;
  s.turns.forEach(t=>{if(t.status==='pending')t.status='superseded';});
  const turn={id:s.turns.length+1,prompt:prompt.trim(),status:'running',steps:['已准备匿名演示出口；不包含节点或密钥。'],routes:[],open:false,error:''};
  s.turns.push(turn);s.busy=turn.id;return turn;
}
export function completeTurn(s,id,scenario='normal') {
  const t=s.turns.find(t=>t.id===id);if(s.busy!==id||!t||t.status!=='running')return;
  s.busy=null;
  if(scenario==='error'){t.status='failed';t.error='演示请求失败，草稿没有变化。请重试或切换演示场景。';return;}
  const parts=t.prompt.split(/[，,；;]|\band\b/i).filter(Boolean);
  const region = p => /日本|\bjp\b|japan/i.test(p)?['日本','日本出口']:/美国|\bus\b|america/i.test(p)?['美国','美国出口']:/香港|\bhk\b|hong kong/i.test(p)?['香港','香港出口']:null;
  const routes=[];
  for(const part of parts){
    const names=Object.keys(services).filter(n=>part.toLowerCase().includes(n.toLowerCase()));
    const target=region(part);
    if(!names.length||!target){t.status='failed';t.error='此演示支持 Netflix / ChatGPT 走日本、美国或香港。没有明确服务或出口时不会猜测。';return;}
    for(const name of names){const route={name,region:target[0],target:target[1]+(scenario==='long'?'-跨服务分流策略组-长名称审阅示例-仅用于合成演示':'')};const old=routes.findIndex(r=>r.name===name);if(old>=0)routes[old]=route;else routes.push(route);}
  }
  if(!routes.length){t.status='failed';t.error='请填写明确的服务和出口，例如 Netflix 走日本。';return;}
  t.routes=routes;
  t.before=[...s.draft];t.after=s.draft.filter(rule=>!routes.some(r=>services[r.name].some(domain=>rule.startsWith('DOMAIN-SUFFIX,'+domain+','))));
  t.after.unshift(...routes.flatMap(r=>services[r.name].map(domain=>`DOMAIN-SUFFIX,${domain},${r.target}`)));
  t.steps.push('已生成服务分流候选。','演示校验完成；未执行真实 Mihomo 测试。');t.status='pending';s.selected=id;
}
export function cancelTurn(s){const t=s.turns.find(t=>t.id===s.busy);if(t){t.status='cancelled';t.steps.push('已取消，草稿未改变。');}s.busy=null;}
export function confirmTurn(s,id){const t=s.turns.find(t=>t.id===id);if(s.busy||!t||t.status!=='pending')return false;s.snapshots.push({draft:[...s.draft],id});s.draft=[...t.after];t.status='confirmed';return true;}
export function undoTurn(s,id){const top=s.snapshots.at(-1);if(s.busy||!top||top.id!==id)return false;s.draft=s.snapshots.pop().draft;s.turns.find(t=>t.id===id).status='undone';s.turns.forEach(t=>{if(t.status==='pending')t.status='superseded';});return true;}
export const yaml = rules => 'rules:\n'+[...rules,'MATCH,DIRECT'].map(r=>'  - '+r).join('\n')+'\n';
export function diffLines(t){return ['  rules:',...(t.before??[]).filter(r=>!(t.after??[]).includes(r)).map(r=>'−   - '+r),...(t.after??[]).filter(r=>!(t.before??[]).includes(r)).map(r=>'+   - '+r),'    - MATCH,DIRECT'];}
