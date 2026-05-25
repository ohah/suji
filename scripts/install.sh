#!/usr/bin/env sh
set -eu

owner_repo="${SUJI_REPO:-ohah/suji}"
version="${SUJI_VERSION:-latest}"
install_dir="${SUJI_INSTALL_DIR:-${HOME}/.suji/bin}"
base_url="${SUJI_RELEASE_BASE_URL:-}"
platform_override="${SUJI_INSTALL_PLATFORM:-}"

usage() {
  cat >&2 <<'EOF'
Usage: scripts/install.sh [--version X.Y.Z|latest] [--install-dir DIR] [--repo OWNER/REPO] [--base-url URL]

Environment:
  SUJI_VERSION            Version to install, or "latest" (default)
  SUJI_INSTALL_DIR        Destination directory (default: ~/.suji/bin)
  SUJI_REPO               GitHub repository (default: ohah/suji)
  SUJI_RELEASE_BASE_URL   Override release asset base URL
  SUJI_INSTALL_PLATFORM   Override detected platform: macos-arm64, linux-x64, windows-x64
EOF
}

error() {
  echo "suji install: $*" >&2
  exit 2
}

while [ "$#" -gt 0 ]; do
  case "$1" in
    --version)
      [ "$#" -ge 2 ] || error "--version requires a value"
      version="$2"
      shift 2
      ;;
    --install-dir)
      [ "$#" -ge 2 ] || error "--install-dir requires a value"
      install_dir="$2"
      shift 2
      ;;
    --repo)
      [ "$#" -ge 2 ] || error "--repo requires a value"
      owner_repo="$2"
      shift 2
      ;;
    --base-url)
      [ "$#" -ge 2 ] || error "--base-url requires a value"
      base_url="$2"
      shift 2
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      usage
      error "unknown argument: $1"
      ;;
  esac
done

need_cmd() {
  command -v "$1" >/dev/null 2>&1 || error "required command not found: $1"
}

detect_platform() {
  if [ -n "$platform_override" ]; then
    case "$platform_override" in
      macos-arm64|linux-x64|windows-x64) printf '%s\n' "$platform_override"; return 0 ;;
      *) error "unsupported platform override: $platform_override" ;;
    esac
  fi

  os="$(uname -s)"
  arch="$(uname -m)"
  case "${os}:${arch}" in
    Darwin:arm64|Darwin:aarch64) printf '%s\n' "macos-arm64" ;;
    Linux:x86_64|Linux:amd64) printf '%s\n' "linux-x64" ;;
    MINGW*:x86_64|MSYS*:x86_64|CYGWIN*:x86_64) printf '%s\n' "windows-x64" ;;
    *) error "unsupported platform: ${os} ${arch}" ;;
  esac
}

sha256_file() {
  file="$1"
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum "$file" | awk '{print $1}'
  elif command -v shasum >/dev/null 2>&1; then
    shasum -a 256 "$file" | awk '{print $1}'
  elif command -v openssl >/dev/null 2>&1; then
    openssl dgst -sha256 "$file" | awk '{print $NF}'
  else
    error "required command not found: sha256sum, shasum, or openssl"
  fi
}

verify_checksum() {
  file="$1"
  checksum_file="$2"
  expected="$(awk '{print $1}' "$checksum_file" | head -n 1)"
  expected_len="$(printf '%s' "$expected" | wc -c | tr -d ' ')"
  case "$expected" in
    ""|*[!0123456789abcdefABCDEF]*) error "invalid checksum file: $checksum_file" ;;
  esac
  [ "$expected_len" = "64" ] || error "invalid checksum file: $checksum_file"

  actual="$(sha256_file "$file")"
  expected="$(printf '%s' "$expected" | tr 'A-F' 'a-f')"
  actual="$(printf '%s' "$actual" | tr 'A-F' 'a-f')"
  [ "$expected" = "$actual" ] || error "checksum mismatch for $(basename "$file")"
}

platform="$(detect_platform)"
case "$platform" in
  macos-arm64)
    asset="suji-macos-arm64"
    archive_name="${asset}.tar.gz"
    binary_name="suji"
    ;;
  linux-x64)
    asset="suji-linux-x64"
    archive_name="${asset}.tar.gz"
    binary_name="suji"
    ;;
  windows-x64)
    asset="suji-windows-x64"
    archive_name="${asset}.zip"
    binary_name="suji.exe"
    ;;
  *)
    error "unsupported platform: $platform"
    ;;
esac

if [ -z "$base_url" ]; then
  case "$version" in
    latest)
      base_url="https://github.com/${owner_repo}/releases/latest/download"
      ;;
    v[0-9]*)
      base_url="https://github.com/${owner_repo}/releases/download/${version}"
      ;;
    [0-9]*)
      base_url="https://github.com/${owner_repo}/releases/download/v${version}"
      ;;
    *)
      error "invalid version: $version"
      ;;
  esac
fi
base_url="${base_url%/}"

need_cmd curl
case "$archive_name" in
  *.tar.gz) need_cmd tar ;;
  *.zip) need_cmd unzip ;;
esac

tmp_dir="$(mktemp -d "${TMPDIR:-/tmp}/suji-install.XXXXXX")"
cleanup() {
  rm -rf "$tmp_dir"
}
trap cleanup EXIT INT TERM

archive_path="${tmp_dir}/${archive_name}"
checksum_path="${archive_path}.sha256"

echo "Downloading ${archive_name} from ${base_url}"
curl -fsSL "${base_url}/${archive_name}" -o "$archive_path"
curl -fsSL "${base_url}/${archive_name}.sha256" -o "$checksum_path"
verify_checksum "$archive_path" "$checksum_path"

extract_dir="${tmp_dir}/extract"
mkdir -p "$extract_dir"
case "$archive_name" in
  *.tar.gz) tar -xzf "$archive_path" -C "$extract_dir" ;;
  *.zip) unzip -q "$archive_path" -d "$extract_dir" ;;
esac

binary_path="$(find "$extract_dir" -type f -name "$binary_name" | head -n 1)"
[ -n "$binary_path" ] || error "archive did not contain ${binary_name}"

mkdir -p "$install_dir"
cp "$binary_path" "${install_dir}/${binary_name}"
chmod 0755 "${install_dir}/${binary_name}"

echo "Installed ${binary_name} to ${install_dir}/${binary_name}"
case ":${PATH:-}:" in
  *":${install_dir}:"*) ;;
  *) echo "Add ${install_dir} to PATH to run suji from any shell." ;;
esac
