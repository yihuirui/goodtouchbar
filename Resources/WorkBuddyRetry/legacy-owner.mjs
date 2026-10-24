import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';

export function legacyRetryLockPath(homeDirectory = os.homedir()) {
  return path.join(homeDirectory, 'Library/Application Support/WorkBuddyRetry/background.lock');
}

export function isProcessAlive(pid, kill = process.kill.bind(process)) {
  if (!Number.isInteger(pid) || pid <= 0) return false;
  try {
    kill(pid, 0);
    return true;
  } catch (error) {
    return error.code === 'EPERM';
  }
}

export class LegacyRetryOwnerError extends Error {
  constructor(pid) {
    super(`检测到旧版 BestTouchTool 自动重试仍在运行（PID ${pid}）。请先在旧工具停止重试，再启动 goodtouchbar。`);
    this.name = 'LegacyRetryOwnerError';
    this.code = 'legacy_retry_active';
    this.pid = pid;
  }
}

export class LegacyRetryLockReadError extends Error {
  constructor() {
    super('无法检查旧版自动重试锁，已阻止绑定和自动点击；请确认旧版重试已停止后再试。');
    this.name = 'LegacyRetryLockReadError';
    this.code = 'legacy_retry_lock_unreadable';
  }
}

export function findLegacyRetryOwner({
  lockFile = legacyRetryLockPath(),
  readFile = fs.readFileSync,
  alive = isProcessAlive,
} = {}) {
  let content;
  try {
    content = readFile(lockFile, 'utf8');
  } catch (error) {
    if (error.code === 'ENOENT') return null;
    throw new LegacyRetryLockReadError();
  }
  const pid = Number(String(content).trim());
  if (!Number.isInteger(pid) || pid <= 0) return null;
  return alive(pid) ? pid : null;
}

export function assertLegacyRetryStopped(options = {}) {
  const pid = findLegacyRetryOwner(options);
  if (pid !== null) throw new LegacyRetryOwnerError(pid);
}
