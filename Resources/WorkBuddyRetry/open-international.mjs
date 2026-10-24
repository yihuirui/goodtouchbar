import {execFileSync} from 'node:child_process';
import net from 'node:net';
import {connect} from './cdp-client.mjs';
import {prepareChannel,MonitorActionError} from './monitor-actions.mjs';
import {currentPort,pickPort,savePort} from './cdp-port.mjs';

const bundle='com.workbuddy.workbuddy-ai';
function jxa(script) {
  return execFileSync('/usr/bin/osascript',['-l','JavaScript','-e',script],{encoding:'utf8',timeout:4000});
}
const applications=`$.NSWorkspace.sharedWorkspace.runningApplications.js.filter(a=>ObjC.unwrap(a.bundleIdentifier)==="${bundle}")`;

function portFree(port) {
  return new Promise((resolve,reject)=>{
    const server=net.createServer();
    server.once('error',()=>reject(new MonitorActionError('port_in_use','监控连接被占用或不可用，请查看运行日志')));
    server.listen(port,'127.0.0.1',()=>server.close(resolve));
  });
}

export async function ensureChannel(options={}) {
  // 端口只在需要重新拉起 WorkBuddy 时才重新挑选：已经活着的那一个继续沿用，
  // 这样"更新监控会话"不会因为换了端口而要求用户重启 WorkBuddy。
  let port=currentPort();
  return prepareChannel({
    ready:async()=>{try {const c=await connect(port);c.close();return true;} catch{return false;}},
    running:async()=>JSON.parse(jxa(`ObjC.import("AppKit"); JSON.stringify(${applications}.length>0);`)),
    quit:async()=>{
      const accepted=JSON.parse(jxa(`ObjC.import("AppKit"); JSON.stringify(${applications}.every(a=>a.terminate));`));
      if(!accepted) throw new MonitorActionError('quit_refused','WorkBuddy 未同意退出，请完成当前任务后再开始监控');
    },
    assertPortFree:()=>portFree(port),
    launch:async()=>{
      port=await pickPort();
      savePort(port);
      return execFileSync('/usr/bin/open',['-g','-a','/Applications/WorkBuddy AI.app',
        '--env',`WORKBUDDY_REMOTE_DEBUGGING_PORT=${port}`,
        '--args','--remote-debugging-address=127.0.0.1',`--remote-debugging-port=${port}`],{timeout:5000});
    },
    sleep:ms=>new Promise(resolve=>setTimeout(resolve,ms)),now:()=>performance.now(),
  },options);
}
