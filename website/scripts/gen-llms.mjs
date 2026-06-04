// src/content/docs/**/*.mdx -> public/llms.txt (인덱스) + public/llms-full.txt (전체 본문).
//
// llms.txt 규약(llmstxt.org): LLM 이 읽기 좋은 사이트 요약 + 링크.
// llms-full.txt: 모든 페이지 본문을 한 파일로 연결(전체 컨텍스트 주입용).
// 사이드바(astro.config.mjs) 와 같은 순서로 묶는다.
import { readFileSync, writeFileSync, mkdirSync } from 'node:fs';
import { dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';

const HERE = dirname(fileURLToPath(import.meta.url)); // website/scripts
const DOCS = join(HERE, '..', 'src', 'content', 'docs');
const PUBLIC = join(HERE, '..', 'public');
const BASE = 'https://ohah.github.io/suji';

// 섹션 = [라벨, [slug...]] — 사이드바 순서 미러
const SECTIONS = [
  ['가이드', ['guides/introduction', 'guides/installation', 'guides/quick-start', 'guides/cli', 'guides/electron-migration']],
  ['백엔드 SDK', ['backends/zig', 'backends/rust', 'backends/go', 'backends/node']],
  ['프론트엔드 & IPC', ['ipc/frontend', 'ipc/wire', 'ipc/events']],
  ['창 & WebContents', ['windows/multi-window', 'windows/multi-webview', 'windows/lifecycle']],
  ['네이티브 API', ['native/dialog', 'native/clipboard-shell', 'native/tray', 'native/menu', 'native/notification', 'native/global-shortcut']],
  ['배포 & 시스템', ['distribution/auto-updater', 'distribution/crash-reporter']],
  ['플러그인', ['plugins/overview', 'plugins/state']],
  ['개념', ['concepts/backends', 'concepts/permissions', 'concepts/fs', 'concepts/sandbox', 'concepts/security', 'concepts/cache']],
  ['레퍼런스', ['reference/roadmap']],
];

function parse(slug) {
  const raw = readFileSync(join(DOCS, `${slug}.mdx`), 'utf8');
  const m = raw.match(/^---\n([\s\S]*?)\n---\n([\s\S]*)$/);
  const fm = m ? m[1] : '';
  const body = m ? m[2] : raw;
  const field = (k) => {
    const line = fm.split('\n').find((l) => l.startsWith(`${k}:`));
    if (!line) return '';
    let v = line.slice(k.length + 1).trim();
    if ((v.startsWith('"') && v.endsWith('"')) || (v.startsWith("'") && v.endsWith("'"))) v = v.slice(1, -1);
    return v;
  };
  return { title: field('title') || slug, description: field('description'), body: body.trim() };
}

const index = parse('index');
const intro = index.description || 'Zig 코어 기반 올인원 데스크톱·모바일 앱 프레임워크 (Electron 스타일 API).';

// --- llms.txt (인덱스) ---
let llms = `# Suji\n\n> ${intro}\n\n`;
llms += `Zig 코어 하나로 데스크톱(CEF)과 모바일(iOS/Android)을 만드는 올인원 앱 프레임워크.\n`;
llms += `Electron 스타일 \`handle\`/\`invoke\`/\`on\`/\`send\` API + Zig·Rust·Go·Node 멀티 백엔드.\n`;
llms += `전체 문서: ${BASE}\n\n`;
for (const [label, slugs] of SECTIONS) {
  llms += `## ${label}\n`;
  for (const slug of slugs) {
    const { title, description } = parse(slug);
    llms += `- [${title}](${BASE}/${slug}/)${description ? `: ${description}` : ''}\n`;
  }
  llms += '\n';
}
llms += `## Optional\n`;
llms += `- [GitHub 저장소](https://github.com/ohah/suji)\n`;
llms += `- [전체 본문 (llms-full.txt)](${BASE}/llms-full.txt)\n`;

// --- llms-full.txt (전체 본문 연결) ---
let full = `# Suji — 전체 문서\n\n> ${intro}\n\n`;
full += `Suji 문서 사이트의 모든 페이지 본문을 LLM 컨텍스트용으로 연결한 파일입니다.\n`;
full += `출처: ${BASE}\n`;
for (const [label, slugs] of SECTIONS) {
  full += `\n${'='.repeat(8)} ${label} ${'='.repeat(8)}\n`;
  for (const slug of slugs) {
    const { title, body } = parse(slug);
    full += `\n\n# ${title}\n출처: ${BASE}/${slug}/\n\n${body}\n`;
  }
}

mkdirSync(PUBLIC, { recursive: true });
writeFileSync(join(PUBLIC, 'llms.txt'), llms, 'utf8');
writeFileSync(join(PUBLIC, 'llms-full.txt'), full, 'utf8');
const count = SECTIONS.reduce((n, [, s]) => n + s.length, 0);
console.log(`llms.txt + llms-full.txt 생성 (${count} pages)`);
