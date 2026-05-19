import { invoke } from "./suji";

const logEl = document.getElementById("log")!;
const nameEl = document.getElementById("name") as HTMLInputElement;

async function call(label: string, run: () => Promise<unknown>) {
  try {
    logEl.textContent = `[${label}] ${JSON.stringify(await run())}`;
  } catch (e) {
    logEl.textContent = `[${label}] ERR: ${String(e)}`;
  }
}

document.getElementById("ping")!.addEventListener("click", () => {
  call("ping", () => invoke("ping"));
});
document.getElementById("greet")!.addEventListener("click", () => {
  call("greet", () => invoke("greet", { name: nameEl.value }));
});
