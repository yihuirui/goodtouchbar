// Local-only CDP transport. No connector, external request, or saved chat data.
import {execFileSync} from 'node:child_process';
import {currentPort} from './cdp-port.mjs';

export function endpoint(port = currentPort()) {
  return `http://127.0.0.1:${port}`;
}

export function verifyOwner(port = currentPort()) {
  const script = 'ObjC.import("AppKit"); JSON.stringify($.NSWorkspace.sharedWorkspace.runningApplications.js.filter(a=>ObjC.unwrap(a.bundleIdentifier)==="com.workbuddy.workbuddy-ai").map(a=>a.processIdentifier));';
  const pids = JSON.parse(execFileSync('/usr/bin/osascript', ['-l','JavaScript','-e',script], {encoding:'utf8',timeout:3000}));
  const listeners = execFileSync('/usr/sbin/lsof', ['-nP',`-iTCP:${port}`,'-sTCP:LISTEN'], {encoding:'utf8',timeout:3000}).trim().split('\n').slice(1);
  if (listeners.length !== 1) throw Error('调试端口归属不唯一');
  const fields = listeners[0].trim().split(/\s+/);
  if (!pids.includes(Number(fields[1])) || !listeners[0].includes(`127.0.0.1:${port} (LISTEN)`)) throw Error('端口不属于国际版或未限定本机');
}

export async function connect(port = currentPort()) {
  verifyOwner(port);
  const pages = await fetch(`${endpoint(port)}/json/list`, {signal:AbortSignal.timeout(3000)}).then(r=>r.json());
  const candidates = pages.filter(p=>{
    try { const u=new URL(p.url); return p.type==='page' && u.protocol==='file:' &&
      decodeURIComponent(u.pathname)==='/Applications/WorkBuddy AI.app/Contents/Resources/app.asar/renderer/index.html'; }
    catch { return false; }
  });
  if(candidates.length!==1) throw Error('无法唯一绑定国际版主页面');
  const target=candidates[0];
  const url=new URL(target.webSocketDebuggerUrl);
  if(url.protocol!=='ws:' || url.hostname!=='127.0.0.1' || url.port!==String(port)) throw Error('拒绝非本机调试地址');
  const ws = new WebSocket(url);
  await new Promise((resolve,reject)=>{
    const t=setTimeout(()=>{ws.close();reject(Error('连接超时'));},3000);
    ws.addEventListener('open',()=>{clearTimeout(t);resolve();},{once:true});
    ws.addEventListener('error',()=>{clearTimeout(t);reject(Error('连接失败'));},{once:true});
  });
  let next=0; const pending=new Map();
  ws.addEventListener('message', event=>{
    const packet=JSON.parse(event.data); const item=pending.get(packet.id);
    if(!item)return;pending.delete(packet.id);clearTimeout(item.timer);
    packet.error?item.reject(Error(packet.error.message)):item.resolve(packet.result);
  });
  ws.addEventListener('close',()=>{for(const item of pending.values()){clearTimeout(item.timer);item.reject(Error('连接已关闭'));}pending.clear();});
  const call=(method,params={})=>new Promise((resolve,reject)=>{
    const id=++next;
    const timer=setTimeout(()=>{pending.delete(id);reject(Error('指令超时'));},5000);
    pending.set(id,{resolve,reject,timer});ws.send(JSON.stringify({id,method,params}));
  });
  return {targetID:target.id,call,close:()=>ws.close(), async evaluate(expression){
    const result=await call('Runtime.evaluate',{expression,returnByValue:true,awaitPromise:true});
    if(result.exceptionDetails) throw Error('页面检查脚本失败');
    return result.result.value;
  }};
}
