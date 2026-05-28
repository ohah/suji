/**
 * @suji/plugin-notification-rich-node — Node backend wrapper.
 * Wire contract 은 renderer 변형과 동일. macOS/Linux action clicks are
 * emitted through `notification:click` with `{ notificationId, actionId }`.
 * Windows button click callback still requires NotificationActivator COM
 * registration.
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
  /** 이미지 파일 절대 경로. setImageRoots 로 등록된 root 안에 있어야 표시되고
   * 아니면 silently 무시. */
  image?: string;
  scenario?: "alarm" | "reminder" | "incomingCall" | "urgent";
  silent?: boolean;
}

export interface RichNotificationClick {
  notificationId: string;
  actionId?: string;
}

export const richNotification = {
  async show(opts: ShowOpts): Promise<{ id: number }> {
    const r = await call("notification:rich_show", {
      title: opts.title,
      body: opts.body,
      ...(opts.actions ? { actions: opts.actions } : {}),
      ...(opts.image ? { image: opts.image } : {}),
      ...(opts.scenario ? { scenario: opts.scenario } : {}),
      ...(opts.silent !== undefined ? { silent: opts.silent } : {}),
    });
    return { id: Number(r?.id ?? 0) };
  },

  async hide(id: number): Promise<void> {
    await call("notification:rich_hide", { id });
  },

  async setImageRoots(roots: string[]): Promise<void> {
    await call("notification:set_image_roots", { roots });
  },

  async getImageRoots(): Promise<string[]> {
    const r = await call("notification:get_image_roots", {});
    return (r?.roots ?? []) as string[];
  },
};
