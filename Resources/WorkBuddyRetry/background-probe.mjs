import {connect} from './cdp-client.mjs';

export function retryableModelError(text) {
  if (/登录|认证|余额|额度|付费|权限|上下文|内容安全|取消|unauthori[sz]ed|forbidden|quota|credit|billing|context.{0,20}(?:length|limit)|cancelled/i.test(text)) return false;
  return /(?:^|\D)14003(?:\D|$)/.test(text) ||
    /模型.{0,30}(?:繁忙|拥堵|过载|超时|暂时不可用)|model.{0,40}(?:busy|capacity|overload|timeout|temporarily unavailable)|服务.{0,15}(?:繁忙|过载|暂时不可用)|service (?:unavailable|overloaded)|gateway timeout/i.test(text);
}

// Runs within the already loaded international renderer. No focus or mouse APIs.
export function pageProbe(click = false, bindingMode = 'none', classify = null) {
  const visible = e => e.isConnected && e.getClientRects().length > 0 && getComputedStyle(e).visibility !== 'hidden';
  const session = () => {
    const ids = new Set([...document.querySelectorAll('[data-conversation-id]')].filter(e=>
      /(?:^|\s|_)selected(?:\s|_|$)/.test(e.className) || e.getAttribute('aria-selected') === 'true' ||
      [...e.querySelectorAll('[class],[aria-selected]')].some(x=>
        /(?:^|\s|_)selected(?:\s|_|$)/.test(x.className) || x.getAttribute('aria-selected') === 'true')
    ).map(e=>e.getAttribute('data-conversation-id')).filter(Boolean));
    return ids.size === 1 ? [...ids][0] : null;
  };
  const generating = () => [...document.querySelectorAll('.cr-send-button--stop')].some(visible);
  const banners = [...document.querySelectorAll('[data-testid="wb-error-banner"]')].filter(visible);
  const busy = banners.filter(e => classify ? classify(e.innerText) :
    /(?:^|\D)14003(?:\D|$)/.test(e.innerText));
  const buttons = busy.flatMap(e=>[...e.querySelectorAll('button')]).filter(e=>visible(e) &&
    banners.length === 1 && !e.disabled && e.getAttribute('aria-disabled') !== 'true' && /^(重试|retry|try again)$/i.test(e.innerText.trim()));
  const id = session();
  if(bindingMode === 'bind') {
    window.__workbuddyRetryBinding?.observer?.disconnect();
    const binding = {id,valid:!!id};
    binding.observer = new MutationObserver(()=>{
      if(session() !== binding.id) binding.valid = false;
    });
    binding.observer.observe(document.body,{subtree:true,childList:true,attributes:true,
      attributeFilter:['class','aria-selected','data-conversation-id']});
    window.__workbuddyRetryBinding = binding;
  }
  const binding = window.__workbuddyRetryBinding;
  const bindingValid = bindingMode === 'none' || !!(binding?.valid && id && id === binding.id);
  const status = {errorBanners:banners.length,background:!document.hasFocus(),sessionBound:!!id,busyBanners:busy.length,
    retryButtons:buttons.length,generating:generating(),bindingValid,clicked:false};
  if(!click) return status;
  if(!bindingValid) return {...status,outcome:'session_changed_unconfirmed'};
  if(!id || busy.length !== 1 || buttons.length !== 1 || status.generating) return {...status,outcome:'not_eligible'};
  if(window.__workbuddyRetryVerification?.pending) return {...status,outcome:'already_verifying'};
  const verification = {pending:true,outcome:'awaiting_request_state',clickedAt:Date.now()};
  window.__workbuddyRetryVerification = verification;
  let observer, timer;
  const finish = outcome => {verification.pending=false;verification.outcome=outcome;observer?.disconnect();clearTimeout(timer);};
  const check = () => {
    if(session() !== id) return finish('session_changed_unconfirmed');
    if(generating()) return finish('request_state_observed');
  };
  observer = new MutationObserver(check);
  observer.observe(document.body,{subtree:true,childList:true,attributes:true,attributeFilter:['class','aria-selected','disabled']});
  timer = setTimeout(()=>finish('no_request_state_observed'),15000);
  try { buttons[0].click(); check(); return {...status,clicked:true,outcome:verification.outcome}; }
  catch { finish('click_failed'); return {...status,outcome:'click_failed'}; }
}

if (process.argv[1] && import.meta.url === new URL(`file://${process.argv[1]}`).href) {
  const mode=process.argv[2] ?? '--inspect';
  if(!['--inspect','--retry-once'].includes(mode)) throw Error('使用 --inspect 或 --retry-once');
  const c=await connect();
  try {
    const result=await c.evaluate(`(${pageProbe.toString()})(${mode==='--retry-once'},'none',(${retryableModelError.toString()}))`);
    console.log(JSON.stringify(result));
    if(result.clicked) {
      for(let i=0;i<34;i++) {
        await new Promise(r=>setTimeout(r,500));
        const v=await c.evaluate('(()=>{const v=window.__workbuddyRetryVerification;return v?{pending:v.pending,outcome:v.outcome}:null})()');
        if(!v || !v.pending) {console.log(JSON.stringify(v ?? {outcome:'page_reloaded_unconfirmed'}));break;}
      }
    }
  } finally {c.close();}
}
