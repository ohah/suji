// @ts-check
import { defineConfig } from 'astro/config';
import starlight from '@astrojs/starlight';

// GitHub Pages: https://ohah.github.io/suji (repo = github.com/ohah/suji).
// zts(documents/astro.config.mjs) 의 Starlight 셋업을 미러 — 단 Suji 는
// monaco/wasm/typedoc/playground 불요라 Starlight 문서만(린).
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
            { label: '빠른 시작', slug: 'guides/quick-start', translations: { en: 'Quick Start' } },
            { label: 'CLI', slug: 'guides/cli' },
          ],
        },
        {
          label: '개념',
          translations: { en: 'Concepts' },
          items: [
            { label: '멀티 백엔드 & 플러그인', slug: 'concepts/backends', translations: { en: 'Backends & Plugins' } },
            { label: '권한 & 샌드박스', slug: 'concepts/permissions', translations: { en: 'Permissions & Sandbox' } },
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
