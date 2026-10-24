import fs from 'node:fs';
import path from 'node:path';

export function createEventLog(directory,{maxBytes=1048576,backups=3}={}) {
  const file=path.join(directory,'wb-retry-events.jsonl');
  // 构建号由 App 通过 WB_RETRY_BUILD 注入；独立运行时退回当前版本号。
  const build=Number(process.env.WB_RETRY_BUILD)||44;
  // Log only explicit metadata. Never include page text, chat identifiers, command output, or credentials.
  const allowed=new Set(['phase','attempts','round','retryEnabled','retryPausedReason','command','code','running','build']);
  return (event,fields={})=>{
    try {
      fs.mkdirSync(directory,{recursive:true,mode:0o700});
      const clean=Object.fromEntries(Object.entries(fields).filter(([key])=>allowed.has(key)));
      const line=JSON.stringify({time:new Date().toISOString(),pid:process.pid,build,event,...clean})+'\n';
      if(fs.existsSync(file) && fs.statSync(file).size+Buffer.byteLength(line)>maxBytes) {
        for(let i=backups;i>=1;i--) {
          const from=i===1?file:`${file}.${i-1}`, to=`${file}.${i}`;
          if(fs.existsSync(from)) fs.renameSync(from,to);
        }
      }
      fs.appendFileSync(file,line,{mode:0o600});
    } catch { /* Diagnostic failures must not stop monitoring. */ }
  };
}
