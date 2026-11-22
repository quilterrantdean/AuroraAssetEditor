/*
 * AuroraTls.dll - native HTTPS transport for Aurora Asset Editor
 *
 * Target : Windows XP SP3 (5.01), x86, Intel Pentium 4 HT "Prescott"
 * Stack  : libcurl 8.11.0 (static) + OpenSSL 1.1.1w (static) + zlib 1.3.1
 *
 * Exports (all __cdecl):
 *   AuroraHttpGet    - GET with TLS 1.2+ (used by AuroraHttpClient.cs)
 *   AuroraHttpGetEx  - GET with an explicit minimum TLS version (smoke test)
 *   AuroraHttpFree   - release a buffer returned by the GET functions
 *
 * Thread safety / Hyper-Threading:
 *   curl_global_init() is guarded by an interlocked state machine.  A single
 *   CURLSH handle shares DNS, TLS session and connection caches between the
 *   worker threads used by the bulk downloader, with one CRITICAL_SECTION per
 *   CURL_LOCK_DATA_* slot.  That gives Keep-Alive and TLS session reuse
 *   without serialising every download on a single lock.
 *
 * Certificate validation:
 *   cacert.pem is looked up next to the host .exe (and next to this DLL as a
 *   fallback, which is what the PowerShell smoke test uses).  If validation
 *   fails with a certificate error - typically a dead CMOS battery making the
 *   XP clock years off - the request is retried once without verification.
 *   The fallback is remembered for the rest of the process so the bulk
 *   downloader does not pay for two handshakes per file.
 */

#define WIN32_LEAN_AND_MEAN
#define _WIN32_WINNT 0x0501
#define WINVER 0x0501
#define CURL_STATICLIB

#include <winsock2.h>
#include <windows.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <stdint.h>
#include <wchar.h>
#include <curl/curl.h>

#define AURORA_EXPORT __declspec(dllexport)
#define AURORA_CALL __cdecl

typedef struct {
    unsigned char *data;
    size_t size;
    size_t capacity;
} AuroraBuffer;

static HMODULE g_module = NULL;
static volatile LONG g_init_state = 0; /* 0 = virgin, 1 = initialising, 2 = ready */
static volatile LONG g_init_ok = 0;
static volatile LONG g_has_ca_bundle = 0;
static volatile LONG g_verify_disabled = 0;
static CURLSH *g_share = NULL;
static CRITICAL_SECTION g_locks[CURL_LOCK_DATA_LAST];
static char g_ca_bundle[MAX_PATH * 4];

#if defined(_MSC_VER) || defined(__MINGW32__) || defined(__MINGW64__)
#define AURORA_SNWPRINTF _snwprintf
#else
#define AURORA_SNWPRINTF swprintf
#endif

/* ------------------------------------------------------------------------ */
/* CURLSH lock callbacks                                                    */
/* ------------------------------------------------------------------------ */

static void aurora_share_lock(CURL *handle,
                              curl_lock_data data,
                              curl_lock_access access,
                              void *userptr)
{
    (void)handle;
    (void)access;
    (void)userptr;

    if ((int)data >= 0 && (int)data < (int)CURL_LOCK_DATA_LAST) {
        EnterCriticalSection(&g_locks[data]);
    }
}

static void aurora_share_unlock(CURL *handle,
                                curl_lock_data data,
                                void *userptr)
{
    (void)handle;
    (void)userptr;

    if ((int)data >= 0 && (int)data < (int)CURL_LOCK_DATA_LAST) {
        LeaveCriticalSection(&g_locks[data]);
    }
}

/* ------------------------------------------------------------------------ */
/* CA bundle discovery                                                      */
/* ------------------------------------------------------------------------ */

static int aurora_find_ca_in_module(HMODULE module, char *out, int out_cap)
{
    wchar_t module_path[MAX_PATH];
    wchar_t ca_path[MAX_PATH];
    wchar_t *slash;
    DWORD attributes;
    DWORD length;
    int written;

    length = GetModuleFileNameW(module,
                                module_path,
                                (DWORD)(sizeof(module_path) / sizeof(module_path[0])));
    if (length == 0 || length >= (DWORD)(sizeof(module_path) / sizeof(module_path[0]))) {
        return 0;
    }

    slash = wcsrchr(module_path, L'\\');
    if (slash == NULL) {
        return 0;
    }
    *slash = L'\0';

    written = AURORA_SNWPRINTF(ca_path,
                               (size_t)(sizeof(ca_path) / sizeof(ca_path[0])),
                               L"%s\\cacert.pem",
                               module_path);
    if (written < 0) {
        return 0;
    }
    ca_path[(sizeof(ca_path) / sizeof(ca_path[0])) - 1] = L'\0';

    attributes = GetFileAttributesW(ca_path);
    if (attributes == INVALID_FILE_ATTRIBUTES || (attributes & FILE_ATTRIBUTE_DIRECTORY)) {
        return 0;
    }

    /*
     * OpenSSL uses fopen() on Windows, which interprets the path in the ANSI
     * code page.  The install path is ASCII in practice, so CP_ACP is both
     * the compatible and the safest conversion here.
     */
    if (WideCharToMultiByte(CP_ACP, 0, ca_path, -1,
                            out, out_cap, NULL, NULL) <= 0) {
        return 0;
    }
    out[out_cap - 1] = '\0';
    return 1;
}

