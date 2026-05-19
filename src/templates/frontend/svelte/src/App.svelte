<script lang="ts">
  import { invoke } from "./suji";

  let name = $state("Suji");
  let log = $state("Ready. 백엔드 핸들러를 호출해 보세요.");

  async function call(label: string, run: () => Promise<unknown>) {
    try {
      log = `[${label}] ${JSON.stringify(await run())}`;
    } catch (e) {
      log = `[${label}] ERR: ${String(e)}`;
    }
  }
</script>

<main>
  <h1>Suji + Svelte</h1>
  <p class="hint"><code>import {"{ invoke }"} from "./suji"</code></p>

  <div class="row">
    <button onclick={() => call("ping", () => invoke("ping"))}>
      invoke("ping")
    </button>
    <input bind:value={name} aria-label="name" />
    <button onclick={() => call("greet", () => invoke("greet", { name }))}>
      invoke("greet", &lbrace; name &rbrace;)
    </button>
  </div>

  <pre class="log">{log}</pre>
</main>

<style>
  main {
    max-width: 560px;
    margin: 0 auto;
    padding: 32px;
    font-family: system-ui, sans-serif;
  }
  .hint {
    color: #888;
  }
  .row {
    display: flex;
    gap: 8px;
    flex-wrap: wrap;
    margin-top: 24px;
  }
  .log {
    margin-top: 24px;
    padding: 14px;
    background: #111;
    color: #0f0;
    border-radius: 6px;
    white-space: pre-wrap;
  }
</style>
