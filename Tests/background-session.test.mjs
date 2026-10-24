import test from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import {monitorSession} from '../Resources/WorkBuddyRetry/background-session.mjs';
import {createEventLog} from '../Resources/WorkBuddyRetry/event-log.mjs';
const busy={bindingValid:true,sessionBound:true,errorBanners:1,busyBanners:1,retryButtons:1,generating:false};
const generating={...busy,errorBanners:0,busyBanners:0,retryButtons:0,generating:true};
async function simulate({duration=20000,status=()=>busy,check='request_state_observed',control=()=>null}={}){
  let time=0;const reports=[],clicks=[],events=[];
  await monitorSession({now:()=>time,sleep:async ms=>{time+=ms;},stopRequested:()=>time>=duration,
    probe:async click=>{if(click){clicks.push(time);return {clicked:true};}return status(time,clicks);},
    verification:async()=>({pending:false,outcome:check}),report:v=>reports.push({...v,time}),
    event:(name,fields)=>events.push({name,...fields}),readControl:()=>control(time)});
  return {reports,clicks,events,time};
}
test('实际循环在发现后 10 秒点击；生成后继续报告，无多余点击',async()=>{
  const r=await simulate({status:(time,clicks)=>clicks.length?generating:busy});
  assert.deepEqual(r.clicks,[10000]);assert.ok(r.reports.some(s=>s.phase==='进行中'&&s.time>10000));
});
test('十次预算耗尽后循环仍运行、继续报告生成状态，不再点击',async()=>{
  const r=await simulate({duration:175000,status:time=>time>=160000?generating:busy});
  assert.equal(r.clicks.length,10);
  assert.ok(r.reports.some(s=>s.phase==='自动重试已暂停'&&!s.retryEnabled));
  assert.ok(r.reports.some(s=>s.phase==='进行中'&&!s.retryEnabled&&s.time>=160000));
});
test('未确认新请求会暂停点击但保留监控，避免重复发送',async()=>{
  const r=await simulate({duration:40000,check:'no_request_state_observed'});
  assert.equal(r.clicks.length,1);assert.ok(r.reports.some(s=>s.time>30000&&!s.retryEnabled));
});
test('暂停控制在到期点击前生效，重新开启仍从十秒计时',async()=>{
  let paused=false,resumed=false;
  const r=await simulate({duration:35000,control:time=>{
    if(!paused&&time>=10000){paused=true;return {id:'pause',command:'pause-retry'};}
    if(!resumed&&time>=16000){resumed=true;return {id:'resume',command:'resume-retry'};}
    return null;
  }});
  assert.ok(r.reports.some(s=>s.controlAck==='pause'&&!s.retryEnabled));
  assert.ok(r.reports.some(s=>s.controlAck==='resume'&&s.retryEnabled));
  assert.ok(r.clicks.length>=1);assert.ok(r.clicks[0]>=26000);
});
test('绑定失效后退出且不点击任何其他聊天',async()=>{
  const r=await simulate({status:time=>({...busy,bindingValid:time<5000})});
  assert.equal(r.clicks.length,0);assert.ok(r.time<20000);assert.equal(r.events.at(-1).name,'binding_lost');
});
test('事件日志轮转且只保留明确元数据，日志不可写不影响主流程',()=>{
  const dir=fs.mkdtempSync(path.join(os.tmpdir(),'wb-log-test-'));
  try{
    const log=createEventLog(dir,{maxBytes:220,backups:2});
    for(let i=0;i<12;i++)log('retry_clicked',{attempts:i,body:'private-chat',token:'secret'});
    const files=fs.readdirSync(dir);assert.ok(files.length<=3);
    const lines=files.flatMap(f=>fs.readFileSync(path.join(dir,f),'utf8').trim().split('\n'));
    for(const line of lines){const value=JSON.parse(line);assert.equal(value.body,undefined);assert.equal(value.token,undefined);}
    const blocked=path.join(dir,'not-a-directory');fs.writeFileSync(blocked,'x');
    assert.doesNotThrow(()=>createEventLog(blocked)('state_changed'));
  }finally{fs.rmSync(dir,{recursive:true});}
});

test('点击前错误已消失时不记次数、不误报已确认请求',async()=>{
  let time=0;const reports=[];
  await monitorSession({now:()=>time,sleep:async ms=>{time+=ms;},stopRequested:()=>time>=16000,
    probe:async click=>click?{clicked:false,outcome:'not_eligible'}:busy,
    verification:async()=>{throw Error('verification must not run');},report:v=>reports.push(v)});
  assert.ok(reports.every(s=>s.attempts===0));
  assert.ok(reports.every(s=>s.phase!=='已确认同一聊天进入请求中，继续观察'));
});
