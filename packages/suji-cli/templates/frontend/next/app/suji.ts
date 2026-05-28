type SujiBridge = {
  invoke(channel: string, payload?: unknown): Promise<unknown>;
  send(event: string, payload?: unknown): void;
  on(event: string, cb: (payload: unknown) => void): () => void;
};

declare global {
  interface Window {
    __suji__?: SujiBridge;
  }
}

export async function invoke(channel: string, payload?: unknown) {
  if (!window.__suji__) throw new Error("Suji bridge is not available");
  return window.__suji__.invoke(channel, payload);
}

export function send(event: string, payload?: unknown) {
  window.__suji__?.send(event, payload);
}

export function on(event: string, cb: (payload: unknown) => void) {
  return window.__suji__?.on(event, cb) ?? (() => {});
}
