# __NAME__

[Suji](https://github.com/ohah/suji) 로 만든 올인원 데스크톱·모바일 앱.
Electron 스타일 API(`handle`/`invoke`/`on`/`send`) + __BACKEND__ 백엔드.

## 명령어

```bash
cd frontend && __INSTALL__   # 프론트엔드 의존성 설치
__DEV__                      # = suji dev (백엔드 빌드 + CEF 창 + 핫 리로드)
__BUILD__                    # = suji build (프로덕션 빌드)
suji types --out frontend/src/suji.generated.d.ts  # 백엔드 .schema() → .d.ts (zig)
```

## 구조

- `suji.json` — 앱/창/백엔드/프론트엔드 설정 (정적 단일 출처, node 불요)
- 백엔드 — `handle("ch", fn)` 로 채널 등록, `invoke`/`send`/`on` 로 통신
- `frontend/` — 렌더러(웹). **Node.js 없음** — 파일/쉘/권한 작업은 백엔드 핸들러로.

## 프론트엔드 → 백엔드 호출

```ts
import { invoke } from '@suji/api';

const { msg } = await invoke('ping');         // 백엔드 handle("ping") 로 자동 라우팅
await invoke('greet', { name: 'Suji' });      // 인자 전달
await invoke('ping', {}, { target: 'rust' }); // 특정 백엔드 지정(멀티 백엔드)
```

백엔드는 같은 채널명을 `handle` 로 등록한다. 채널명만으로 코어가 올바른 백엔드로
라우팅한다.

## 규칙

- `process.platform` 대신 `suji.platform` (`"macos"` | `"linux"` | `"windows"`).
- 렌더러 `fs.*` 등 네이티브 접근은 `suji.json` 의 `fs.allowedRoots` 샌드박스를 따른다
  (미설정 시 deny). 백엔드 SDK 호출은 신뢰 코드라 우회.
- 신뢰할 수 없는 외부 콘텐츠를 로드하는 창은 필요한 기능만 백엔드 핸들러로 좁혀 노출.

## 문서

- 공식 문서: <https://ohah.github.io/suji>
- LLM 컨텍스트(llms.txt): <https://ohah.github.io/suji/llms.txt>
- LLM 전체 본문(llms-full.txt): <https://ohah.github.io/suji/llms-full.txt>
