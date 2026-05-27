/**
 * @suji/plugin-notification-rich-node — Node backend wrapper.
 * Wire contract 은 renderer 변형과 동일.
 */

interface SujiBridge {
  invoke(backend: string, request: string): Promise<string>;
}

function getBridge(): SujiBridge {
  const bridge = (globalThis as any).suji as SujiBridge | undefined;
  if (!bridge) {
    throw new Error(
      "@suji/plugin-notification-rich-node: bridge not available. This module must run inside a Suji app (libnode embedding).",
    );
  }
  return bridge;
}

async function call(cmd: string, payload: Record<string, unknown>): Promise<any> {
  const raw = await getBridge().invoke("notification-rich", JSON.stringify({ cmd, ...payload }));
  let resp: any;
  try {
    resp = JSON.parse(raw);
  } catch {
    resp = {};
  }
  if (resp?.error) throw new Error(`notification-rich: ${resp.error}`);
  return resp?.result;
}

export interface ToastAction {
  id: string;
  label: string;
}

export interface ShowOpts {
  title: string;
  body: string;
  actions?: ToastAction[];
  scenario?: "alarm" | "reminder" | "incomingCall" | "urgent";
  silent?: boolean;
}

export const richNotification = {
  async show(opts: ShowOpts): Promise<{ id: number }> {
    const r = await call("notification:rich_show", {
      title: opts.title,
      body: opts.body,
      ...(opts.actions ? { actions: opts.actions } : {}),
      ...(opts.scenario ? { scenario: opts.scenario } : {}),
      ...(opts.silent !== undefined ? { silent: opts.silent } : {}),
    });
    return { id: Number(r?.id ?? 0) };
  },

  async hide(id: number): Promise<void> {
    await call("notification:rich_hide", { id });
  },
};
