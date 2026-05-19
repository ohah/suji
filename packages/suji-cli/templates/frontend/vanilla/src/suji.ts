// Suji 프론트엔드 브리지 — CEF 호스트가 런타임에 주입하는 window.__suji__
// 를 타입 있는 함수로 감싼다. @suji/api 와 표면이 동일하므로, 패키지가
// npm 에 발행되면 `npm i @suji/api` 후 아래 import 를 `from "@suji/api"`
// 로 바꾸기만 하면 된다(코드 변경 0). 그 전까지는 이 로컬 래퍼로 동작.

interface SujiBridge {
  invoke(channel: string, data?: unknown, options?: unknown): Promise<unknown>;
  on(event: string, cb: (data: unknown) => void): () => void;
  emit(event: string, data: string, target?: number): unknown;
}

function bridge(): SujiBridge {
  const b = (window as unknown as { __suji__?: SujiBridge }).__suji__;
  if (!b) {
    throw new Error(
      "Suji bridge unavailable — open this app via `suji dev`, not a plain browser.",
    );
  }
  return b;
}

/** 백엔드 핸들러 호출 (Electron ipcRenderer.invoke 대응). */
export function invoke<T = unknown>(
  cmd: string,
  data?: Record<string, unknown>,
): Promise<T> {
  return bridge().invoke(cmd, data) as Promise<T>;
}

/** 이벤트 구독. 반환값은 해제 함수. */
export function on(event: string, cb: (data: unknown) => void): () => void {
  return bridge().on(event, cb);
}

/** 이벤트 발신. */
export function send(event: string, data: unknown): void {
  bridge().emit(event, JSON.stringify(data ?? {}));
}
