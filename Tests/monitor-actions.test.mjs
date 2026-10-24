import test from 'node:test';
import assert from 'node:assert/strict';
import {performMonitorAction,prepareChannel,MonitorActionError} from '../Resources/WorkBuddyRetry/monitor-actions.mjs';

for(const action of ['start','update']) test(`${action} waits for old worker stop, then prepares and binds exactly once`,async()=>{
  const calls=[];let stopped=false;
  const result=await performMonitorAction(action,{
    stopWorker:async()=>{await Promise.resolve();stopped=true;calls.push('stop');},
    ensureChannel:async options=>{assert.ok(stopped);assert.equal(options.allowRestart,false);calls.push('prepare');},
    startWorker:async()=>{calls.push('bind');return {running:true};}
  });
  assert.deepEqual(calls,['stop','prepare','bind']);assert.equal(result.running,true);
});
test('stop never opens WB or binds a chat',async()=>{
  const result=await performMonitorAction('stop',{stopWorker:async()=>{},
    ensureChannel:async()=>assert.fail('must not connect'),startWorker:async()=>assert.fail('must not start')});
  assert.equal(result.running,false);
});
test('old worker stop failure prevents any new binding or WB restart',async()=>{
  await assert.rejects(performMonitorAction('update',{stopWorker:async()=>{throw Error('stop failed');},
    ensureChannel:async()=>assert.fail('must not prepare'),startWorker:async()=>assert.fail('must not bind')}),/stop failed/);
});
test('restart-required is propagated to UI without starting a worker',async()=>{
  await assert.rejects(performMonitorAction('start',{stopWorker:async()=>{},
    ensureChannel:async()=>{throw new MonitorActionError('restart_required','restart');},
    startWorker:async()=>assert.fail('must not bind')}),e=>e.code==='restart_required');
});
function channel({running=true,ready=false,quitCompletes=true,portFree=true}={}) {
  let time=0,isRunning=running,isReady=ready;const calls=[];
  const deps={ready:async()=>isReady,running:async()=>isRunning,
    quit:async()=>{calls.push('quit');if(quitCompletes)isRunning=false;},
    launch:async()=>{calls.push('launch');isRunning=true;isReady=true;},
    assertPortFree:async()=>{if(!portFree)throw new MonitorActionError('port_in_use','occupied');},
    sleep:async ms=>{time+=ms;},now:()=>time};
  return {deps,calls};
}
test('connected WB is reused without restart',async()=>{
  const c=channel({ready:true});await prepareChannel(c.deps);assert.deepEqual(c.calls,[]);
});
test('running WB without channel requires consent and is not terminated',async()=>{
  const c=channel();await assert.rejects(prepareChannel(c.deps),e=>e.code==='restart_required');assert.deepEqual(c.calls,[]);
});
test('explicit consent performs normal quit then launch and verifies channel',async()=>{
  const c=channel();await prepareChannel(c.deps,{allowRestart:true});assert.deepEqual(c.calls,['quit','launch']);
});
test('WB waiting for quit confirmation prevents replacement launch',async()=>{
  const c=channel({quitCompletes:false});await assert.rejects(prepareChannel(c.deps,{allowRestart:true}),e=>e.code==='quit_pending');
  assert.deepEqual(c.calls,['quit']);
});
test('stopped WB launches directly, port conflict never quits an app',async()=>{
  const c=channel({running:false});await prepareChannel(c.deps);assert.deepEqual(c.calls,['launch']);
  const conflict=channel({portFree:false});await assert.rejects(prepareChannel(conflict.deps,{allowRestart:true}),e=>e.code==='port_in_use');
  assert.deepEqual(conflict.calls,[]);
});
test('launch without a usable channel reports timeout and never binds',async()=>{
  const c=channel({running:false});c.deps.launch=async()=>c.calls.push('launch');
  await assert.rejects(prepareChannel(c.deps),e=>e.code==='connect_timeout');
});
