// @ts-check
import { defineConfig } from 'astro/config';
import starlight from '@astrojs/starlight';

// GitHub Pages: https://ohah.github.io/suji (repo = github.com/ohah/suji).
// zts(documents/astro.config.mjs) 의 Starlight 셋업을 미러 — 단 Suji 는
// monaco/wasm/typedoc/playground 불요라 Starlight 문서만(린).
// 본문 페이지는 저장소 documents/*.mdx 를 사이트 IA 로 포팅한 것.
export default defineConfig({
  site: 'https://ohah.github.io',
  base: '/suji',
  integrations: [
    starlight({
      title: 'Suji',
      description: 'Zig 코어 기반 올인원 데스크톱·모바일 앱 프레임워크 (Electron 스타일 API)',
      defaultLocale: 'root',
      locales: {
        root: { label: '한국어', lang: 'ko' },
        en: { label: 'English', lang: 'en' },
      },
      social: [
        { icon: 'github', label: 'GitHub', href: 'https://github.com/ohah/suji' },
      ],
      expressiveCode: {
        themes: ['github-dark', 'github-light'],
      },
      sidebar: [
        {
          label: '가이드',
          translations: { en: 'Guides' },
          items: [
            { label: '소개', slug: 'guides/introduction', translations: { en: 'Introduction' } },
            { label: '설치 & 사용', slug: 'guides/installation', translations: { en: 'Installation & Usage' } },
            { label: '빠른 시작', slug: 'guides/quick-start', translations: { en: 'Quick Start' } },
            { label: 'CLI', slug: 'guides/cli' },
            { label: 'Electron 마이그레이션', slug: 'guides/electron-migration', translations: { en: 'Electron Migration' } },
          ],
        },
        {
          label: '백엔드 SDK',
          translations: { en: 'Backend SDKs' },
          items: [
            { label: 'Zig 백엔드', slug: 'backends/zig', translations: { en: 'Zig Backend' } },
            { label: 'Rust 백엔드', slug: 'backends/rust', translations: { en: 'Rust Backend' } },
            { label: 'Go 백엔드', slug: 'backends/go', translations: { en: 'Go Backend' } },
            { label: 'Node.js 백엔드', slug: 'backends/node', translations: { en: 'Node.js Backend' } },
          ],
        },
        {
          label: '프론트엔드 & IPC',
          translations: { en: 'Frontend & IPC' },
          items: [
            { label: '프론트엔드 API', slug: 'ipc/frontend', translations: { en: 'Frontend API' } },
            { label: 'IPC 와이어 포맷', slug: 'ipc/wire', translations: { en: 'IPC Wire Format' } },
            { label: '이벤트 & Electron 대응', slug: 'ipc/events', translations: { en: 'Events & Electron Map' } },
          ],
        },
        {
          label: '창 & WebContents',
          translations: { en: 'Windows & WebContents' },
          items: [
            { label: '멀티 윈도우', slug: 'windows/multi-window', translations: { en: 'Multi-window' } },
            { label: '멀티 WebView', slug: 'windows/multi-webview', translations: { en: 'Multi WebView' } },
            { label: '윈도우 라이프사이클', slug: 'windows/lifecycle', translations: { en: 'Window Lifecycle' } },
          ],
        },
        {
          label: '네이티브 API',
          translations: { en: 'Native APIs' },
          items: [
            { label: 'Dialog', slug: 'native/dialog' },
            { label: 'Clipboard & Shell', slug: 'native/clipboard-shell' },
            { label: 'Tray', slug: 'native/tray' },
            { label: 'Menu', slug: 'native/menu' },
            { label: 'Notification', slug: 'native/notification' },
            { label: 'Global Shortcut', slug: 'native/global-shortcut' },
          ],
        },
        {
          label: '배포 & 시스템',
          translations: { en: 'Distribution & System' },
          items: [
            { label: 'autoUpdater', slug: 'distribution/auto-updater' },
            { label: 'crashReporter', slug: 'distribution/crash-reporter' },
          ],
        },
        {
          label: '플러그인',
          translations: { en: 'Plugins' },
          items: [
            { label: '플러그인 개요', slug: 'plugins/overview', translations: { en: 'Plugins Overview' } },
            { label: 'state 플러그인', slug: 'plugins/state', translations: { en: 'state Plugin' } },
          ],
        },
        {
          label: '개념',
          translations: { en: 'Concepts' },
          items: [
            { label: '멀티 백엔드 & 플러그인', slug: 'concepts/backends', translations: { en: 'Backends & Plugins' } },
            { label: '권한 & 샌드박스', slug: 'concepts/permissions', translations: { en: 'Permissions & Sandbox' } },
            { label: '파일 시스템 & fs 샌드박스', slug: 'concepts/fs', translations: { en: 'File System & fs Sandbox' } },
            { label: 'macOS App Sandbox', slug: 'concepts/sandbox' },
            { label: '보안 모델', slug: 'concepts/security', translations: { en: 'Security Model' } },
            { label: '앱 데이터 / 캐시', slug: 'concepts/cache', translations: { en: 'App Data / Cache' } },
          ],
        },
        {
          label: '레퍼런스',
          translations: { en: 'Reference' },
          items: [
            { label: '로드맵 & 패리티', slug: 'reference/roadmap', translations: { en: 'Roadmap & Parity' } },
          ],
        },
      ],
    }),
  ],
});
