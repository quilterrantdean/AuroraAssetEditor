#!/usr/bin/env bash
#
# build-tls.sh - pilha TLS estática para Windows XP SP3 / Pentium 4 Prescott
#
# Compila, para i686-w64-mingw32:
#   - zlib 1.3.1
#   - OpenSSL 1.1.1w (mingw, no-shared, no-tests, no-asm, no-dso,
#     no-engine, no-capieng)
#   - libcurl 8.11.0 (estático, só HTTP/HTTPS, sem APIs Vista+)
#   - AuroraTls.dll (transporte nativo usado por AuroraHttpClient.cs)
#
# Alvo: Windows XP SP3 (5.01), x86, Intel Pentium 4 HT "Prescott".
#
# Suporte primário: shell MSYS2 MINGW32 (msys2/setup-msys2@v2).  O MINGW32
# está a ser descontinuado pela MSYS2 (2026), por isso o script também corre
# em Linux com o cross-compiler `gcc-mingw-w64-i686` (ver README.md): o mesmo
# HOST (i686-w64-mingw32), sem cygpath.
#
# Cache:
#   DEPS_PREFIX (por omissão C:/xp-prescott-deps em Windows) é pensado para ser
#   reposto por actions/cache.  Se as bibliotecas estáticas e headers já lá
#   estiverem, as três dependências são saltadas; AuroraTls.dll e cacert.pem
#   são sempre produzidos.
#
# Variáveis de ambiente:
#   ZLIB_VERSION, OPENSSL_VERSION, CURL_VERSION
#   DEPS_PREFIX, XP_NATIVE_OUT, JOBS, HOST, BUILD_ROOT
#
# Utilização (shell MSYS2 MINGW32):
#   bash xp-port/build-tls.sh
#
set -euo pipefail

ZLIB_VERSION="${ZLIB_VERSION:-1.3.1}"
OPENSSL_VERSION="${OPENSSL_VERSION:-1.1.1w}"
CURL_VERSION="${CURL_VERSION:-8.11.0}"
HOST="${HOST:-i686-w64-mingw32}"
JOBS="${JOBS:-$(nproc)}"
BUILD_ROOT="${BUILD_ROOT:-/tmp/xp-build}"

# cygpath só existe em Windows (MSYS2/Cygwin); em Linux os caminhos já são POSIX.
to_unix() {
    if command -v cygpath >/dev/null 2>&1; then
        cygpath -u "$1"
    else
        printf '%s\n' "$1"
    fi
}

if [ -n "${DEPS_PREFIX:-}" ]; then
    :
elif command -v cygpath >/dev/null 2>&1; then
    DEPS_PREFIX="C:/xp-prescott-deps"
else
    DEPS_PREFIX="${RUNNER_TEMP:-/tmp}/xp-prescott-deps"
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PREFIX_UNIX="$(to_unix "$DEPS_PREFIX")"

if [ -n "${XP_NATIVE_OUT:-}" ]; then
    OUT_DIR="$(to_unix "$XP_NATIVE_OUT")"
else
    OUT_DIR="$(to_unix "${RUNNER_TEMP:-/tmp}")/xp-native"
fi

CC="${CC:-${HOST}-gcc}"
AR="${AR:-${HOST}-ar}"
RANLIB="${RANLIB:-${HOST}-ranlib}"

# ---------------------------------------------------------------------------
# Flags do compilador / linker
#
# -march=prescott activa SSE2 + SSE3 (o conjunto de instruções do Prescott) e
# mantém SSSE3/SSE4/AVX desligados.  -mfpmath=sse evita surpresas de precisão
# x87.  -std=gnu99 fixa o dialecto C para o qual OpenSSL 1.1.1 / curl 8.11 /
# zlib foram escritos, independentemente do default (gnu23) do GCC 15+.
# Os campos PE tornam todas as imagens carregáveis no XP SP3.
# ---------------------------------------------------------------------------
XP_CPU_FLAGS=(
    -O2
    -std=gnu99
    -march=prescott
    -mtune=prescott
    -msse2
    -msse3
    -mno-ssse3
    -mno-sse4
    -mno-avx
    -mfpmath=sse
)

XP_WIN_DEFS=(
    -D_WIN32_WINNT=0x0501
    -DWINVER=0x0501
)

