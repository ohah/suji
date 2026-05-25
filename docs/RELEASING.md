# 릴리스 / 코드 서명 / 배포

zero-native 패리티의 인-트리 Zig 서명·패키징 + GitHub Releases 자동화.

## 버전 단일 출처

`build.zig.zon` 의 `.version` 가 유일 출처. `scripts/version.sh` 가 추출,
`scripts/version.sh --check vX.Y.Z` 로 태그 일치 검증(release.yml 이 태그
푸시 시 자동 실행 — 불일치면 실패).

릴리스 절차:
1. `build.zig.zon` `.version` 갱신.
2. `CHANGELOG.md` 의 `<!-- release:start -->`~`<!-- release:end -->` 블록 작성
   (GitHub Release 본문으로 추출됨).
3. `git tag vX.Y.Z && git push --tags` → release.yml 정식 릴리스.

검증만(퍼블리시 X): Actions → release → Run workflow → `dry_run=true`
(기본). 3-OS CLI 빌드/패키징 + 임베드 라이브러리 크로스빌드 + 아티팩트
업로드까지 수행, GitHub Release 생성은 생략.

워크플로 계약은 `zig build test`의 `tests/release_workflow_test.zig`와
`bash tests/e2e/run-release-workflow.sh`가 고정한다. 태그 패턴, dry-run 기본값,
publish gate, 3-OS CLI asset, embed lib artifact, checksum 생성 경로가 빠지면
테스트가 실패한다.

## 데스크톱 서명 (`suji build`)

사용자 앱 빌드 시 서명/공증/패키징 — zero-native `--signing` 패리티.
플래그 > env(CI secret) 우선:

```
suji build --sign=identity --identity="Developer ID Application: Acme (TEAMID)" \
           --notarize --dmg
```

| 플래그 | env | 의미 |
|---|---|---|
| `--sign=none\|adhoc\|identity` | `SUJI_SIGN` | 서명 모드(기본 adhoc) |
| `--identity=<id>` | `SUJI_SIGN_IDENTITY` | identity 서명 ID |
| `--notarize` | `SUJI_NOTARIZE` | xcrun notarytool + stapler |
| `--dmg` | `SUJI_DMG` | hdiutil UDZO .dmg |
| | `SUJI_NOTARIZE_APPLE_ID` / `SUJI_NOTARIZE_TEAM_ID` / `SUJI_NOTARIZE_PASSWORD` | 공증 자격증명 |
| | `SUJI_NOTARIZE_KEYCHAIN_PROFILE` | 위 대신 notarytool keychain profile |
| | `SUJI_WIN_SIGN_CERT` / `SUJI_WIN_SIGN_PASSWORD` | Windows signtool PFX |

- macOS: `none`=서명 생략, `adhoc`=로컬 실행용(배포 불가), `identity`=
  hardened runtime(`--options runtime`)+secure timestamp → 공증 전제.
  공증은 `identity` 서명 필수.
- Linux: `<name>-<ver>-linux-<arch>.tar.gz` (bin/ + resources/frontend +
  `<name>.desktop`). 서명 없음(배포처 위임 — zero-native 동일).
- Windows: `<name>-<ver>-windows-<arch>.zip`. `SUJI_WIN_SIGN_CERT` 있으면
  signtool Authenticode 서명.

## 모바일 서명 (배포)

### Android (`examples/android/<variant>`)
`app/build.gradle` 의 `signingConfigs.release` 가 env 주입 시에만 적용
(없으면 unsigned release — keystore 없이도 빌드 가능):

```
ANDROID_KEYSTORE_PATH=/path/key.jks ANDROID_KEYSTORE_PASSWORD=... \
ANDROID_KEY_ALIAS=... ANDROID_KEY_PASSWORD=... \
  ./gradlew :app:bundleRelease   # 서명된 AAB
```

### iOS (`examples/ios/<variant>`)
`_shared/archive-ios.sh` 가 archive+exportArchive(IPA):

```
SUJI_IOS_TEAM_ID=ABCDE12345 SUJI_IOS_EXPORT_METHOD=app-store \
  examples/ios/_shared/archive-ios.sh multi
# Apple 계정 없이 빌드 검증만:
SUJI_IOS_UNSIGNED=1 examples/ios/_shared/archive-ios.sh zig
```

