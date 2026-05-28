<script setup lang="ts">
import { ref } from "vue";
import { invoke } from "./suji";

const name = ref("Suji");
const log = ref("Ready. 백엔드 핸들러를 호출해 보세요.");

async function call(label: string, run: () => Promise<unknown>) {
  try {
    log.value = `[${label}] ${JSON.stringify(await run())}`;
  } catch (e) {
    log.value = `[${label}] ERR: ${String(e)}`;
  }
}
</script>

<template>
  <main class="wrap">
    <h1>Suji + Vue</h1>
    <p class="hint"><code>import { invoke } from "./suji"</code></p>

    <div class="row">
      <button @click="call('ping', () => invoke('ping'))">
        invoke("ping")
      </button>
      <input v-model="name" aria-label="name" />
      <button @click="call('greet', () => invoke('greet', { name }))">
        invoke("greet", { name })
      </button>
    </div>

    <pre class="log">{{ log }}</pre>
  </main>
</template>

<style>
.wrap {
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
