#!/usr/bin/env bash
# @suji/cli config-loader 회귀 테스트 — config.ts 빌드 훅/플랫폼 빌드/dev.env normalize.
# CEF/Zig 무관, node 만 필요. (build hooks/platform-build/dev.env 후속 작업 가드)
#
# 검증:
#  1. 함수형 config 가 mode/command 로 평가
#  2. window 단축 → windows 배열, dev.devUrl → frontend.dev_url
#  3. 플랫폼별 build 오버라이드 fold(현재 OS) + build._hooks 플래그 + _configFile
#  4. dev.env 보존, 함수(훅) strip 후 유효 JSON
#  5. --hook 모드가 해당 훅을 mode/command 와 실행, 부재 훅은 no-op
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
LOADER="$ROOT/packages/suji-cli/bin/load-config.js"
command -v node >/dev/null || { echo "FAIL: node not found"; exit 1; }
[ -f "$LOADER" ] || { echo "FAIL: loader not found at $LOADER"; exit 1; }

PASS=0
ok() { PASS=$((PASS+1)); echo "  ok: $1"; }
fail() { echo "FAIL: $1"; exit 1; }

T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
cat > "$T/suji.config.js" <<'EOF'
export default ({ mode, command }) => ({
  app: { name: "CfgApp", version: "1.0.0" },
  window: { title: "TS", width: 1280, height: 800 },
  build: {
    sign: "adhoc",
    mac: { sign: "identity", notarize: mode === "production", entitlements: "my.entitlements" },
    win: { sign: "none" }, linux: { sign: "none" },
    async beforeBuild({ mode }) { console.error("HOOK:beforeBuild:" + mode); },
    async afterBuild() { console.error("HOOK:afterBuild"); },
  },
  dev: { devUrl: "http://localhost:4321", env: { MY_VAR: "yes" } },
});
EOF

# ---- 1-4: resolve (production/build) ----
OUT="$(node "$LOADER" --command build --mode production --cwd "$T" --config "$T/suji.config.js")"
echo "$OUT" | node -e '
const j = JSON.parse(require("fs").readFileSync(0, "utf8"));
const a = (c, m) => { if (!c) { console.error("ASSERT FAIL: " + m); process.exit(1); } };
a(Array.isArray(j.windows) && j.windows[0].width === 1280, "window shorthand -> windows array");
a(j.frontend.dev_url === "http://localhost:4321", "dev.devUrl -> frontend.dev_url");
a(j.build && j.build._hooks.beforeBuild === true && j.build._hooks.afterBuild === true && j.build._hooks.beforeDev === false, "build._hooks flags");
a(typeof j.build._configFile === "string", "_configFile recorded");
a(j.dev && j.dev.env && j.dev.env.MY_VAR === "yes", "dev.env preserved");
const plat = process.platform === "darwin" ? "mac" : process.platform === "win32" ? "win" : "linux";
if (plat === "mac") {
  a(j.build.sign === "identity", "mac build override folded (sign)");
  a(j.build.notarize === true, "mac notarize = (mode===production)");
  a(j.app.entitlements === "my.entitlements", "build.mac.entitlements -> app.entitlements");
} else {
  a(j.build.sign === "none", plat + " build override folded");
}
// functions must be stripped (valid JSON already parsed above)
a(typeof j.build.beforeBuild === "undefined", "hook functions stripped from emitted config");
console.error("resolve assertions passed (platform=" + plat + ")");
' || fail "resolve assertions"
ok "resolve: window/devUrl/platform-build/hooks/dev.env normalization"

# ---- 5: hook execution ----
HB="$(node "$LOADER" --command build --mode production --cwd "$T" --config "$T/suji.config.js" --hook beforeBuild 2>&1 || true)"
echo "$HB" | grep -q "HOOK:beforeBuild:production" || fail "beforeBuild hook did not run with mode=production (got: $HB)"
ok "beforeBuild hook runs with env (mode=production)"

HM="$(node "$LOADER" --cwd "$T" --config "$T/suji.config.js" --hook beforeDev 2>&1 || true)"
[ -z "$HM" ] || fail "missing hook should be silent no-op (got: $HM)"
ok "missing hook is a no-op"

echo "PASS: $PASS config-loader checks"
