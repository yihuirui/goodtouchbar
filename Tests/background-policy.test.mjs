import test from 'node:test';
import assert from 'node:assert/strict';
import {BackgroundPolicy} from '../Resources/WorkBuddyRetry/background-policy.mjs';
const busy={bindingValid:true,sessionBound:true,errorBanners:1,busyBanners:1,retryButtons:1,generating:false};
const idle={...busy,errorBanners:0,busyBanners:0,retryButtons:0};
const generating={...idle,generating:true};

test('每次都固定 10 秒，从首轮发现开始；确认两轮且不抢跑',()=>{
  const p=new BackgroundPolicy();
  for(let n=0;n<3;n++){
    const start=n*11000;
    assert.equal(p.observe(busy,start).retry,false);
    assert.equal(p.observe(busy,start+1000).seconds,9);
    assert.equal(p.observe(busy,start+9999).retry,false);
    assert.equal(p.observe(busy,start+10000).retry,true);
    p.submitted();
  }
  assert.equal(p.attempts,3);
});
test('错误消失、多按钮、生成中均取消倒计时并重新确认',()=>{
  for(const invalid of [idle,{...busy,retryButtons:2},generating]){
    const p=new BackgroundPolicy();p.observe(busy,0);p.observe(busy,1000);
    assert.notEqual(p.observe(invalid,10000).retry,true);
    assert.equal(p.observe(busy,11000).seconds,10);
    assert.equal(p.observe(busy,12000).seconds,9);
    assert.equal(p.observe(busy,21000).retry,true);
  }
});
test('切换聊天或页面重载永久停止，手动恢复也不得重新绑定',()=>{
  const p=new BackgroundPolicy();assert.equal(p.observe({...busy,bindingValid:false},0).stop,true);
  assert.equal(p.resume(),false);assert.equal(p.observe(busy,1000).stop,true);
});
test('20 分钟或 10 次只暂停点击，正在生成的状态继续更新',()=>{
  const p=new BackgroundPolicy();p.observe(busy,0);p.observe(generating,1199999);
  const reached=p.observe(generating,1200000);
  assert.equal(reached.phase,'进行中');assert.equal(reached.stop,undefined);assert.ok(p.pausedReason);
  assert.equal(p.observe(busy,1201000).phase,'自动重试已暂停');
  const q=new BackgroundPolicy();for(let i=0;i<10;i++)q.submitted();
  assert.equal(q.observe(busy,0).retry,false);assert.equal(q.observe(generating,1000).phase,'进行中');
});
test('短暂恢复不补充预算，连续正常生成两分钟才结束一轮',()=>{
  const p=new BackgroundPolicy();p.observe(busy,0);p.submitted();
  p.observe(generating,1000);p.observe(idle,2000);p.observe(busy,5000);
  assert.equal(p.attempts,1);assert.equal(p.firstBusy,0);
  p.observe(generating,6000);p.observe(generating,125999);assert.equal(p.attempts,1);
  p.observe(generating,126000);assert.equal(p.attempts,0);assert.equal(p.firstBusy,null);
});
test('生成结束后连续 30 秒无错误才结束一轮，错误会中断恢复',()=>{
  const p=new BackgroundPolicy();p.observe(busy,0);p.submitted();p.observe(generating,1000);
  p.observe(idle,2000);p.observe({...idle,errorBanners:1},31000);p.observe(idle,40000);
  assert.equal(p.attempts,1);
  p.observe(generating,41000);p.observe(idle,42000);p.observe(idle,71999);assert.equal(p.attempts,1);
  p.observe(idle,72000);assert.equal(p.attempts,0);
});
test('暂停后即使恢复也不自动开启，显式恢复重建一轮且仍需二次确认',()=>{
  const p=new BackgroundPolicy();p.observe(busy,0);p.pause();
  p.observe(generating,1000);p.observe(generating,200000);assert.ok(p.pausedReason);
  assert.equal(p.resume(),true);assert.equal(p.pausedReason,null);
  assert.equal(p.observe(busy,201000).retry,false);assert.equal(p.observe(busy,202000).seconds,9);
});

import {retryableModelError, pageProbe} from '../Resources/WorkBuddyRetry/background-probe.mjs';
test('只重试临时模型错误，排除需人工处理的错误',()=>{
  for(const text of ['模型繁忙 14003','模型超时，请重试','Model temporarily unavailable','Service unavailable','模型过载']) assert.equal(retryableModelError(text),true,text);
  for(const text of ['额度不足','登录失效 14003','用户取消','Context length limit','模型不存在','网络连接已断开','401 unauthorized','余额不足']) assert.equal(retryableModelError(text),false,text);
});
test('生成结束后显示完成，30 秒后待命；错误时不误报完成',()=>{
  const p=new BackgroundPolicy(); const idle={...busy,errorBanners:0,busyBanners:0,retryButtons:0};
  assert.equal(p.observe({...idle,generating:true},0).phase,'进行中');
  assert.equal(p.observe(idle,1000).phase,'已完成');
  assert.equal(p.observe(idle,31000).phase,'待命');
  p.observe({...idle,generating:true},32000);
  assert.equal(p.observe({...idle,errorBanners:1},33000).phase,'模型报错，需人工处理');
});
test('已绑定聊天的唯一可重试错误才执行按钮，生成或多个错误框时不执行',()=>{
  let clicked=0, generating=false, count=1;
  const button={isConnected:true,getClientRects:()=>[1],getAttribute:()=>null,innerText:'重试',click:()=>{clicked++;generating=true;}};
  const banner={...button,innerText:'模型繁忙 14003',querySelectorAll:()=>[button]};
  const selected={className:'selected',getAttribute:()=> 'chat-one',querySelectorAll:()=>[]};
  globalThis.getComputedStyle=()=>({visibility:'visible'});
  globalThis.MutationObserver=class {observe(){} disconnect(){}};
  globalThis.window={};globalThis.document={body:{},hasFocus:()=>false,querySelectorAll:(selector)=>{
    if(selector==='[data-conversation-id]')return [selected];
    if(selector==='.cr-send-button--stop')return generating?[button]:[];
    return Array(count).fill(banner);
  }};
  pageProbe(false,'bind',retryableModelError);
  count=2;assert.equal(pageProbe(true,'require',retryableModelError).clicked,false);
  count=1;generating=true;assert.equal(pageProbe(true,'require',retryableModelError).clicked,false);
  generating=false;assert.equal(pageProbe(true,'require',retryableModelError).clicked,true);
  assert.equal(clicked,1);assert.equal(window.__workbuddyRetryVerification.outcome,'request_state_observed');
  generating=false;window.__workbuddyRetryBinding.valid=false;
  assert.equal(pageProbe(true,'require',retryableModelError).clicked,false);
});
