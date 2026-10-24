// 调试端口的唯一来源。
//
// 原来端口写死 19243，散落在 cdp-client / open-international 两处共 6 个位置。
// 写死的端口有两个问题：任何本机进程不必探测就知道该连哪里；装了两个 Electron
// 工具时还会互相抢端口。现在改成"每次拉起 WorkBuddy 时挑一个空闲端口"，并把
// 选择结果记在状态目录里，让后续的更新／停止复用同一个端口，不必重启 WorkBuddy。
//
// 注意：CDP 协议本身没有认证，换端口只是降低被发现和被误连的概率，不等于消除暴露。
import fs from 'node:fs';
import net from 'node:net';
import os from 'node:os';
import path from 'node:path';

export const fallbackPort = 19243;

const defaultFile = path.join(os.homedir(), 'Library/Application Support/GoodTouchBar/WorkBuddyRetry', 'cdp-port');

function valid(value) {
  return Number.isInteger(value) && value >= 1024 && value <= 65535;
}

/// 可注入存储路径，便于测试时不碰真实用户状态。
export function createPortStore(file, env = process.env) {
  const readPort = () => {
    const fromEnv = Number(env.WB_RETRY_CDP_PORT);
    if (valid(fromEnv)) return fromEnv;
    try {
      const value = Number(fs.readFileSync(file, 'utf8').trim());
      if (valid(value)) return value;
    } catch { /* 首次运行没有状态文件 */ }
    return null;
  };
  return {
    readPort,
    currentPort: () => readPort() ?? fallbackPort,
    savePort(port) {
      if (!valid(port)) throw Error('端口无效');
      fs.mkdirSync(path.dirname(file), { recursive: true, mode: 0o700 });
      fs.writeFileSync(file, String(port), { mode: 0o600 });
      env.WB_RETRY_CDP_PORT = String(port);
    },
    clearPort() {
      try { fs.unlinkSync(file); } catch { /* 已经不存在 */ }
      delete env.WB_RETRY_CDP_PORT;
    },
  };
}

const store = createPortStore(defaultFile);

/// 当前应使用的端口：环境变量优先（子进程继承），其次状态文件，最后回退默认值。
export const readPort = () => store.readPort();
export const currentPort = () => store.currentPort();
export const savePort = port => store.savePort(port);
export const clearPort = () => store.clearPort();

/// 让内核分配一个空闲端口，再立刻释放。调用方随后会重新检查端口是否被占用。
export function pickPort() {
  return new Promise((resolve, reject) => {
    const server = net.createServer();
    server.once('error', reject);
    server.listen(0, '127.0.0.1', () => {
      const { port } = server.address();
      server.close(() => resolve(port));
    });
  });
}
