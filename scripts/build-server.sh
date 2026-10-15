#!/usr/bin/env bash
set -Eeuo pipefail

[[ "${VERSION:-}" =~ ^(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)$ ]]
action_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
rust_version=$(sed -n 's/^channel = "\([0-9.]*\)"$/\1/p' backend/rust-toolchain.toml)
[[ "$rust_version" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]
mkdir -p .cache/cargo/registry .cache/cargo/git .cache/target .cache/fonts dist/image/fonts
# Compile against Bookworm, matching the runtime's libc, with Cargo outputs cached
# between releases. Server compilation does not wait for the Web build.
docker run --rm --platform linux/amd64 \
  -v "$PWD/backend:/src" -w /src \
  -v "$PWD/.cache/cargo/registry:/usr/local/cargo/registry" \
  -v "$PWD/.cache/cargo/git:/usr/local/cargo/git" \
  -v "$PWD/.cache/target:/src/target" \
  "rust:$rust_version-slim-bookworm" cargo build --release --locked --bin one-ip-backend
cp .cache/target/release/one-ip-backend dist/image/

for spec in 'Regular:faa6c9df652116dde789d351359f3d7e5d2285a2b2a1f04a2d7244df706d5ea9' 'Bold:c6cb5a93abaa9edc8ee7463b7ebb7f42d618d40e6ed2f7a5371c97b0b64767c0'; do
  font="NotoSansSC-${spec%%:*}.otf"; digest="${spec#*:}"; cached=".cache/fonts/$font"
  if [ ! -f "$cached" ] || [ "$(sha256sum "$cached" | cut -d ' ' -f 1)" != "$digest" ]; then
    curl --fail --silent --show-error --location --retry 5 --retry-all-errors \
      --output "$cached.part" "https://github.com/notofonts/noto-cjk/raw/Sans2.004/Sans/SubsetOTF/SC/$font"
    printf '%s  %s\n' "$digest" "$cached.part" | sha256sum --check --strict
    mv "$cached.part" "$cached"
  fi
  cp "$cached" dist/image/fonts/
done

# Only the compiled binary and verified fonts enter the public runtime image.
docker build --platform linux/amd64 --pull --file "$action_dir/deploy/Dockerfile" \
  --tag "one-ip:$VERSION" dist/image
docker save "one-ip:$VERSION" | gzip -1 > dist/server-image.tar.gz
cp backend/deploy/docker/docker-compose.yml dist/docker-compose.yml
