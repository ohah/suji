// documents/*.mdx -> website/src/content/docs/<group>/<slug>.mdx 1회성 임포터.
//
// ⚠️ 주의: 이 스크립트는 저장소 documents/ 의 상세 API 문서를 사이트 IA 로
// 옮긴 *초기 임포트* 도구다. 임포트 이후 사이트 페이지는 사용자 관점으로
// 직접 다듬어졌으므로(내부 Phase/커밋/테스트 메타 제거 등) website 가
// 공개 문서의 정식 출처다. 이 스크립트를 다시 실행하면 그 편집이 전부
// 덮어쓰여지므로 재실행하지 말 것(documents/ 는 내부 엔지니어링 참조용).
// build 의 prebuild 에서도 제거됨 — gen-llms 만 자동 실행된다.
//
// 변환:
//   1) 중복 H1 제거 (Starlight 가 frontmatter title 을 H1 으로 렌더)
//   2) 코드영역 밖 <>{} -> HTML 엔티티 (MDX 가 JSX/표현식으로 오해 방지)
//      - 인라인 코드 span / 코드펜스 / <http..> autolink / 줄머리 blockquote 보존
//   3) 내부 링크 ./X.mdx[#anchor] -> /suji/<slug>/[#anchor]
//      ../docs/<path>.md -> GitHub blob
import { readFileSync, writeFileSync, mkdirSync } from 'node:fs';
import { dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';

const HERE = dirname(fileURLToPath(import.meta.url)); // website/scripts
const REPO = join(HERE, '..', '..'); // repo root
const SRC = join(REPO, 'documents');
const DST = join(HERE, '..', 'src', 'content', 'docs'); // website/src/content/docs
const GH_BLOB = 'https://github.com/ohah/suji/blob/main/docs/';

const SLUG = {
  frontend: 'ipc/frontend',
  'ipc-wire': 'ipc/wire',
  events: 'ipc/events',
  'backend-zig': 'backends/zig',
  'backend-rust': 'backends/rust',
  'backend-go': 'backends/go',
  'backend-node': 'backends/node',
  'multi-window': 'windows/multi-window',
  'multi-webview': 'windows/multi-webview',
  'window-lifecycle': 'windows/lifecycle',
  dialog: 'native/dialog',
  'clipboard-shell': 'native/clipboard-shell',
  tray: 'native/tray',
  menu: 'native/menu',
  notification: 'native/notification',
  'global-shortcut': 'native/global-shortcut',
  fs: 'concepts/fs',
  sandbox: 'concepts/sandbox',
  security: 'concepts/security',
  cache: 'concepts/cache',
  'crash-reporter': 'distribution/crash-reporter',
  'auto-updater': 'distribution/auto-updater',
  plugins: 'plugins/overview',
  'plugin-state': 'plugins/state',
  'electron-migration': 'guides/electron-migration',
};

function stripFirstH1(body) {
  const lines = body.split('\n');
  for (let i = 0; i < lines.length; i++) {
    if (/^# (?!#)/.test(lines[i])) {
      lines.splice(i, 1);
      if (lines[i] === '') lines.splice(i, 1);
      break;
    }
    if (lines[i].trim() !== '' && !lines[i].startsWith('import ')) break;
  }
  return lines.join('\n');
}

const OPEN = 'AUTOLINKOPEN9173';
const CLOSE = 'AUTOLINKCLOSE9173';
function escInline(s) {
  return s
    .replace(/<(https?:\/\/[^>]+)>/g, OPEN + '$1' + CLOSE)
    .replace(/[<>{}]/g, (c) => ({ '<': '&lt;', '>': '&gt;', '{': '&#123;', '}': '&#125;' }[c]))
    .split(OPEN)
    .join('<')
    .split(CLOSE)
    .join('>');
}
function escapeInText(text) {
  const re = /`[^`]*`/g;
  let out = '';
  let last = 0;
  let m;
  while ((m = re.exec(text)) !== null) {
    out += escInline(text.slice(last, m.index));
    out += m[0];
    last = m.index + m[0].length;
  }
  out += escInline(text.slice(last));
  return out;
}
function escapeMdx(body) {
  const lines = body.split('\n');
  let inFence = false;
  let marker = '';
  return lines
    .map((line) => {
      const fm = line.match(/^\s*(`{3,}|~{3,})/);
      if (fm) {
        const ch = fm[1][0];
        if (!inFence) {
          inFence = true;
          marker = ch;
        } else if (ch === marker) {
          inFence = false;
          marker = '';
        }
        return line;
      }
      if (inFence) return line;
      const bq = line.match(/^(\s*(?:>\s?)+)(.*)$/);
      if (bq) return bq[1] + escapeInText(bq[2]);
      return escapeInText(line);
    })
    .join('\n');
}

function rewriteLinks(text) {
  text = text.replace(/\]\(\.\/([a-z0-9-]+)\.mdx(#[^)]*)?\)/g, (m, base, anchor) => {
    const slug = SLUG[base];
    return slug ? `](/suji/${slug}/${anchor ?? ''})` : m;
  });
  text = text.replace(/\]\(\.\.\/docs\/([A-Za-z0-9_/-]+\.md)(#[^)]*)?\)/g, (m, path) => {
    return `](${GH_BLOB}${path})`;
  });
  return text;
}

let count = 0;
for (const [base, slug] of Object.entries(SLUG)) {
  const srcPath = join(SRC, `${base}.mdx`);
  let content;
  try {
    content = readFileSync(srcPath, 'utf8');
  } catch {
    console.error(`SKIP (missing): ${srcPath}`);
    continue;
  }
  const fmMatch = content.match(/^(---\n[\s\S]*?\n---\n)([\s\S]*)$/);
  if (!fmMatch) {
    console.error(`SKIP (no frontmatter): ${base}`);
    continue;
  }
  let body = stripFirstH1(fmMatch[2]);
  body = escapeMdx(body);
  body = rewriteLinks(body);
  const dstPath = join(DST, `${slug}.mdx`);
  mkdirSync(dirname(dstPath), { recursive: true });
  writeFileSync(dstPath, fmMatch[1] + body, 'utf8');
  count++;
  console.log(`  ${base}.mdx -> ${slug}.mdx`);
}
console.log(`\n${count} pages ported from documents/`);
