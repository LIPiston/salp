#!/usr/bin/env bash
# Build a minimal pinned FreeRDP shared library against the Linux CI baseline.
set -euo pipefail
task_root="$(git rev-parse --show-toplevel)"
native="$task_root/.ci/linux-native"
mkdir -p "$native/src" "$native/prefix"
archive="$native/src/freerdp-3.33.1.tar.gz"
if [[ ! -f "$archive" ]]; then
  curl --fail --location --retry 3 \
    https://codeload.github.com/FreeRDP/FreeRDP/tar.gz/refs/tags/3.33.1 \
    --output "$archive"
fi
echo "6b6da1e7217f924b033da6896e70eb4c4a447c3900d03c0d10179062f0a7d495  $archive" | sha256sum --check
if [[ ! -d "$native/src/FreeRDP-3.33.1" ]]; then
  tar -xzf "$archive" -C "$native/src"
fi
flags=(
  -DCMAKE_BUILD_TYPE=Release -DCMAKE_INSTALL_PREFIX="$native/prefix"
  -DCMAKE_INSTALL_LIBDIR=lib -DBUILD_SHARED_LIBS=ON -DBUILD_TESTING=OFF
  -DWITH_OPENSSL=ON -DWITH_UNICODE_BUILTIN=ON
)
for feature in CLIENT CLIENT_COMMON SERVER SAMPLE CHANNELS MANPAGES FFMPEG SWSCALE \
  OPENH264 JPEG WEBP CAIRO PULSE ALSA CUPS PCSC PKCS11 KRB5 GSSAPI WINPR_JSON AAD \
  URIPARSER WINPR_TOOLS X11 WAYLAND OPUS FAAC FAAD2 LAME SOXR MBEDTLS CCACHE \
  CLANG_FORMAT SMARTCARD_EMULATE ICU LIBSYSTEMD FUSE OSS SNDIO; do
  flags+=("-DWITH_$feature=OFF")
done
cmake -S "$native/src/FreeRDP-3.33.1" -B "$native/build" -GNinja "${flags[@]}"
cmake --build "$native/build" --parallel 4
cmake --install "$native/build"
