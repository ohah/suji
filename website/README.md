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

`src/content/docs/` 아래 페이지는 두 출처로 나뉜다.

| 분류 | 출처 | 편집 위치 |
|---|---|---|
| **손작성 가이드** — `index`, `guides/{introduction,installation,quick-start,cli}`, `concepts/{backends,permissions}`, `reference/roadmap` | 사이트 전용 큐레이션 | 이 디렉터리에서 직접 편집 |
| **포팅된 API 레퍼런스** — `ipc/*`, `backends/*`, `windows/*`, `native/*`, `distribution/*`, `plugins/*`, `concepts/{fs,sandbox,security,cache}`, `guides/electron-migration` | 저장소 `documents/*.mdx` (단일 출처) | `documents/` 에서 편집 후 재생성 |

### 포팅 페이지 재생성

포팅된 레퍼런스 페이지는 `documents/*.mdx` 가 단일 출처다. 본문을 바꾸려면
`documents/` 에서 고친 뒤 재생성한다(이 디렉터리의 생성 페이지를 직접 편집하면
다음 재생성 때 덮어쓰여진다).

```bash
bun run port-docs   # scripts/port-docs.mjs — documents/*.mdx 를 사이트 IA 로 포팅
```

변환 내용: 중복 H1 제거, 코드영역 밖 `<>{}` HTML 엔티티화(MDX JSX/표현식 오해
방지), 내부 링크(`./x.mdx`, `../docs/*.md`) 재작성. 사이드바 구조는
`astro.config.mjs` 의 `sidebar` 에서 관리한다.

`bun run build` 의 **prebuild** 가 `port-docs` + `gen-llms` 를 자동 실행하므로
배포 산출물은 항상 `documents/` 와 동기화된다.

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
