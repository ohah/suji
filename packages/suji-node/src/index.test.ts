import { describe, it, expect, beforeEach, mock } from 'bun:test';

// Bridge 구조 — index.ts의 SujiBridge와 일치하는 mock.
type HandlerEntry = (data: string, event: any) => string;

let registered: Record<string, HandlerEntry> = {};
const bridge = {
  handle: mock((ch: string, fn: HandlerEntry) => { registered[ch] = fn; }),
  invoke: mock(() => Promise.resolve('{}')),
  invokeSync: mock(() => '{}'),
  send: mock(() => {}),
  sendTo: mock(() => {}),
  on: mock(() => 1),
  off: mock(() => {}),
  register: mock(() => {}),
  quit: mock(() => {}),
  platform: mock(() => 'macos'),
};

(globalThis as any).suji = bridge;

// bridge가 globalThis에 세팅된 뒤에 import
import { handle, send, sendTo, type InvokeEvent } from './index';

beforeEach(() => {
  registered = {};
  for (const key of Object.keys(bridge) as (keyof typeof bridge)[]) {
    (bridge[key] as any).mockClear?.();
  }
});

describe('handle — 1-arity (기존 호환)', () => {
  it('파싱된 data를 단일 인자로 받는다', () => {
    const h = mock((_d: any) => ({ ok: true }));
    handle('ping', h);
    const result = registered['ping']('{"cmd":"ping"}', { window: { id: 0, name: null, url: null } });
    expect(h).toHaveBeenCalledTimes(1);
    expect(h.mock.calls[0][0]).toEqual({ cmd: 'ping' });
    expect(result).toBe('{"ok":true}');
  });

  it('문자열 반환은 그대로 전달 (JSON.stringify 건너뜀)', () => {
    handle('ping', () => 'raw-string');
    expect(registered['ping']('{}', { window: { id: 0, name: null, url: null } })).toBe('raw-string');
  });
});

describe('handle — 2-arity (InvokeEvent)', () => {
  it('event를 두 번째 인자로 받는다', () => {
    let captured: InvokeEvent | null = null;
    handle('save', (_data, event) => {
      captured = event;
      return { ok: true };
    });

    const ev = { window: { id: 7, name: 'settings', url: 'http://localhost:5173/settings' } };
    registered['save']('{"cmd":"save","__window":7,"__window_name":"settings","__window_url":"http://localhost:5173/settings"}', ev);

    expect(captured).toEqual(ev);
  });

  it('1-arity handler는 event를 받지 않는다 (handler.length === 1 분기)', () => {
    const h = mock((_d: any) => 'ok');
    handle('ping', h);
    registered['ping']('{}', { window: { id: 9, name: 'x', url: null } });
    // 1-arity — 두 번째 인자 생략
    expect(h.mock.calls[0].length).toBe(1);
  });
});

describe('send / sendTo', () => {
  it('send는 bridge.send(channel, JSON)로 전달', () => {
    send('event', { a: 1 });
    expect(bridge.send).toHaveBeenCalledWith('event', '{"a":1}');
  });

  it('sendTo는 windowId + JSON으로 bridge.sendTo 호출', () => {
    sendTo(3, 'toast', { text: 'saved' });
    expect(bridge.sendTo).toHaveBeenCalledWith(3, 'toast', '{"text":"saved"}');
  });

  it('sendTo는 data 생략 시 빈 객체 JSON', () => {
    sendTo(5, 'ping');
    expect(bridge.sendTo).toHaveBeenCalledWith(5, 'ping', '{}');
  });

  it('sendTo는 bridge에 필드가 없으면 silent no-op (구버전 core 호환)', () => {
    const savedSendTo = bridge.sendTo;
    (bridge as any).sendTo = undefined;
    expect(() => sendTo(1, 'x', {})).not.toThrow();
    bridge.sendTo = savedSendTo;
  });
});
