import test from 'node:test';
import assert from 'node:assert/strict';
import {monitorSession} from '../Resources/WorkBuddyRetry/background-session.mjs';
import {performMonitorAction} from '../Resources/WorkBuddyRetry/monitor-actions.mjs';
import {
  assertLegacyRetryStopped,
  findLegacyRetryOwner,
  isProcessAlive,
  legacyRetryLockPath,
  LegacyRetryLockReadError,
  LegacyRetryOwnerError,
} from '../Resources/WorkBuddyRetry/legacy-owner.mjs';

const fixtureLock = '/fixture/Library/Application Support/WorkBuddyRetry/background.lock';

test('legacy lock path is isolated and stale PID does not block', () => {
  assert.equal(legacyRetryLockPath('/fixture'), fixtureLock);
  let readPath;
  const owner = findLegacyRetryOwner({
    lockFile: fixtureLock,
    readFile: file => { readPath = file; return '4242\n'; },
    alive: pid => { assert.equal(pid, 4242); return false; },
  });
  assert.equal(owner, null);
  assert.equal(readPath, fixtureLock);
  assert.doesNotThrow(() => assertLegacyRetryStopped({lockFile: fixtureLock, readFile: () => '4242', alive: () => false}));
});

test('live legacy retry PID blocks new binding with actionable feedback', () => {
  assert.throws(
    () => assertLegacyRetryStopped({lockFile: fixtureLock, readFile: () => '5151\n', alive: pid => pid === 5151}),
    error => error instanceof LegacyRetryOwnerError && error.code === 'legacy_retry_active' &&
      error.message.includes('PID 5151') && error.message.includes('先在旧工具停止重试')
  );
});

test('EPERM from process kill check means the old owner is still alive', () => {
  const denied = Object.assign(new Error('permission denied'), {code: 'EPERM'});
  assert.equal(isProcessAlive(6262, () => { throw denied; }), true);
});

test('unreadable legacy lock fails closed without modifying it', () => {
  const denied = Object.assign(new Error('permission denied'), {code: 'EACCES'});
  assert.throws(
    () => findLegacyRetryOwner({lockFile: fixtureLock, readFile: () => { throw denied; }, alive: () => false}),
    error => error instanceof LegacyRetryLockReadError && error.code === 'legacy_retry_lock_unreadable'
  );
});

test('start/update guard runs before channel restart and chat binding', async () => {
  const calls = [];
  await assert.rejects(performMonitorAction('update', {
    stopWorker: async () => calls.push('stop-new-worker'),
    assertLegacyRetryStopped: () => { calls.push('check-old-lock'); throw new LegacyRetryOwnerError(7373); },
    ensureChannel: async () => calls.push('restart-or-connect'),
    startWorker: async () => calls.push('bind-new-chat'),
  }, {allowRestart: true}), error => error.code === 'legacy_retry_active');
  assert.deepEqual(calls, ['stop-new-worker', 'check-old-lock']);
});

test('legacy worker starting after monitor bind is blocked immediately before retry click', async () => {
  const busy = {bindingValid: true, sessionBound: true, errorBanners: 1, busyBanners: 1, retryButtons: 1, generating: false};
  let now = 0;
  let legacyLive = false;
  let clickCount = 0;
  let checkCount = 0;
  const reports = [];
  const events = [];
  const oldLockCheck = () => {
    checkCount++;
    assertLegacyRetryStopped({
      lockFile: fixtureLock,
      readFile: () => legacyLive ? '8484\n' : (() => { throw Object.assign(new Error('missing'), {code: 'ENOENT'}); })(),
      alive: pid => legacyLive && pid === 8484,
    });
  };

  await monitorSession({
    now: () => now,
    sleep: async ms => { now += ms; if (now >= 10_000) legacyLive = true; },
    stopRequested: () => now >= 18_000,
    probe: async click => {
      if (click) { clickCount++; return {clicked: true}; }
      return busy;
    },
    verification: async () => ({pending: false, outcome: 'request_state_observed'}),
    beforeClick: oldLockCheck,
    report: value => reports.push({...value, now}),
    event: name => events.push(name),
  });

  assert.equal(checkCount, 1);
  assert.equal(clickCount, 0);
  assert.ok(reports.some(report => report.retryPausedReason?.includes('PID 8484')));
  assert.ok(events.includes('legacy_owner_blocked'));
});