# O GCC 14+ transformou vários avisos em erros (declarações implícitas,
# conversões int/ponteiro, tipos de ponteiro incompatíveis, return errado).
# O OpenSSL 1.1.1w é anterior a isso; manter esses diagnósticos como avisos.
LEGACY_C_WARN=(
    -Wno-implicit-function-declaration
    -Wno-implicit-int
    -Wno-int-conversion
    -Wno-incompatible-pointer-types
    -Wno-return-mismatch
)

XP_LDFLAGS=(
    -Wl,--major-os-version,5,--minor-os-version,1
    -Wl,--major-subsystem-version,5,--minor-subsystem-version,1
)

CFLAGS="${XP_CPU_FLAGS[*]} ${XP_WIN_DEFS[*]}"
CPPFLAGS="${XP_WIN_DEFS[*]} -I${PREFIX_UNIX}/include"
LDFLAGS="-L${PREFIX_UNIX}/lib ${XP_LDFLAGS[*]}"
LIBS="-lws2_32 -lcrypt32 -ladvapi32 -luser32 -lgdi32"

# ---------------------------------------------------------------------------
# Auxiliares
# ---------------------------------------------------------------------------
log() {
    printf '\n==> %s\n' "$*"
}

# download <saída> <url> [<url>...]
# Tenta cada espelho pela ordem; só aceita o ficheiro se o tarball for válido.
download() {
    local output="$1"
    shift

    for url in "$@"; do
        log "Download ${url}"
        rm -f "${output}"
        if curl -fL --retry 3 --retry-delay 2 --connect-timeout 20 \
                -sS -o "${output}" "${url}"; then
            if tar -tzf "${output}" >/dev/null 2>&1; then
                return 0
            fi
            log "Tarball inválido a partir de ${url}; a tentar o espelho seguinte"
        else
            log "Falha no download a partir de ${url}; a tentar o espelho seguinte"
        fi
    done

    echo "ERRO: não foi possível obter ${output}" >&2
    return 1
}

deps_cached() {
    [ -f "${PREFIX_UNIX}/lib/libz.a" ] &&
        [ -f "${PREFIX_UNIX}/lib/libssl.a" ] &&
        [ -f "${PREFIX_UNIX}/lib/libcrypto.a" ] &&
        [ -f "${PREFIX_UNIX}/lib/libcurl.a" ] &&
        [ -f "${PREFIX_UNIX}/include/zlib.h" ] &&
        [ -f "${PREFIX_UNIX}/include/openssl/ssl.h" ] &&
        [ -f "${PREFIX_UNIX}/include/curl/curl.h" ]
}

# ---------------------------------------------------------------------------
# zlib 1.3.1
# ---------------------------------------------------------------------------
build_zlib() {
    log "zlib ${ZLIB_VERSION}"
    download "${BUILD_ROOT}/zlib.tar.gz" \
        "https://zlib.net/zlib-${ZLIB_VERSION}.tar.gz" \
        "https://zlib.net/fossils/zlib-${ZLIB_VERSION}.tar.gz" \
        "https://github.com/madler/zlib/releases/download/v${ZLIB_VERSION}/zlib-${ZLIB_VERSION}.tar.gz"
    rm -rf "${BUILD_ROOT}/zlib-${ZLIB_VERSION}"
    tar -xzf "${BUILD_ROOT}/zlib.tar.gz" -C "${BUILD_ROOT}"

    (
        cd "${BUILD_ROOT}/zlib-${ZLIB_VERSION}"
        make -j"${JOBS}" -f win32/Makefile.gcc \
            CC="${CC}" \
            AR="${AR}" \
            RANLIB="${RANLIB}" \
            CFLAGS="${CFLAGS}" \
            SHARED_MODE=0 \
            libz.a
        cp -f zlib.h zconf.h "${PREFIX_UNIX}/include/"
        cp -f libz.a "${PREFIX_UNIX}/lib/"
    )
}

