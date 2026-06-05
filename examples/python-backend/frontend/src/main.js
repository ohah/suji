import "./style.css";

const output = document.querySelector("#output");

async function invoke(channel, payload) {
  try {
    const result = await window.__suji__.invoke(channel, payload);
    output.textContent = JSON.stringify(result, null, 2);
  } catch (err) {
    output.textContent = String(err && err.stack ? err.stack : err);
  }
}

document.querySelector("#ping").addEventListener("click", () => {
  invoke("ping", {});
});

document.querySelector("#echo").addEventListener("click", () => {
  invoke("echo", { message: "hello from frontend", at: Date.now() });
});
