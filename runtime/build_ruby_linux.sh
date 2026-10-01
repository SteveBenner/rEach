#!/usr/bin/env bash
set -euo pipefail

RUBY_VERSION="4.0.7"
RUBY_URL="https://cache.ruby-lang.org/pub/ruby/4.0/ruby-4.0.7.tar.gz"
RUBY_SHA256="911ace20f90d068ca0e4dda6d0e4f0f81e52e52f2dd4f4004c721e253412e82d"
OPENSSL_URL="https://github.com/openssl/openssl/releases/download/openssl-3.5.9/openssl-3.5.9.tar.gz"
OPENSSL_SHA256="603f5602e2eef00d77fbd429d34dcd5822bb301757a1bc9cdb24c670f1eb859a"
LIBYAML_URL="https://github.com/yaml/libyaml/releases/download/0.2.5/yaml-0.2.5.tar.gz"
LIBYAML_SHA256="c642ae9b75fee120b2d96c712538bd2cf283228d2337df2cf2988e3c02678ef4"
LIBFFI_URL="https://github.com/libffi/libffi/releases/download/v3.8.0/libffi-3.8.0.tar.gz"
LIBFFI_SHA256="7da3e2d9a171eb0a038f592ecad3ff2bb2550f3496d87b3b29ad0cf4430c0db4"
ZLIB_URL="https://github.com/madler/zlib/releases/download/v1.3.2/zlib-1.3.2.tar.gz"
ZLIB_SHA256="bb329a0a2cd0274d05519d61c667c062e06990d72e125ee2dfa8de64f0119d16"
GLIBC_CEILING="2.28"
CURL_FLAGS="-fsSL --retry 3 --connect-timeout 30 --max-time 600"
FETCH_ATTEMPTS=3

fail() {
  echo "build_ruby_linux: $*" >&2
  exit 1
}

usage() {
  fail "usage: build_ruby_linux.sh OUTPUT_DIR [WORK_DIR]"
}

