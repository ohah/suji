/**
 * @suji/plugin-notification-rich — Rich toast notifications for Suji renderer.
 *
 * Platform rich notification wrapper:
 * - Windows: WinRT ToastNotificationManager action buttons + Action Center persistence.
 * - macOS: UNUserNotificationCenter action buttons + image attachment best effort.
 * - Linux: Freedesktop Notifications action buttons via D-Bus.
 *
 * ```ts
 * import { richNotification } from '@suji/plugin-notification-rich';
 * const { id } = await richNotification.show({
 *   title: "메시지 도착",
 *   body: "ohah 님이 메시지를 보냈습니다.",
 *   actions: [{ id: "reply", label: "답장" }, { id: "mark_read", label: "읽음 표시" }],
 *   scenario: "reminder",
 * });
 * // ...
 * await richNotification.hide(id);
 * ```
 *
 * Action clicks are emitted through `notification:click` with
 * `{ notificationId, actionId }`. Windows still needs a NotificationActivator
 * COM registration before button clicks can call back into the app.
 */

interface SujiBridge {
  invoke(channel: string, data?: Record<string, unknown>): Promise<any>;
}

function getBridge(): SujiBridge {
  const bridge = (window as any).__suji__;
  if (!bridge) throw new Error("Suji bridge not available.");
  return bridge;
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
   * 아니면 silently 무시(toast 는 image 없이 표시). */
  image?: string;
  scenario?: "alarm" | "reminder" | "incomingCall" | "urgent";
  silent?: boolean;
}

export interface RichNotificationClick {
  notificationId: string;
  actionId?: string;
}

async function call(cmd: string, payload: Record<string, unknown>): Promise<any> {
  const resp = await getBridge().invoke(cmd, payload);
  if (resp?.error) throw new Error(`notification-rich: ${resp.error}`);
  return resp?.result ?? resp;
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

  /** image 경로 allowlist 설정 — fs sandbox 와 동형(deny-by-default, ".." 차단,
   * prefix + separator boundary, `["*"]` = escape hatch). */
  async setImageRoots(roots: string[]): Promise<void> {
    await call("notification:set_image_roots", { roots });
  },

  async getImageRoots(): Promise<string[]> {
    const r = await call("notification:get_image_roots", {});
    return (r?.roots ?? []) as string[];
  },
};