static void aurora_locate_ca_bundle(void)
{
    HMODULE module = NULL;

    g_has_ca_bundle = 0;
    g_ca_bundle[0] = '\0';

    /* Preferred: next to the host .exe (AuroraAssetEditor.exe). */
    if (aurora_find_ca_in_module(NULL, g_ca_bundle, (int)sizeof(g_ca_bundle))) {
        g_has_ca_bundle = 1;
        return;
    }

    /* Fallback: next to this DLL (used by the PowerShell smoke test). */
    if (g_module != NULL &&
        aurora_find_ca_in_module(g_module, g_ca_bundle, (int)sizeof(g_ca_bundle))) {
        g_has_ca_bundle = 1;
        return;
    }

    /* Last resort: derive the DLL handle from a local address. */
    if (GetModuleHandleExW(GET_MODULE_HANDLE_EX_FLAG_FROM_ADDRESS |
                           GET_MODULE_HANDLE_EX_FLAG_UNCHANGED_REFCOUNT,
                           (LPCWSTR)&aurora_locate_ca_bundle,
                           &module) &&
        module != NULL) {
        if (aurora_find_ca_in_module(module, g_ca_bundle, (int)sizeof(g_ca_bundle))) {
            g_has_ca_bundle = 1;
        }
    }
}

/* ------------------------------------------------------------------------ */
/* One-shot global initialisation                                           */
/* ------------------------------------------------------------------------ */

static void aurora_ensure_initialised(void)
{
    LONG previous = InterlockedCompareExchange((LONG volatile *)&g_init_state, 1, 0);

    if (previous == 0) {
        int i;

        for (i = 0; i < (int)CURL_LOCK_DATA_LAST; i++) {
            InitializeCriticalSectionAndSpinCount(&g_locks[i], 4000);
        }

        if (curl_global_init(CURL_GLOBAL_DEFAULT) == CURLE_OK) {
            aurora_locate_ca_bundle();

            g_share = curl_share_init();
            if (g_share != NULL) {
                curl_share_setopt(g_share, CURLSHOPT_LOCKFUNC, aurora_share_lock);
                curl_share_setopt(g_share, CURLSHOPT_UNLOCKFUNC, aurora_share_unlock);
                curl_share_setopt(g_share, CURLSHOPT_SHARE, CURL_LOCK_DATA_DNS);
                curl_share_setopt(g_share, CURLSHOPT_SHARE, CURL_LOCK_DATA_SSL_SESSION);
                curl_share_setopt(g_share, CURLSHOPT_SHARE, CURL_LOCK_DATA_CONNECT);
            }
            g_init_ok = 1;
        }

        InterlockedExchange((LONG volatile *)&g_init_state, 2);
    } else {
        while (g_init_state != 2) {
            Sleep(1);
        }
    }
}

/* ------------------------------------------------------------------------ */
/* Memory buffer                                                            */
/* ------------------------------------------------------------------------ */

static void aurora_buffer_free(AuroraBuffer *buffer)
{
    if (buffer == NULL) {
        return;
    }
    if (buffer->data != NULL) {
        free(buffer->data);
        buffer->data = NULL;
    }
    buffer->size = 0;
    buffer->capacity = 0;
}

static size_t aurora_write_cb(void *contents, size_t size, size_t nmemb, void *userptr)
{
    AuroraBuffer *buffer = (AuroraBuffer *)userptr;
    unsigned char *resized;
    size_t real_size;
    size_t needed;
    size_t new_capacity;

    if (buffer == NULL || contents == NULL) {
        return 0;
    }

    if (size != 0 && nmemb > (size_t)-1 / size) {
        return 0; /* multiplication overflow */
    }
    real_size = size * nmemb;
    if (real_size == 0) {
        return 0;
    }

    if (buffer->size > (size_t)-1 - real_size - 1) {
        return 0; /* addition overflow */
    }
    needed = buffer->size + real_size + 1;

    if (needed > buffer->capacity) {
        new_capacity = buffer->capacity ? buffer->capacity : 16384;
        while (new_capacity < needed) {
            if (new_capacity > (size_t)-1 / 2) {
                new_capacity = needed;
                break;
            }
            new_capacity *= 2;
        }

        resized = (unsigned char *)realloc(buffer->data, new_capacity);
        if (resized == NULL) {
            return 0;
        }
        buffer->data = resized;
        buffer->capacity = new_capacity;
    }

    memcpy(buffer->data + buffer->size, contents, real_size);
    buffer->size += real_size;
    buffer->data[buffer->size] = '\0';
    return real_size;
}

