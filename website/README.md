# Suji 문서 사이트

[Astro](https://astro.build) + [Starlight](https://starlight.astro.build) 기반
GitHub Pages 문서 사이트. 배포 URL: <https://ohah.github.io/suji>
(`.github/workflows/docs.yml` 이 `website/**` 변경 시 빌드 → Pages 배포).

## 개발 / 빌드

```bash
cd website
bun install
bun run dev       # 로컬 개발 서버
bun run build     # 정적 빌드 (dist/)
bun run preview   # 빌드 결과 미리보기
```

## 콘텐츠 구성

`src/content/docs/` 아래 모든 페이지가 **공개 문서의 정식 출처**다. 사용자 관점에
맞게 직접 다듬으면 된다(사이드바 구조는 `astro.config.mjs` 의 `sidebar`).

저장소 `documents/*.mdx` 는 **내부 엔지니어링 참조**다. 사이트 페이지는 그
문서들을 `scripts/port-docs.mjs` 로 1회 임포트한 뒤, Phase 라벨·커밋/PR 참조·
내부 소스 경로·테스트 메타 등 사용자에게 불필요한 내용을 걷어내 다듬은 것이라
이미 갈라져 있다.

> ⚠️ `scripts/port-docs.mjs` 는 초기 임포트 도구이며 **재실행하면 위 편집을
> 전부 덮어쓴다**. 사이트 본문 수정은 `website/src/content/docs/` 에서 직접 한다.
> (스타일은 `src/styles/custom.css`, 레이아웃 override 는 `src/overrides/`.)

## llms.txt

`scripts/gen-llms.mjs` 가 사이드바 순서대로 `public/llms.txt`(인덱스) +
`public/llms-full.txt`(전체 본문)를 생성한다([llmstxt.org](https://llmstxt.org)
규약). 배포 후 다음 경로로 제공:

- <https://ohah.github.io/suji/llms.txt>
- <https://ohah.github.io/suji/llms-full.txt>

```bash
bun run gen-llms   # 수동 재생성 (prebuild 가 자동 실행)
```

두 파일은 prebuild 생성물이라 git 추적에서 제외한다.
