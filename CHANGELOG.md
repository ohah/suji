# Changelog

릴리스 노트는 아래 마커 사이 블록이 GitHub Release 본문으로 추출된다
(release.yml). 새 버전 시 build.zig.zon `.version` 갱신 + 이 블록 작성 후
`vX.Y.Z` 태그 푸시.

<!-- release:start -->
## v0.1.0

- 초기 릴리스 파이프라인: GitHub Releases 자동화(데스크톱 CLI 바이너리
  3-OS + 임베드 코어 라이브러리 host/iOS/Android/Windows + 체크섬).
- macOS 서명 모드(none/adhoc/identity) + 공증(notarytool/stapler) + .dmg.
- Windows/Linux 데스크톱 패키징(zip / tar.gz + .desktop, 선택 signtool).
- 모바일 릴리스 서명(Android keystore signingConfig / iOS exportOptions
  + archive-ios.sh).
<!-- release:end -->
