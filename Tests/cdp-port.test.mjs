import test from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import {createPortStore,fallbackPort,pickPort} from '../Resources/WorkBuddyRetry/cdp-port.mjs';

function store(initial) {
  const dir=fs.mkdtempSync(path.join(os.tmpdir(),'cdp-port-'));
  const file=path.join(dir,'cdp-port');
  if(initial!==undefined) fs.writeFileSync(file,String(initial));
  const env={};
  return {file,env,store:createPortStore(file,env)};
}

test('没有状态文件也没有环境变量时回退到默认端口', () => {
  const {store:s}=store();
  assert.equal(s.readPort(),null);
  assert.equal(s.currentPort(),fallbackPort);
});

test('保存后能读回，并同步到环境变量供子进程继承', () => {
  const {store:s,env}=store();
  s.savePort(24567);
  assert.equal(s.readPort(),24567);
  assert.equal(env.WB_RETRY_CDP_PORT,'24567');
});

test('环境变量优先于状态文件', () => {
  const {store:s,env}=store(24567);
  env.WB_RETRY_CDP_PORT='30111';
  assert.equal(s.readPort(),30111);
});

test('非法端口不会被采纳', () => {
  const {store:s,env}=store('abc');
  assert.equal(s.currentPort(),fallbackPort);
  env.WB_RETRY_CDP_PORT='80';
  assert.equal(s.currentPort(),fallbackPort);
  assert.throws(()=>s.savePort(0),/端口无效/);
  assert.throws(()=>s.savePort(70000),/端口无效/);
  assert.throws(()=>s.savePort('abc'),/端口无效/);
});

test('clearPort 同时清掉文件与环境变量', () => {
  const {store:s,env,file}=store();
  s.savePort(24567);
  s.clearPort();
  assert.equal(fs.existsSync(file),false);
  assert.equal(env.WB_RETRY_CDP_PORT,undefined);
  assert.equal(s.currentPort(),fallbackPort);
});

test('pickPort 返回可用的高位端口', async () => {
  const port=await pickPort();
  assert.ok(Number.isInteger(port));
  assert.ok(port>=1024&&port<=65535);
});
