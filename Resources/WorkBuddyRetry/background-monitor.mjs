import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import {fileURLToPath} from 'node:url';
import {spawn} from 'node:child_process';
import {connect} from './cdp-client.mjs';
import {pageProbe, retryableModelError} from './background-probe.mjs';
import {monitorSession} from './background-session.mjs';
import {createEventLog} from './event-log.mjs';
import {randomUUID} from 'node:crypto';
import {performMonitorAction,MonitorActionError} from './monitor-actions.mjs';
import {ensureChannel} from './open-international.mjs';
import {assertLegacyRetryStopped,legacyRetryLockPath,isProcessAlive,LegacyRetryOwnerError,LegacyRetryLockReadError} from './legacy-owner.mjs';

if(Number(process.versions.node.split('.')[0])<22) throw Error('需要 Node.js 22 或更新版本');

const dir=path.join(os.homedir(),'Library/Application Support/GoodTouchBar/WorkBuddyRetry');
const statusFile=path.join(dir,'background-status.json');
const lockFile=path.join(dir,'background.lock');
const stopFile=path.join(dir,'background-stop');
const controlFile=path.join(dir,'background-control.json');
const legacyLockFile=legacyRetryLockPath(os.homedir());
const event=createEventLog(path.join(os.homedir(),'Library/Logs/GoodTouchBar'));
const ownFile=fileURLToPath(import.meta.url);
const sleep=ms=>new Promise(r=>setTimeout(r,ms));
function readStatus(){try{return JSON.parse(fs.readFileSync(statusFile,'utf8'));}catch{return {running:false,phase:'尚未启动后台监控'};}}
function alive(pid){return isProcessAlive(pid);}
function ensureLegacyRetryStopped(){
  assertLegacyRetryStopped({lockFile:legacyLockFile,readFile:fs.readFileSync,alive});
}
function locked(){try{return alive(Number(fs.readFileSync(lockFile,'utf8')));}catch{return false;}}
function save(value){fs.writeFileSync(statusFile+'.tmp',JSON.stringify({...value,updatedAt:new Date().toISOString()},null,2),{mode:0o600});fs.renameSync(statusFile+'.tmp',statusFile);}

async function run(){
  fs.mkdirSync(dir,{recursive:true});
  if(locked()) throw Error('已有后台监控运行');
  // Never unlink a lock in the acquisition path: concurrent starts must not
  // delete the first starter's freshly-created lock.
  if(fs.existsSync(lockFile)) throw Error('存在已退出进程的锁，请先运行“停止后台重试”再启动');
  try {
    ensureLegacyRetryStopped();
  } catch(error) {
    event('legacy_owner_blocked');
    save({running:false,pid:process.pid,protocolVersion:2,build:Number(process.env.WB_RETRY_BUILD)||1,
      attempts:0,confirmedRequests:0,phase:error.message,error:true});
    return;
  }
  const fd=fs.openSync(lockFile,'wx',0o600);fs.writeSync(fd,String(process.pid));fs.closeSync(fd);
  try{fs.unlinkSync(stopFile);}catch{}
  let c,stopping=false;
  let state={running:true,pid:process.pid,sessionID:randomUUID(),protocolVersion:2,build:Number(process.env.WB_RETRY_BUILD)||1,attempts:0,confirmedRequests:0,phase:'正在连接国际版'};
  let lastTransition=null;
  process.on('SIGTERM',()=>{stopping=true});process.on('SIGINT',()=>{stopping=true});
  const stopRequested=()=>stopping||fs.existsSync(stopFile);
  const report=patch=>{
    state={...state,...patch};save(state);
    const summary={phase:state.phase,attempts:state.attempts,round:state.round,
      retryEnabled:state.retryEnabled,retryPausedReason:state.retryPausedReason,running:state.running};
    const key=JSON.stringify(summary);
    if(key!==lastTransition){event('state_changed',summary);lastTransition=key;}
  };
  const readControl=()=>{
    try {
      const request=JSON.parse(fs.readFileSync(controlFile,'utf8'));
      fs.unlinkSync(controlFile);
      if(request.pid!==process.pid || request.sessionID!==state.sessionID ||
         typeof request.id!=='string' || !['pause-retry','resume-retry'].includes(request.command)) return null;
      return request;
    } catch { return null; }
  };
  try{
    report({});c=await connect();
    const probe=(click=false,mode='require')=>c.evaluate(`(${pageProbe.toString()})(${click},${JSON.stringify(mode)},(${retryableModelError.toString()}))`);
    ensureLegacyRetryStopped();
    const initial=await probe(false,'bind');
    if(!initial.bindingValid) throw Error('无法唯一绑定当前聊天，请先打开要监控的聊天');
    event('chat_bound');
    await monitorSession({probe,
      verification:()=>c.evaluate('(()=>{const v=window.__workbuddyRetryVerification;return v?{pending:v.pending,outcome:v.outcome}:null})()'),
      report,readControl,event,stopRequested,sleep,now:()=>performance.now(),beforeClick:ensureLegacyRetryStopped});
  }catch(error){
    const known=new Map([
      ['连接超时','connect_timeout'],['连接失败','connect_failed'],['连接已关闭','connection_closed'],
      ['指令超时','command_timeout'],['页面检查脚本失败','page_probe_failed'],
      ['调试端口归属不唯一','ambiguous_port'],['端口不属于国际版或未限定本机','invalid_port_owner'],
      ['无法唯一绑定国际版主页面','ambiguous_page'],['无法唯一绑定当前聊天，请先打开要监控的聊天','ambiguous_chat']]);
    const code=error.code??known.get(error.message)??'connection_or_probe_failed';
    event(code==='legacy_retry_active'||code==='legacy_retry_lock_unreadable'?'legacy_owner_blocked':'monitor_failed',{code});
    const phase=code==='legacy_retry_active'||code==='legacy_retry_lock_unreadable'
      ? error.message
      : code==='ambiguous_chat'?'请在 WorkBuddy 中打开要监控的聊天，再点更新监控会话':'连接异常，请点开始监控';
    report({phase,error:true});
  }
  finally{
    c?.close();report({running:false,seconds:null});
    try{if(Number(fs.readFileSync(lockFile,'utf8'))===process.pid)fs.unlinkSync(lockFile);}catch{}
  }
}