`project.yml` 은 `DEVELOPMENT_TEAM=${SUJI_IOS_TEAM_ID}`/`CODE_SIGN_STYLE=
Automatic`(xcodegen env 치환). archive-ios.sh 가 xcodebuild 커맨드라인으로
재차 override(권위). `exportOptions.plist` 의 `__METHOD__`/`__TEAM_ID__`
토큰은 스크립트가 임시 치환(시크릿 미커밋).

## GitHub Secrets 일람

| Secret | 용도 | 사용처 |
|---|---|---|
| `MACOS_SIGN_IDENTITY` | suji CLI 바이너리 Developer ID 서명(선택) | release.yml cli(macOS) |
| `SUJI_SIGN_IDENTITY` | 사용자 앱 identity 서명 | `suji build` (env) |
| `SUJI_NOTARIZE_APPLE_ID` / `SUJI_NOTARIZE_TEAM_ID` / `SUJI_NOTARIZE_PASSWORD` | 공증 | `suji build --notarize` |
| `SUJI_NOTARIZE_KEYCHAIN_PROFILE` | 공증(keychain profile 방식) | 〃 |
| `SUJI_WIN_SIGN_CERT` / `SUJI_WIN_SIGN_PASSWORD` | Windows signtool PFX | `suji build`(Windows) |
| `ANDROID_KEYSTORE_PATH` / `ANDROID_KEYSTORE_PASSWORD` / `ANDROID_KEY_ALIAS` / `ANDROID_KEY_PASSWORD` | Android AAB/APK 서명 | gradle release |
| `SUJI_IOS_TEAM_ID` | iOS Apple Developer Team ID | archive-ios.sh / project.yml |
| `GITHUB_TOKEN` | Release 생성(기본 제공) | release.yml |
| `NPM_TOKEN` | `@suji/api`·`@suji/node` npm 발행 | sdk-publish.yml |
| `CARGO_REGISTRY_TOKEN` | crates.io `suji` 발행 | sdk-publish.yml |

CI 에서는 위 secret 을 해당 job step 의 `env:` 로 매핑해 주입한다(시크릿은
저장소에 커밋하지 않음 — `${SUJI_IOS_TEAM_ID}` 등은 런타임 치환).

## SDK 배포 (sdk-publish.yml)

| SDK | 채널 | 발행 |
|---|---|---|
| `@suji/api` (packages/suji-js) | npm | `npm publish` |
| `@suji/node` (packages/suji-node) | npm | `npm publish` |
| `suji` (crates/suji-rs) | crates.io | `cargo publish` |
| `github.com/ohah/suji-go` (sdks/suji-go) | Go (VCS 태그) | 발행 단계 없음 — `sdk-vX.Y.Z` 태그로 `go get @태그` |

- 기본(`workflow_dispatch`, `dry_run=true`): `npm pack`/`npm publish
  --dry-run`/`cargo publish --dry-run`/go build·vet **검증만**, 실제
  발행 안 함.
- 실제 발행: `git tag sdk-vX.Y.Z && git push --tags` 또는
  `dry_run=false`. 단 레지스트리 토큰(`NPM_TOKEN`/`CARGO_REGISTRY_TOKEN`)
  미설정 시 해당 발행 step 은 경고 후 자동 skip(안전).
- app 릴리스(`v*`)와 태그 네임스페이스 분리(`sdk-v*`).
- **crate 발행 순서**: `suji-macros`(leaf) → `suji`. `suji` 의 path
  dep 는 발행 시 registry 버전으로 해소되므로 `suji-macros` 가
  crates.io 에 먼저 있어야 한다. 그래서 검증 단계는 macros=dry-run,
  `suji`=`cargo check`(미발행 워크스페이스는 suji 의 publish --dry-run
  자체가 불가). 워크플로가 순서대로 발행 + 인덱스 반영 대기 처리.

## 검증 경계 (정직)

- 로컬 실증: `--sign=none/adhoc`, `--dmg`(UDZO), `--sign=identity` 누락 시
  에러, 비-macOS 패키징 의미컴파일, gradle/xcodegen 서명키 파싱.
- Apple 인증서/keystore/Apple 계정 필요 경로(identity 서명, 공증, 실 IPA,
  서명 AAB)는 시크릿 보유 환경에서만 실검증 가능 — 코드 경로/실패-fast는
  검증됨. release.yml `dry_run` 으로 CLI/임베드 파이프라인 전체 실검증.
