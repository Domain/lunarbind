#!/usr/bin/env bash
# Build and run the coverage-guided fuzz target for one Lua profile.
#
# The target lives in fuzz/fuzz_target.d and uses LDC's ldc.libfuzzer mixin.
# The script locates the compiler-rt libFuzzer runtime that matches LDC's LLVM
# version, downloads the matching Debian package when it is not installed, and
# links it by hand because LDC does not bundle compiler-rt on all platforms.
#
# The cached Lua runtime is built with tools/test-lua.sh --runtime-only when it
# is missing, so no Lua binaries are committed. Corpora and crash artifacts are
# kept under the git-ignored .lua/fuzz/ directory.
set -euo pipefail

root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
runtime_root="$root/.lua/linux"
fuzz_root="$root/.lua/fuzz"
corpus="$fuzz_root/corpus"
artifacts="$fuzz_root/artifacts"

profile=lua54
compiler=${COMPILER:-ldc2}
sanitize=1
max_time=60
runs=0
seed=1
fuzzer_rt=${FUZZER_RT:-}

usage() {
    cat <<'EOF'
Usage: tools/fuzz.sh [options]

Options:
  --profile NAME        Lua profile (default: lua54)
  --compiler PATH       LDC compiler (default: ldc2 or $COMPILER)
  --fuzzer-rt PATH      libclang_rt.fuzzer-<arch>.a to link
  --max-total-time SEC  Fuzzing time limit (default: 60)
  --runs N              Run exactly N inputs instead of using a time limit
  --corpus DIR          Corpus directory (default: .lua/fuzz/corpus)
  --no-seed             Do not create the initial seed corpus
  --sanitize            Build with AddressSanitizer (default)
  --no-sanitize         Build without AddressSanitizer
  -h, --help            Show this help
EOF
}

while (($#)); do
    case "$1" in
        --profile)
            profile=${2:?missing value for --profile}
            shift 2
            ;;
        --profile=*)
            profile=${1#*=}
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
        --fuzzer-rt)
            fuzzer_rt=${2:?missing value for --fuzzer-rt}
            shift 2
            ;;
        --fuzzer-rt=*)
            fuzzer_rt=${1#*=}
            shift
            ;;
        --max-total-time)
            max_time=${2:?missing value for --max-total-time}
            shift 2
            ;;
        --max-total-time=*)
            max_time=${1#*=}
            shift
            ;;
        --runs)
            runs=${2:?missing value for --runs}
            shift 2
            ;;
        --runs=*)
            runs=${1#*=}
            shift
            ;;
        --corpus)
            corpus=${2:?missing value for --corpus}
            shift 2
            ;;
        --corpus=*)
            corpus=${1#*=}
            shift
            ;;
        --no-seed)
            seed=0
            shift
            ;;
        --sanitize)
            sanitize=1
            shift
            ;;
        --no-sanitize)
            sanitize=0
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

for tool in find sort "$compiler"; do
    if ! command -v "$tool" >/dev/null 2>&1; then
        echo "required tool not found: $tool" >&2
        exit 1
    fi
done

case "$profile" in
    lua51) versions=(LUA_51); lua_version=5.1.5 ;;
    lua52) versions=(LUA_52); lua_version=5.2.4 ;;
    lua53) versions=(LUA_53); lua_version=5.3.6 ;;
    lua54) versions=(LUA_54); lua_version=5.4.8 ;;
    lua55) versions=(LUA_55); lua_version=5.5.1 ;;
    luajit) versions=(LUA_51 LUAJIT); lua_version= ;;
    *)
        echo "unknown profile: $profile" >&2
        exit 2
        ;;
esac

if [[ $profile == luajit ]]; then
    lua_lib="$runtime_root/luajit/lib/libluajit-5.1.a"
else
    lua_lib="$runtime_root/$profile/lib/liblua${lua_version%.*}.a"
fi

if [[ ! -f $lua_lib ]]; then
    echo "Lua runtime for $profile is not cached; building it"
    "$root/tools/test-lua.sh" --profiles "$profile" --runtime-only
fi

if [[ ! -f $lua_lib ]]; then
    echo "Lua runtime library not found after setup: $lua_lib" >&2
    exit 1
fi