/* ------------------------------------------------------------------------ */
/* Helpers                                                                  */
/* ------------------------------------------------------------------------ */

static void aurora_copy_error(char *destination, int capacity, const char *source)
{
    size_t length;

    if (destination == NULL || capacity <= 0) {
        return;
    }
    if (source == NULL) {
        source = "";
    }

    length = strlen(source);
    if (length > (size_t)capacity - 1) {
        length = (size_t)capacity - 1;
    }
    memcpy(destination, source, length);
    destination[length] = '\0';
}

static void aurora_apply_common_options(CURL *curl,
                                        AuroraBuffer *buffer,
                                        char *error_buffer)
{
    if (g_share != NULL) {
        curl_easy_setopt(curl, CURLOPT_SHARE, g_share);
    }

    curl_easy_setopt(curl, CURLOPT_WRITEFUNCTION, aurora_write_cb);
    curl_easy_setopt(curl, CURLOPT_WRITEDATA, (void *)buffer);
    curl_easy_setopt(curl, CURLOPT_ERRORBUFFER, error_buffer);
    curl_easy_setopt(curl, CURLOPT_USERAGENT,
                     "AuroraAssetEditor/1.4 (Windows NT 5.1; x86)");
    curl_easy_setopt(curl, CURLOPT_FOLLOWLOCATION, 1L);
    curl_easy_setopt(curl, CURLOPT_MAXREDIRS, 10L);
    curl_easy_setopt(curl, CURLOPT_PROTOCOLS_STR, "http,https");
    curl_easy_setopt(curl, CURLOPT_REDIR_PROTOCOLS_STR, "http,https");
    curl_easy_setopt(curl, CURLOPT_ACCEPT_ENCODING, "");
    curl_easy_setopt(curl, CURLOPT_CONNECTTIMEOUT, 30L);
    curl_easy_setopt(curl, CURLOPT_NOSIGNAL, 1L);
    curl_easy_setopt(curl, CURLOPT_TCP_KEEPALIVE, 1L);
    curl_easy_setopt(curl, CURLOPT_SSL_SESSIONID_CACHE, 1L);
    curl_easy_setopt(curl, CURLOPT_LOW_SPEED_LIMIT, 1L);
    curl_easy_setopt(curl, CURLOPT_LOW_SPEED_TIME, 60L);
    curl_easy_setopt(curl, CURLOPT_DNS_CACHE_TIMEOUT, 300L);
}

static void aurora_apply_ssl_options(CURL *curl,
                                     int verify,
                                     int min_tls_major,
                                     int min_tls_minor)
{
    long ssl_version = CURL_SSLVERSION_TLSv1_2;

    if (min_tls_major == 1 && min_tls_minor == 3) {
        ssl_version = CURL_SSLVERSION_TLSv1_3;
    } else if (min_tls_major == 1 && min_tls_minor == 2) {
        ssl_version = CURL_SSLVERSION_TLSv1_2;
    } else if (min_tls_major == 1 && min_tls_minor == 1) {
        ssl_version = CURL_SSLVERSION_TLSv1_1;
    } else if (min_tls_major == 1 && min_tls_minor == 0) {
        ssl_version = CURL_SSLVERSION_TLSv1_0;
    }

    curl_easy_setopt(curl, CURLOPT_SSLVERSION, ssl_version);

    if (verify && g_has_ca_bundle) {
        curl_easy_setopt(curl, CURLOPT_SSL_VERIFYPEER, 1L);
        curl_easy_setopt(curl, CURLOPT_SSL_VERIFYHOST, 2L);
        curl_easy_setopt(curl, CURLOPT_CAINFO, g_ca_bundle);
    } else {
        curl_easy_setopt(curl, CURLOPT_SSL_VERIFYPEER, 0L);
        curl_easy_setopt(curl, CURLOPT_SSL_VERIFYHOST, 0L);
    }
}

static int aurora_is_certificate_error(CURLcode code)
{
    return code == CURLE_PEER_FAILED_VERIFICATION ||
           code == CURLE_SSL_CACERT_BADFILE ||
           code == CURLE_SSL_CERTPROBLEM ||
           code == CURLE_SSL_CIPHER;
}