# ---------------------------------------------------------------------------
# OpenSSL 1.1.1w
#
# no-asm evita o NASM; no-shared/no-dso/no-engine/no-capieng mantêm a
# biblioteca totalmente estática e sem carregamento de engines.  no-zlib evita
# que o OpenSSL apanhe a zlib do MSYS2; o curl liga explicitamente à nossa.
#
# --cross-compile-prefix=i686-w64-mingw32- funciona tanto no MINGW32 (onde gcc
# é esse binário) como em Linux (pacote gcc-mingw-w64-i686).
# ---------------------------------------------------------------------------
build_openssl() {
    log "OpenSSL ${OPENSSL_VERSION}"
    download "${BUILD_ROOT}/openssl.tar.gz" \
        "https://github.com/openssl/openssl/releases/download/OpenSSL_${OPENSSL_VERSION//./_}/openssl-${OPENSSL_VERSION}.tar.gz" \
        "https://www.openssl.org/source/old/1.1.1/openssl-${OPENSSL_VERSION}.tar.gz"
    rm -rf "${BUILD_ROOT}/openssl-${OPENSSL_VERSION}"
    tar -xzf "${BUILD_ROOT}/openssl.tar.gz" -C "${BUILD_ROOT}"

    (
        cd "${BUILD_ROOT}/openssl-${OPENSSL_VERSION}"
        perl Configure mingw \
            no-shared \
            no-tests \
            no-asm \
            no-dso \
            no-engine \
            no-capieng \
            no-zlib \
            --cross-compile-prefix="${HOST}-" \
            --prefix="${PREFIX_UNIX}" \
            --openssldir="${PREFIX_UNIX}/ssl" \
            "${XP_CPU_FLAGS[@]}" \
            "${XP_WIN_DEFS[@]}" \
            "${LEGACY_C_WARN[@]}" \
            -fcommon
        make -j"${JOBS}" build_libs
        make install_dev
    )
}

# ---------------------------------------------------------------------------
# libcurl 8.11.0
#
# Os ac_cv_func_* são a parte importante: impedem o configure de usar poll(),
# WSAPoll(), inet_pton(), inet_ntop() e if_nametoindex(), nenhum dos quais
# existe no Windows XP.  O curl passa a usar as implementações portáveis
# próprias e select().  --disable-threaded-resolver evita uma dependência de
# libwinpthread; --disable-sspi/--disable-ntlm evitam secur32.
# ---------------------------------------------------------------------------
build_curl() {
    log "libcurl ${CURL_VERSION}"
    download "${BUILD_ROOT}/curl.tar.gz" \
        "https://curl.se/download/curl-${CURL_VERSION}.tar.gz" \
        "https://github.com/curl/curl/releases/download/curl-${CURL_VERSION//./_}/curl-${CURL_VERSION}.tar.gz"
    rm -rf "${BUILD_ROOT}/curl-${CURL_VERSION}"
    tar -xzf "${BUILD_ROOT}/curl.tar.gz" -C "${BUILD_ROOT}"

    (
        cd "${BUILD_ROOT}/curl-${CURL_VERSION}"

        export ac_cv_func_poll=no
        export ac_cv_func_WSAPoll=no
        export ac_cv_func_inet_pton=no
        export ac_cv_func_inet_ntop=no
        export ac_cv_func_if_nametoindex=no

        ./configure \
            --host="${HOST}" \
            --prefix="${PREFIX_UNIX}" \
            --disable-shared \
            --enable-static \
            --enable-http \
            --enable-ipv6 \
            --disable-ftp \
            --disable-file \
            --disable-ldap \
            --disable-ldaps \
            --disable-rtsp \
            --disable-dict \
            --disable-telnet \
            --disable-tftp \
            --disable-pop3 \
            --disable-imap \
            --disable-smb \
            --disable-smtp \
            --disable-gopher \
            --disable-mqtt \
            --disable-docs \
            --disable-manual \
            --disable-ntlm \
            --disable-sspi \
            --disable-threaded-resolver \
            --disable-websockets \
            --disable-doh \
            --disable-alt-svc \
            --disable-hsts \
            --without-libpsl \
            --without-libidn2 \
            --without-nghttp2 \
            --without-brotli \
            --without-zstd \
            --without-schannel \
            --without-ca-bundle \
            --without-ca-path \
            --with-openssl="${PREFIX_UNIX}" \
            --with-zlib="${PREFIX_UNIX}" \
            CC="${CC}" \
            CFLAGS="${CFLAGS} -DCURL_STATICLIB" \
            CPPFLAGS="${CPPFLAGS} -DCURL_STATICLIB" \
            LDFLAGS="${LDFLAGS}" \
            LIBS="${LIBS}"

        # O configure do curl 8.11 acrescenta -lbcrypt mesmo com
        # _WIN32_WINNT < 0x0600.  bcrypt.dll é Vista+; remover dos makefiles
        # gerados para nunca aparecer na tabela de importação da AuroraTls.dll.
        sed -i 's/-lbcrypt//g' Makefile lib/Makefile

        make -C lib -j"${JOBS}"
        make -C lib install
        make -C include install
    )
}