find_fuzzer_rt() {
    local major=$1 found
    if [[ -n $fuzzer_rt ]]; then
        if [[ -f $fuzzer_rt ]]; then
            return 0
        fi
        return 1
    fi

    for candidate in \
        "$root/.lua/toolchain/fuzz-rt/extracted/usr/lib/llvm-$major/lib/clang/$major/lib/linux/libclang_rt.fuzzer-x86_64.a" \
        "/usr/lib/llvm-$major/lib/clang/$major/lib/linux/libclang_rt.fuzzer-x86_64.a"; do
        if [[ -f $candidate ]]; then
            fuzzer_rt=$candidate
            return 0
        fi
    done

    found=$(find /usr/lib/llvm-* "$root/.lua/toolchain/fuzz-rt" \
        -type f -name 'libclang_rt.fuzzer-x86_64.a' 2>/dev/null |
        sort -V | tail -n 1 || true)
    if [[ -n $found ]]; then
        fuzzer_rt=$found
        return 0
    fi
    return 1
}

llvm_major=$("$compiler" --version 2>/dev/null |
    sed -n 's/.*LLVM \([0-9][0-9]*\).*/\1/p' | head -n 1)
if [[ -z $llvm_major ]]; then
    echo "could not determine the LLVM version used by $compiler" >&2
    exit 1
fi

if ! find_fuzzer_rt "$llvm_major"; then
    if command -v apt-get >/dev/null 2>&1 &&
        command -v dpkg-deb >/dev/null 2>&1; then
        rt_cache="$root/.lua/toolchain/fuzz-rt"
        mkdir -p "$rt_cache"
        package="libclang-rt-$llvm_major-dev"
        echo "libFuzzer runtime for LLVM $llvm_major not found; fetching $package"
        if ! (cd "$rt_cache" && apt-get download "$package"); then
            echo "could not download $package" >&2
            echo "install it with: sudo apt-get install $package" >&2
            exit 1
        fi
        deb=$(find "$rt_cache" -maxdepth 1 -name "${package}_*.deb" -print |
            sort -V | tail -n 1)
        if [[ -z $deb ]]; then
            echo "downloaded package for $package not found" >&2
            exit 1
        fi
        dpkg-deb -x "$deb" "$rt_cache/extracted"
    fi

    if ! find_fuzzer_rt "$llvm_major"; then
        echo "libFuzzer runtime for LLVM $llvm_major was not found" >&2
        echo "pass --fuzzer-rt PATH or set FUZZER_RT" >&2
        exit 1
    fi
fi

echo "lunarbind fuzz target"
echo "  profile:   $profile"
echo "  compiler:  $compiler"
echo "  fuzzer rt: $fuzzer_rt"
echo "  sanitize:  $([[ $sanitize -eq 1 ]] && echo address || echo no)"

exe="$runtime_root/$profile/fuzz-target"
flags=(-i -I"$root/source" -g -O1)
if [[ $sanitize -eq 1 ]]; then
    flags+=(-fsanitize=address,fuzzer)
else
    flags+=(-fsanitize=fuzzer)
fi

defs=()
for version in "${versions[@]}"; do
    defs+=("-d-version=$version")
done

echo "  building:  $exe"
if ! "$compiler" "${flags[@]}" "${defs[@]}" \
    "$root/fuzz/fuzz_target.d" "$lua_lib" "$fuzzer_rt" \
    -L=-lstdc++ -L=-lm -L=-ldl -of="$exe"; then
    echo "fuzz target build failed" >&2
    exit 1
fi

mkdir -p "$corpus" "$artifacts"
if [[ $seed -eq 1 && -z $(find "$corpus" -type f -print -quit) ]]; then
    echo "  seeding:   $corpus"
    for op in $(seq 0 13); do
        for variant in $(seq 0 4); do
            {
                printf "\\$(printf '%03o' "$op")"
                printf "\\$(printf '%03o' "$variant")"
                for i in $(seq 0 61); do
                    printf "\\$(printf '%03o' \
                        $(((i * 37 + op * 11 + variant * 53) % 256)))"
                done
            } >"$corpus/seed-$op-$variant"
        done
    done
fi

run_args=(-max_len=4096 -timeout=10 -print_final_stats=1
    -artifact_prefix="$artifacts/")
if ((runs > 0)); then
    run_args+=("-runs=$runs")
else
    run_args+=("-max_total_time=$max_time")
fi

echo "  corpus:    $corpus"
echo "  artifacts: $artifacts"
echo "  running"
ASAN_OPTIONS="detect_leaks=0${ASAN_OPTIONS:+:$ASAN_OPTIONS}" \
    "$exe" "${run_args[@]}" "$corpus"