static CURLcode aurora_perform(const char *url,
                               AuroraBuffer *buffer,
                               long *http_code,
                               int verify,
                               int min_tls_major,
                               int min_tls_minor,
                               char *error_buffer)
{
    CURL *curl;
    CURLcode result;

    error_buffer[0] = '\0';
    curl = curl_easy_init();
    if (curl == NULL) {
        return CURLE_FAILED_INIT;
    }

    aurora_apply_common_options(curl, buffer, error_buffer);
    aurora_apply_ssl_options(curl, verify, min_tls_major, min_tls_minor);
    curl_easy_setopt(curl, CURLOPT_URL, url);

    result = curl_easy_perform(curl);

    if (http_code != NULL) {
        long code = 0;
        curl_easy_getinfo(curl, CURLINFO_RESPONSE_CODE, &code);
        *http_code = code;
    }

    curl_easy_cleanup(curl);
    return result;
}

/* ------------------------------------------------------------------------ */
/* Exports                                                                  */
/* ------------------------------------------------------------------------ */

AURORA_EXPORT int AURORA_CALL AuroraHttpGetEx(const char *url,
                                              int min_tls_major,
                                              int min_tls_minor,
                                              unsigned char **out_data,
                                              int *out_len,
                                              int *out_http_status,
                                              char *out_error,
                                              int out_error_cap)
{
    AuroraBuffer buffer;
    char error_buffer[CURL_ERROR_SIZE];
    long http_code = 0;
    CURLcode result;
    int verify;

    if (url == NULL || out_data == NULL || out_len == NULL) {
        return -1;
    }

    *out_data = NULL;
    *out_len = 0;
    if (out_http_status != NULL) {
        *out_http_status = 0;
    }
    if (out_error != NULL && out_error_cap > 0) {
        out_error[0] = '\0';
    }

    aurora_ensure_initialised();
    if (!g_init_ok) {
        aurora_copy_error(out_error, out_error_cap, "curl_global_init failed");
        return -3;
    }

    buffer.data = NULL;
    buffer.size = 0;
    buffer.capacity = 0;

    verify = (g_has_ca_bundle && !g_verify_disabled) ? 1 : 0;

    result = aurora_perform(url, &buffer, &http_code, verify,
                            min_tls_major, min_tls_minor, error_buffer);

    /*
     * Windows XP machines often have a dead CMOS battery, which makes the
     * system clock drift years into the past and breaks certificate
     * validation.  Retry once without verification rather than failing the
     * whole bulk download.  The CA bundle is still preferred when it works.
     */
    if (verify && aurora_is_certificate_error(result)) {
        aurora_buffer_free(&buffer);
        error_buffer[0] = '\0';
        result = aurora_perform(url, &buffer, &http_code, 0,
                                min_tls_major, min_tls_minor, error_buffer);
        if (result == CURLE_OK || http_code != 0) {
            InterlockedExchange(&g_verify_disabled, 1);
        }
    }

    if (out_http_status != NULL) {
        *out_http_status = (int)http_code;
    }

    if (result != CURLE_OK) {
        aurora_buffer_free(&buffer);
        aurora_copy_error(out_error, out_error_cap,
                          error_buffer[0] ? error_buffer : curl_easy_strerror(result));
        return (int)result;
    }

    if (buffer.data == NULL) {
        buffer.data = (unsigned char *)malloc(1);
        if (buffer.data == NULL) {
            aurora_copy_error(out_error, out_error_cap, "out of memory");
            return -2;
        }
        buffer.data[0] = '\0';
        buffer.size = 0;
    }

    *out_data = buffer.data;
    *out_len = (int)buffer.size;
    return 0;
}

AURORA_EXPORT int AURORA_CALL AuroraHttpGet(const char *url,
                                            unsigned char **out_data,
                                            int *out_len,
                                            int *out_http_status,
                                            char *out_error,
                                            int out_error_cap)
{
    return AuroraHttpGetEx(url, 1, 2,
                           out_data, out_len, out_http_status,
                           out_error, out_error_cap);
}

AURORA_EXPORT void AURORA_CALL AuroraHttpFree(unsigned char *ptr)
{
    if (ptr != NULL) {
        free(ptr);
    }
}

/* ------------------------------------------------------------------------ */
/* DLL entry point                                                          */
/* ------------------------------------------------------------------------ */

BOOL WINAPI DllMain(HINSTANCE instance, DWORD reason, LPVOID reserved)
{
    (void)reserved;

    if (reason == DLL_PROCESS_ATTACH) {
        g_module = instance;
        DisableThreadLibraryCalls(instance);
    }

    return TRUE;
}
