/**
 * @suji/node — Suji Desktop Framework Node.js Backend SDK
 *
 * libnode 임베딩 환경에서 사용. globalThis.suji를 타입 안전하게 래핑.
 *
 * ```ts
 * import { handle, invoke, invokeSync, send } from '@suji/node';
 *
 * handle('ping', () => ({ msg: 'pong' }));
 *
 * handle('greet', (data) => ({
 *   greeting: `Hello ${data.name}!`
 * }));
 *
 * // 크로스 호출 (핸들러 내부 — 동기)
 * handle('call-zig', () => {
 *   const result = invokeSync('zig', { cmd: 'ping' });
 *   return { from: 'node', result };
 * });
 *
 * // 이벤트 발신
 * send('my-event', { msg: 'hello from Node.js' });
 * ```
 */

// ============================================
// Types
// ============================================

export type HandlerFn<TReq = unknown, TRes = unknown> = (data: TReq) => TRes;

interface SujiBridge {
  handle(channel: string, fn: (data: string) => string): void;
  invoke(backend: string, request: string): Promise<string>;
  invokeSync(backend: string, request: string): string;
  send(channel: string, data: string): void;
  on(channel: string, fn: (channel: string, data: string) => void): number;
  off(subId: number): void;
  register(channel: string): void;
}

// ============================================
// Bridge access
// ============================================

function getBridge(): SujiBridge {
  const bridge = (globalThis as any).suji as SujiBridge | undefined;
  if (!bridge) {
    throw new Error(
      '@suji/node: bridge not available. This module must run inside a Suji app (libnode embedding).'
    );
  }
  return bridge;
}

// ============================================
// Handler registration
// ============================================

/**
 * 핸들러 등록 — 프론트엔드/다른 백엔드에서 이 채널로 호출 가능
 *
 * 콜백은 파싱된 객체를 받고, 반환값은 자동으로 JSON.stringify됨.
 * 문자열을 반환하면 그대로 전달.
 *
 * @example
 * handle('ping', () => ({ msg: 'pong' }));
 * handle('greet', (data) => ({ hello: data.name }));
 */
export function handle<TReq = unknown, TRes = unknown>(
  channel: string,
  handler: HandlerFn<TReq, TRes>,
): void {
  getBridge().handle(channel, (raw: string) => {
    let data: TReq;
    try {
      data = JSON.parse(raw);
    } catch {
      data = raw as unknown as TReq;
    }

    const result = handler(data);

    if (typeof result === 'string') return result;
    return JSON.stringify(result);
  });
}

// ============================================
// Cross-backend invocation
// ============================================

/**
 * 다른 백엔드 비동기 호출 (Promise 반환, event loop 비블록)
 *
 * 핸들러 밖에서 사용. 핸들러 안에서는 invokeSync 사용.
 *
 * @example
 * const result = await invoke('zig', { cmd: 'ping' });
 */
export async function invoke<T = unknown>(
  backend: string,
  request: Record<string, unknown> = {},
): Promise<T> {
  const raw = await getBridge().invoke(backend, JSON.stringify(request));
  try {
    return JSON.parse(raw) as T;
  } catch {
    return raw as unknown as T;
  }
}

/**
 * 다른 백엔드 동기 호출 (핸들러 내부용)
 *
 * event loop을 블록하므로 핸들러 안에서만 사용할 것.
 *
 * @example
 * handle('call-zig', () => {
 *   const result = invokeSync('zig', { cmd: 'ping' });
 *   return { from: 'node', result };
 * });
 */
export function invokeSync<T = unknown>(
  backend: string,
  request: Record<string, unknown> = {},
): T {
  const raw = getBridge().invokeSync(backend, JSON.stringify(request));
  try {
    return JSON.parse(raw) as T;
  } catch {
    return raw as unknown as T;
  }
}

// ============================================
// Events
// ============================================

/**
 * 이벤트 발신 — 프론트엔드로 전달
 *
 * @example
 * send('data-updated', { items: [1, 2, 3] });
 */
export function send(channel: string, data: unknown = {}): void {
  getBridge().send(channel, JSON.stringify(data));
}

// ============================================
// Channel registration
// ============================================

/**
 * 이벤트 수신 — 프론트엔드/다른 백엔드에서 발신한 이벤트를 수신
 *
 * @returns 구독 해제 함수
 *
 * @example
 * const cancel = on('data-updated', (data) => {
 *   console.log('received:', data);
 * });
 * // 나중에 해제
 * cancel();
 */
export function on<T = unknown>(
  channel: string,
  callback: (data: T) => void,
): () => void {
  const subId = getBridge().on(channel, (_ch: string, raw: string) => {
    let data: T;
    try {
      data = JSON.parse(raw) as T;
    } catch {
      data = raw as unknown as T;
    }
    callback(data);
  });

  return () => off(subId);
}

/**
 * 이벤트 구독 해제
 */
export function off(subId: number): void {
  getBridge().off(subId);
}

/**
 * 이벤트 한 번만 수신
 *
 * @returns 구독 해제 함수
 */
export function once<T = unknown>(
  channel: string,
  callback: (data: T) => void,
): () => void {
  let subId: number;
  subId = getBridge().on(channel, (_ch: string, raw: string) => {
    getBridge().off(subId);
    let data: T;
    try {
      data = JSON.parse(raw) as T;
    } catch {
      data = raw as unknown as T;
    }
    callback(data);
  });

  return () => getBridge().off(subId);
}

/**
 * 채널을 수동으로 등록 (자동 라우팅 테이블에 추가)
 *
 * handle()은 자동으로 register하지 않음 (bridge.cc에서 별도 관리).
 * 명시적으로 코어 라우팅 테이블에 등록해야 할 때 사용.
 */
export function register(channel: string): void {
  getBridge().register(channel);
}
