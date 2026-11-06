#!/usr/bin/env bash
# Fetch Lua runtimes and run the lunarbind test suite for every profile.
#
# Lua 5.1-5.5 are built from the official lua.org sources. LuaJIT is built from
# its official git source. Static libraries are cached under .lua/linux/ and are
# not committed.
set -euo pipefail

root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
runtime_root="$root/.lua/linux"
download_root="$runtime_root/downloads"
source_root="$runtime_root/src"

profiles=(lua51 lua52 lua53 lua54 lua55 luajit)
compiler=${COMPILER:-ldc2}
dub=${DUB:-dub}
force=0

usage() {
    cat <<'EOF'
Usage: tools/test-lua.sh [options]

Options:
  --profiles LIST   Comma-separated profiles (default: lua51,lua52,lua53,lua54,lua55,luajit)
  --compiler NAME   D compiler passed to dub (default: ldc2)
  --dub PATH        dub executable (default: dub)
  --force           Re-download and rebuild cached runtimes
  -h, --help        Show this help
EOF
}

while (($#)); do
    case "$1" in
        --profiles)
            IFS=, read -r -a profiles <<<"${2:?missing value for --profiles}"
            shift 2
            ;;
        --profiles=*)
            IFS=, read -r -a profiles <<<"${1#*=}"
            shift
            ;;
        --compiler)
            compiler=${2:?missing value for --compiler}
            shift 2
            ;;
        --compiler=*)
            compiler=${1#*=}
            shift
            ;;
        --dub)
            dub=${2:?missing value for --dub}
            shift 2
            ;;
        --dub=*)
            dub=${1#*=}
            shift
            ;;
        --force)
            force=1
            shift
            ;;
        -h | --help)
            usage
            exit 0
            ;;
        *)
            echo "unknown option: $1" >&2
            usage >&2
            exit 2
            ;;
    esac
done

if ((${#profiles[@]} == 0)); then
    echo "no profiles selected" >&2
    exit 2
fi

for tool in curl tar make "$dub" "$compiler"; do
    if ! command -v "$tool" >/dev/null 2>&1; then
        echo "required tool not found: $tool" >&2
        exit 1
    fi
done

mkdir -p "$download_root" "$source_root"

jobs=$(getconf _NPROCESSORS_ONLN 2>/dev/null || echo 2)

lua_version() {
    case "$1" in
        lua51) echo 5.1.5 ;;
        lua52) echo 5.2.4 ;;
        lua53) echo 5.3.6 ;;
        lua54) echo 5.4.8 ;;
        # LuaBinaries only ships 5.5.0 on Windows; Linux tracks the latest
        # patch release so both patch versions are covered by CI.
        lua55) echo 5.5.1 ;;
        *) return 1 ;;
    esac
}

download() {
    local url=$1 destination=$2
    if [[ -f $destination && $force -eq 0 ]]; then
        echo "  cached: $destination"
        return
    fi

    echo "  downloading: $url"
    local tmp="$destination.part"
    rm -f "$tmp"
    if ! curl -fsSL --connect-timeout 15 --retry 3 --retry-delay 2 -o "$tmp" "$url"; then
        rm -f "$tmp"
        echo "download failed: $url" >&2
        return 1
    fi
    mv -f "$tmp" "$destination"
}

build_lua() {
    local profile=$1 version src libdir lib
    version=$(lua_version "$profile") || {
        echo "unknown profile: $profile" >&2
        return 1
    }

    libdir="$runtime_root/$profile/lib"
    lib="$libdir/liblua${version%.*}.a"
    if [[ -f $lib && $force -eq 0 ]]; then
        echo "  runtime ready: $libdir"
        return
    fi

    local archive="$download_root/lua-$version.tar.gz"
    if ! download "https://www.lua.org/ftp/lua-$version.tar.gz" "$archive"; then
        return 1
    fi

    src="$source_root/lua-$version"
    if [[ ! -d $src || $force -eq 1 ]]; then
        rm -rf "$src"
        tar -xzf "$archive" -C "$source_root"
    fi

    echo "  building Lua $version"
    make -C "$src/src" clean >/dev/null 2>&1 || true
    local log="$runtime_root/build-$profile.log"
    if ! make -C "$src/src" liblua.a -j"$jobs" \
        MYCFLAGS="-fPIC -DLUA_USE_LINUX" >"$log" 2>&1; then
        echo "Lua $version build failed; see $log" >&2
        tail -n 30 "$log" >&2
        return 1
    fi

    mkdir -p "$libdir"
    cp -f "$src/src/liblua.a" "$lib"
    echo "  runtime ready: $libdir"
}

build_luajit() {
    local libdir="$runtime_root/luajit/lib"
    local lib="$libdir/libluajit-5.1.a"
    if [[ -f $lib && $force -eq 0 ]]; then
        echo "  runtime ready: $libdir"
        return
    fi

    local archive="$download_root/LuaJIT-v2.1.tar.gz"
    if ! download "https://codeload.github.com/LuaJIT/LuaJIT/tar.gz/refs/heads/v2.1" "$archive"; then
        return 1
    fi

    local src="$source_root/LuaJIT-2.1"
    if [[ ! -d $src || $force -eq 1 ]]; then
        rm -rf "$src"
        tar -xzf "$archive" -C "$source_root"
    fi

    echo "  building LuaJIT"
    make -C "$src/src" clean >/dev/null 2>&1 || true
    local log="$runtime_root/build-luajit.log"
    if ! make -C "$src/src" libluajit.a -j"$jobs" >"$log" 2>&1; then
        echo "LuaJIT build failed; see $log" >&2
        tail -n 30 "$log" >&2
        return 1
    fi

    mkdir -p "$libdir"
    cp -f "$src/src/libluajit.a" "$lib"
    echo "  runtime ready: $libdir"
}

run_profile() {
    local profile=$1 runtime
    echo
    echo "== $profile =="

    case "$profile" in
        luajit) build_luajit ;;
        lua51 | lua52 | lua53 | lua54 | lua55) build_lua "$profile" ;;
        *)
            echo "unknown profile: $profile" >&2
            return 1
            ;;
    esac

    runtime="$runtime_root/$profile/lib"
    local -a args=(test --root="$root" --config="$profile" --compiler="$compiler")
    if [[ $force -eq 1 ]]; then
        args+=(--force)
    fi

    LIBRARY_PATH="$runtime${LIBRARY_PATH:+:$LIBRARY_PATH}" \
        LD_LIBRARY_PATH="$runtime${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}" \
        "$dub" "${args[@]}"
}

echo "lunarbind Lua runtime test"
echo "  root:     $root"
echo "  compiler: $compiler"
echo "  profiles: ${profiles[*]}"

for profile in "${profiles[@]}"; do
    run_profile "$profile"
done

echo
echo "all profiles passed"
