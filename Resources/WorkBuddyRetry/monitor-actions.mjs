// Three product actions. Stop acknowledgement precedes any new binding.
export async function performMonitorAction(action, {stopWorker,ensureChannel,startWorker,assertLegacyRetryStopped=()=>{}}, {allowRestart=false}={}) {
  if(!['start','update','stop'].includes(action)) throw Error('不支持的监控操作');
  await stopWorker();
  if(action==='stop') return {phase:'监控停止',running:false};
  // Check the pre-branding lock before any WorkBuddy restart or new chat bind.
  assertLegacyRetryStopped();
  await ensureChannel({allowRestart});
  return await startWorker();
}

export class MonitorActionError extends Error {
  constructor(code,message) {super(message);this.code=code;}
}

export async function prepareChannel({ready,running,quit,launch,assertPortFree,sleep,now}, {allowRestart=false}={}) {
  if(await ready()) return;
  // A conflicting listener cannot be fixed by restarting WB.
  await assertPortFree();
  if(await running()) {
    if(!allowRestart) throw new MonitorActionError('restart_required','需要重新打开 WorkBuddy 后开始监控');
    await quit();
    const deadline=now()+15000;
    while(await running()) {
      if(now()>=deadline) throw new MonitorActionError('quit_pending','WorkBuddy 尚未退出，请处理它的退出确认后再开始监控');
      await sleep(250);
    }
  }
  await assertPortFree();
  await launch();
  const deadline=now()+20000;
  do {
    if(await ready()) return;
    await sleep(500);
  } while(now()<deadline);
  throw new MonitorActionError('connect_timeout','未能连接 WorkBuddy，请稍后再点开始监控');
}
