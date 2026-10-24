export class BackgroundPolicy {
  attempts=0; firstBusy=null; stable=0; due=null; halted=null;
  wasGenerating=false; completedAt=null; healthySince=null; pausedReason=null; round=1;
  resetRound() {
    this.attempts=0; this.firstBusy=null; this.stable=0; this.due=null;
    this.healthySince=null; this.completedAt=null; this.wasGenerating=false; this.round++;
  }
  pause(reason='已手动暂停自动重试') { this.pausedReason=reason; this.cancel(); }
  resume() {
    if(this.halted) return false;
    this.resetRound(); this.pausedReason=null; return true;
  }
  observe(state,now) {
    if(this.halted) return {phase:this.halted,stop:true};
    if(!state.bindingValid || !state.sessionBound) return this.halt('聊天已切换或页面重载，请重新绑定');
    const errors=state.errorBanners ?? state.busyBanners ?? 0;
    const busy=errors===1 && state.busyBanners===1 && state.retryButtons===1 && !state.generating;
    // Exhaustion pauses clicking, but never ends observation of the bound chat.
    if(!this.pausedReason) {
      if(this.attempts>=10) this.pause('已达本轮 10 次重试上限');
      else if(this.firstBusy!==null && now-this.firstBusy>=1200000) this.pause('已达本轮 20 分钟上限');
    }
    let phase;
    if(state.generating) {
      this.cancel(); this.wasGenerating=true; this.completedAt=null;
      if(errors===0) this.healthySince ??= now; else this.healthySince=null;
      // Only sustained recovery ends a round. Brief generating flashes do not replenish it.
      if(!this.pausedReason && this.firstBusy!==null && this.healthySince!==null && now-this.healthySince>=120000) {
        this.resetRound(); this.wasGenerating=true; this.healthySince=now;
      }
      phase='进行中';
    } else if(errors===0) {
      this.cancel(); this.healthySince=null;
      if(this.wasGenerating) { this.wasGenerating=false; this.completedAt=now; }
      if(!this.pausedReason && this.firstBusy!==null && this.completedAt!==null && now-this.completedAt>=30000) this.resetRound();
      phase=this.completedAt!==null && now-this.completedAt<30000?'已完成':'待命';
    } else {
      this.healthySince=null; this.wasGenerating=false; this.completedAt=null;
      if(busy && !this.pausedReason) {
        this.firstBusy ??= now;
        // Ten seconds from first observation, including the second confirmation poll.
        this.due ??= now+10000;
        this.stable++;
        return {phase:this.stable<2?'确认模型错误':'等待后台重试',
          seconds:Math.max(0,Math.ceil((this.due-now)/1000)),retry:this.stable>=2 && now>=this.due};
      }
      this.cancel(); phase=busy?'自动重试已暂停':'模型报错，需人工处理';
    }
    return {phase,retry:false};
  }
  submitted(){this.attempts++;this.cancel();}
  cancel(){this.stable=0;this.due=null;}
  halt(phase){this.halted=phase;this.due=null;return {phase,stop:true};}
}
