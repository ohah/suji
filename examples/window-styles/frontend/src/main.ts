// 메인 창 스크립트 — Phase 3 + sendTo 데모.

const out = document.getElementById("out") as HTMLPreElement;
const log = (msg: string) => { out.textContent = msg + "\n" + out.textContent; };

declare global {
  interface Window {
    __suji__: {
      invoke: (ch: string, data?: object, opts?: { target?: string }) => Promise<any>;
      emit: (ev: string, data: object | string, target?: number) => void;
    };
  }
}

document.getElementById("whoami")!.addEventListener("click", async () => {
  const resp = await window.__suji__.invoke("whoami");
  log("whoami: " + JSON.stringify(resp.result, null, 2));
});

document.getElementById("toast")!.addEventListener("click", async () => {
  const text = "메인 → " + new Date().toLocaleTimeString();
  await window.__suji__.invoke("hud-toast", { text });
  log("→ broadcast hud:toast: " + text);
});
