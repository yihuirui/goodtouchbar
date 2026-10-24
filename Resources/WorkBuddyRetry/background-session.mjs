import {BackgroundPolicy} from './background-policy.mjs';

// Dependency injection keeps the actual worker loop testable without opening or clicking real chats.
export async function monitorSession({probe,verification,report,stopRequested,sleep,now,
  readControl=()=>null,event=()=>{},beforeClick=()=>{}}) {
  const policy=new BackgroundPolicy();
  let confirmedRequests=0, controlAck=null;
  const publish=patch=>report({attempts:policy.attempts,round:policy.round,
    retryEnabled:!policy.pausedReason,retryPausedReason:policy.pausedReason,
    roundElapsedSeconds:policy.firstBusy===null?null:Math.floor((now()-policy.firstBusy)/1000),
    retryDelaySeconds:10,confirmedRequests,controlAck,...patch});
  const applyControl=()=>{
    const request=readControl();
    if(!request) return;
    if(request.command==='pause-retry') policy.pause();
    else if(request.command==='resume-retry') policy.resume();
    else return;
    controlAck=request.id; event('control',{command:request.command});
    publish({seconds:null,phase:request.command==='pause-retry'?'自动重试已暂停':'正在检查聊天'}); // Acknowledge even during verification.
  };
  while(!stopRequested()) {
    applyControl();
    const status=await probe();
    const decision=policy.observe(status,now());
    publish({phase:decision.phase,seconds:decision.seconds??null,
      errorBanners:status.errorBanners??0,background:status.background,
      generating:status.generating,busy:status.busyBanners===1});
    if(decision.stop) { event('binding_lost'); return; }
    if(decision.retry) {
      let verified=false;
      // A pause that arrived during observation must win over a due click.
      applyControl();
      if(stopRequested()) break;
      if(!policy.pausedReason) {
        try {
          await beforeClick();
        } catch (error) {
          policy.pause(error?.message || '检测到旧版重试通道，自动点击已暂停');
          event('legacy_owner_blocked');
        }
        if(!policy.pausedReason) {
          const result=await probe(true);
          if(!result.clicked) {
            policy.cancel();
            if(result.outcome!=='not_eligible') {
              policy.pause('未确认安全重试条件，请检查聊天');
              event('retry_rejected');
            }
          } else {
            policy.submitted(); event('retry_clicked',{attempts:policy.attempts});
            publish({phase:'已触发重试，确认同一聊天请求状态',seconds:null});
            let checked=null;
            for(let i=0;i<34 && !stopRequested();i++) {
              await sleep(500); applyControl(); checked=await verification();
              if(!checked?.pending) break;
            }
            if(stopRequested()) break;
            if(checked?.outcome!=='request_state_observed') {
              policy.pause('未确认新的请求状态，自动重试已暂停'); event('retry_unconfirmed');
            } else { verified=true; confirmedRequests++; event('retry_confirmed'); }
          }
        }
      }
      publish({phase:policy.pausedReason?'自动重试已暂停':(verified?'已确认同一聊天进入请求中，继续观察':'正在检查聊天'),seconds:null});
    }
    // One-second cadence only while counting down; otherwise observe every three seconds.
    await sleep(policy.due!==null?1000:3000);
  }
  publish({phase:'已手动停止监控',seconds:null});
}
