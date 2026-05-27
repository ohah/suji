/**
 * @suji/plugin-notification-rich — Rich toast notifications for Suji renderer.
 *
 * Windows 에서 WinRT ToastNotificationManager 로 정식 toast (action button,
 * Action Center 영속). 코어 `suji.notification.show` 는 Shell_NotifyIcon balloon
 * 기반이라 이런 기능이 제한적.
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
 * ⚠️ Action 버튼 click 콜백은 NotificationActivator COM 등록 필요 — v1 정직 경계.
 * 표시/영속/AUMID set 까지 동작 보증.
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
  scenario?: "alarm" | "reminder" | "incomingCall" | "urgent";
  silent?: boolean;
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
      ...(opts.scenario ? { scenario: opts.scenario } : {}),
      ...(opts.silent !== undefined ? { silent: opts.silent } : {}),
    });
    return { id: Number(r?.id ?? 0) };
  },

  async hide(id: number): Promise<void> {
    await call("notification:rich_hide", { id });
  },
};