# ---------------------------------------------------------------------------
# AuroraTls.dll
# ---------------------------------------------------------------------------
build_aurora_tls() {
    log "AuroraTls.dll (i686, Prescott, PE 5.01)"
    "${CC}" -shared \
        "${SCRIPT_DIR}/aurora_tls.c" \
        -o "${OUT_DIR}/AuroraTls.dll" \
        "${XP_CPU_FLAGS[@]}" \
        "${XP_WIN_DEFS[@]}" \
        -DCURL_STATICLIB \
        -I"${PREFIX_UNIX}/include" \
        -L"${PREFIX_UNIX}/lib" \
        -static-libgcc \
        -Wl,-Bstatic -lcurl -lssl -lcrypto -lz \
        -Wl,-Bdynamic -lws2_32 -lcrypt32 -ladvapi32 -luser32 -lgdi32 \
        -Wl,--kill-at \
        "${XP_LDFLAGS[@]}" \
        -s

    if command -v "${HOST}-objdump" >/dev/null 2>&1; then
        log "DLLs importadas pela AuroraTls.dll"
        "${HOST}-objdump" -p "${OUT_DIR}/AuroraTls.dll" | grep 'DLL Name' || true
    fi
}

# ---------------------------------------------------------------------------
# Bundle CA oficial da Mozilla via curl.se
# ---------------------------------------------------------------------------
download_cacert() {
    log "cacert.pem oficial (curl.se)"
    download_plain "${OUT_DIR}/cacert.pem" "https://curl.se/ca/cacert.pem"
    if ! grep -q "BEGIN CERTIFICATE" "${OUT_DIR}/cacert.pem"; then
        echo "ERRO: cacert.pem inválido." >&2
        exit 1
    fi
}

# download_plain <saída> <url> [<url>...] (ficheiros que não são tarballs)
download_plain() {
    local output="$1"
    shift

    for url in "$@"; do
        log "Download ${url}"
        rm -f "${output}"
        if curl -fL --retry 3 --retry-delay 2 --connect-timeout 20 \
                -sS -o "${output}" "${url}"; then
            return 0
        fi
        log "Falha no download a partir de ${url}; a tentar o espelho seguinte"
    done

    echo "ERRO: não foi possível obter ${output}" >&2
    return 1
}

# ---------------------------------------------------------------------------
# Principal
#
# Todo o output passa por tee para build-tls.log e, em caso de erro, a cauda do
# log é emitida como anotação ::error:: do GitHub Actions (visível em
# Actions > Summary > Annotations) - evita ter de abrir o log completo.
# ---------------------------------------------------------------------------
main() {
    mkdir -p "${PREFIX_UNIX}/include" \
             "${PREFIX_UNIX}/lib" \
             "${BUILD_ROOT}" \
             "${OUT_DIR}"

    if deps_cached; then
        log "Dependências estáticas já presentes em ${DEPS_PREFIX} (cache)"
    else
        log "A compilar dependências estáticas em ${DEPS_PREFIX}"
        build_zlib
        build_openssl
        build_curl
    fi

    build_aurora_tls
    download_cacert

    log "Concluído"
    echo "  AuroraTls.dll: ${OUT_DIR}/AuroraTls.dll"
    echo "  cacert.pem:    ${OUT_DIR}/cacert.pem"
}

on_error() {
    local status=$?
    local command_text="${BASH_COMMAND//$'\n'/ }"
    printf '::error title=build-tls.sh falhou::%s:%s (exit %s): %s\n' \
        "${BASH_SOURCE[0]}" "${BASH_LINENO[0]:-0}" "${status}" "${command_text:0:400}"
}

set -E
trap on_error ERR

mkdir -p "${BUILD_ROOT}"
LOG_FILE="${BUILD_ROOT}/build-tls.log"
exec > >(tee "${LOG_FILE}") 2>&1

on_exit() {
    local status=$?
    local line
    if [ "${status}" -ne 0 ]; then
        sleep 2
        # Últimas 8 linhas do log, uma anotação por linha (limite: 10 por step).
        tail -n 8 "${LOG_FILE}" | while IFS= read -r line; do
            printf '::error title=build-tls.sh (exit %s)::%s\n' "${status}" "${line:0:1000}"
        done
    fi
}
trap on_exit EXIT

main