async function stopWorker() {
  fs.mkdirSync(dir,{recursive:true});
  fs.writeFileSync(stopFile,'stop',{mode:0o600});
  const deadline=performance.now()+12000;
  while(locked()) {
    if(performance.now()>=deadline) throw new MonitorActionError('stop_timeout','旧监控尚未停止，请稍后再试');
    await sleep(250);
  }
  // Stale locks are removed only after confirming their owner is no longer alive.
  if(fs.existsSync(lockFile) && !locked()) fs.unlinkSync(lockFile);
  save({...readStatus(),running:false,phase:'监控停止',seconds:null,retryEnabled:false,error:false});
  event('monitor_stopped');
}

async function startWorker() {
  const child=spawn(process.execPath,[ownFile,'run'],{detached:true,stdio:'ignore'});
  let spawnError=null;child.on('error',error=>{spawnError=error;});child.unref();
  for(let i=0;i<48;i++) {
    await sleep(250);
    if(spawnError) throw new MonitorActionError('spawn_failed','无法启动监控进程');
    const state=readStatus();
    if(state.pid===child.pid && state.phase!=='正在连接国际版') {
      if(!state.running || state.error) throw new MonitorActionError('bind_failed',state.phase);
      return state;
    }
    if(child.pid && !alive(child.pid)) break;
  }
  // Do not leave a late-starting worker clicking after the UI reports a failed start.
  await stopWorker();
  throw new MonitorActionError('start_timeout','未确认监控启动，请重新开始');
}

function acquireActionLock() {
  fs.mkdirSync(dir,{recursive:true});
  const file=path.join(dir,'monitor-action.lock');
  try { fs.writeFileSync(file,String(process.pid),{flag:'wx',mode:0o600}); }
  catch(error) {
    if(error.code!=='EEXIST') throw error;
    const owner=Number(fs.readFileSync(file,'utf8'));
    if(!Number.isInteger(owner) || owner<=0 || alive(owner)) throw new MonitorActionError('operation_busy','监控操作进行中，请稍候');
    fs.unlinkSync(file);
    fs.writeFileSync(file,String(process.pid),{flag:'wx',mode:0o600});
  }
  return ()=>{try {if(Number(fs.readFileSync(file,'utf8'))===process.pid)fs.unlinkSync(file);}catch{}};
}

const command=process.argv[2]??'status';
if(command==='run') await run();
else if(command==='status') console.log(JSON.stringify({...readStatus(),running:locked()}));
else {
  let release;
  try {
    release=acquireActionLock();
    const state=await performMonitorAction(command,{stopWorker,ensureChannel,startWorker,assertLegacyRetryStopped:ensureLegacyRetryStopped},
      {allowRestart:process.argv.includes('--allow-restart')});
    console.log(JSON.stringify({ok:true,...state}));
  } catch(error) {
    const code=error.code??'operation_failed';
    event('action_failed',{code,command});
    const message=error instanceof MonitorActionError || error instanceof LegacyRetryOwnerError || error instanceof LegacyRetryLockReadError
      ? error.message
      : '监控操作失败，请检查 Node.js 和运行日志';
    console.log(JSON.stringify({ok:false,code,message}));process.exitCode=1;
  } finally {release?.();}
}