[ $# -ge 1 ] && [ $# -le 2 ] || usage
out="$1"
[ "$(uname -s)" = "Linux" ] || fail "this script builds on Linux only"
mkdir -p "$out"
out="$(cd "$out" && pwd)"
if [ -n "$(ls -A "$out")" ]; then
  fail "output directory $out is not empty"
fi
work="${2:-$(mktemp -d)}"
mkdir -p "$work"
work="$(cd "$work" && pwd)"
deps="$work/deps"
src="$work/src"
mkdir -p "$deps" "$src"
jobs="$(nproc)"

for tool in gcc make perl curl tar sha256sum objdump; do
  command -v "$tool" >/dev/null 2>&1 || fail "missing build tool $tool"
done
perl -MIPC::Cmd -MTime::Piece -MFindBin -MFile::Compare -e1 >/dev/null 2>&1 || fail "perl lacks IPC::Cmd or Time::Piece, needed to configure OpenSSL (dnf install perl-IPC-Cmd perl-Time-Piece)"

fetch() {
  local url="$1" sha="$2" file="$src/$(basename "$1")" attempt=1
  until curl $CURL_FLAGS -o "$file" "$url"; do
    [ "$attempt" -lt "$FETCH_ATTEMPTS" ] || fail "could not download $url"
    attempt=$((attempt + 1))
    sleep $((attempt * attempt))
  done
  echo "$sha  $file" | sha256sum -c - >/dev/null || fail "sha256 mismatch for $url"
  FETCHED="$file"
}

unpack() {
  local top
  top="$(tar -tzf "$FETCHED" | sed -n '1s#/.*##p')"
  [ -n "$top" ] || fail "empty archive $FETCHED"
  tar -xzf "$FETCHED" -C "$src" || fail "could not unpack $FETCHED"
  UNPACKED="$src/$top"
}

export CFLAGS="-O2 -fPIC"
export PKG_CONFIG_PATH="$deps/lib/pkgconfig"

fetch "$OPENSSL_URL" "$OPENSSL_SHA256"
unpack
openssl_dir="$UNPACKED"
(
  cd "$openssl_dir"
  ./Configure no-shared no-tests no-docs --prefix="$deps" --libdir=lib --openssldir=/etc/ssl -fPIC
  make -j"$jobs"
  make install_sw
)

fetch "$LIBYAML_URL" "$LIBYAML_SHA256"
unpack
libyaml_dir="$UNPACKED"
(
  cd "$libyaml_dir"
  ./configure --prefix="$deps" --libdir="$deps/lib" --disable-shared --enable-static --with-pic
  make -j"$jobs"
  make install
)

fetch "$LIBFFI_URL" "$LIBFFI_SHA256"
unpack
libffi_dir="$UNPACKED"
(
  cd "$libffi_dir"
  ./configure --prefix="$deps" --libdir="$deps/lib" --disable-shared --enable-static --with-pic --disable-docs
  make -j"$jobs"
  make install
)

fetch "$ZLIB_URL" "$ZLIB_SHA256"
unpack
zlib_dir="$UNPACKED"
(
  cd "$zlib_dir"
  ./configure --prefix="$deps" --libdir="$deps/lib" --static
  make -j"$jobs"
  make install
)

fetch "$RUBY_URL" "$RUBY_SHA256"
unpack
ruby_dir="$UNPACKED"
(
  cd "$ruby_dir"
  ./configure --prefix="$out" --enable-load-relative --disable-install-doc --disable-rpath --enable-shared=no \
    --with-openssl-dir="$deps" --with-libyaml-dir="$deps" --with-zlib-dir="$deps" --without-gmp \
    CPPFLAGS="-I$deps/include" LDFLAGS="-L$deps/lib"
  make -j"$jobs"
  make install
)

[ -x "$out/bin/ruby" ] || fail "no $out/bin/ruby after install"
[ -d "$out/lib/ruby" ] || fail "no $out/lib/ruby after install"

built="$("$out/bin/ruby" -e 'print RUBY_VERSION')"
[ "$built" = "$RUBY_VERSION" ] || fail "built ruby $built, expected $RUBY_VERSION"
"$out/bin/ruby" -ropenssl -ryaml -rfiddle -rzlib -rdigest -rsocket -e 'print :ok' >/dev/null \
  || fail "built ruby cannot load openssl, psych, fiddle, zlib, digest and socket"
"$out/bin/ruby" -ropenssl -e 'abort("openssl is not 3.x: #{OpenSSL::OPENSSL_LIBRARY_VERSION}") unless OpenSSL::OPENSSL_LIBRARY_VERSION.include?("OpenSSL 3.")'

ceiling_ok() {
  local file="$1" worst
  worst="$(objdump -T "$file" 2>/dev/null | grep -o 'GLIBC_[0-9][0-9.]*' | sed 's/GLIBC_//' | sort -uV | tail -1)"
  [ -z "$worst" ] && return 0
  [ "$(printf '%s\n%s\n' "$worst" "$GLIBC_CEILING" | sort -V | tail -1)" = "$GLIBC_CEILING" ]
}

while IFS= read -r file; do
  if ! ceiling_ok "$file"; then
    fail "$file requires a GLIBC symbol version above $GLIBC_CEILING"
  fi
  needed="$(objdump -p "$file" 2>/dev/null | awk '/NEEDED/ {print $2}')"
  if echo "$needed" | grep -Eq '^lib(ssl|crypto|yaml|ffi|z|gmp)\.so'; then
    fail "$file links a shared dependency that must be static: $(echo "$needed" | grep -E '^lib(ssl|crypto|yaml|ffi|z|gmp)\.so' | tr '\n' ' ')"
  fi
done < <(find "$out" -type f \( -name '*.so' -o -name '*.so.*' -o -path "$out/bin/*" \) -exec sh -c 'head -c4 "$1" | grep -q ELF && echo "$1"' _ {} \;)

echo "built ruby $built into $out"
