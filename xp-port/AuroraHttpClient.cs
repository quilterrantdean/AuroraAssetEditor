//
// AuroraHttpClient.cs
// AuroraAssetEditor
//
// .NET 4.0 shim that replaces System.Net.WebClient with the native
// AuroraTls.dll transport (static OpenSSL 1.1.1w + libcurl 8.11.0).
//
// Why a shim instead of WebClient:
//   Windows XP SP3 only ships TLS 1.0 support in SChannel/.NET 4.0, and the
//   ServicePointManager.SecurityProtocol |= 3072 trick throws on XP.  The
//   native DLL speaks TLS 1.2 and TLS 1.3 itself, validates certificates with
//   the bundled cacert.pem, and shares DNS/TLS-session/connection caches
//   across the bulk-downloader worker threads.
//
// Compatibility notes:
//   - Targets .NET Framework 4.0 (no async, no LPUTF8Str from .NET 4.7+).
//   - URL and error buffers are marshalled as byte[] (UTF-8, NUL-terminated),
//     which works on every .NET 4.0 runtime.
//   - Implements IDisposable so existing "using (WebClient ...)" call sites
//     compile unchanged after the WebClient -> AuroraHttpClient replacement.
//

namespace AuroraAssetEditor.Classes
{
    using System;
    using System.IO;
    using System.Net;
    using System.Runtime.InteropServices;
    using System.Text;

    /// <summary>
    /// Drop-in replacement for <see cref="WebClient"/> backed by AuroraTls.dll.
    /// </summary>
    internal sealed class AuroraHttpClient : IDisposable
    {
        private const string NativeLibrary = "AuroraTls.dll";
        private const int ErrorBufferCapacity = 512;

        [DllImport(NativeLibrary, CallingConvention = CallingConvention.Cdecl)]
        private static extern int AuroraHttpGet(
            byte[] utf8Url,
            out IntPtr outData,
            out int outLength,
            out int outHttpStatus,
            byte[] outError,
            int outErrorCapacity);

        [DllImport(NativeLibrary, CallingConvention = CallingConvention.Cdecl)]
        private static extern void AuroraHttpFree(IntPtr ptr);

        public byte[] DownloadData(string address)
        {
            if (string.IsNullOrEmpty(address))
            {
                throw new ArgumentNullException("address");
            }

            return DownloadData(new Uri(address));
        }

        public byte[] DownloadData(Uri address)
        {
            if (address == null)
            {
                throw new ArgumentNullException("address");
            }

            byte[] urlBytes = Encoding.UTF8.GetBytes(address.AbsoluteUri + "\0");
            byte[] errorBytes = new byte[ErrorBufferCapacity];
            IntPtr nativeBuffer = IntPtr.Zero;
            int length;
            int httpStatus;

            try
            {
                int result = AuroraHttpGet(
                    urlBytes,
                    out nativeBuffer,
                    out length,
                    out httpStatus,
                    errorBytes,
                    errorBytes.Length);

                string error = DecodeError(errorBytes);

                if (result != 0)
                {
                    throw new WebException(
                        string.IsNullOrEmpty(error)
                            ? "AuroraTls error " + result
                            : error,
                        WebExceptionStatus.ConnectFailure);
                }

                if (httpStatus >= 400)
                {
                    throw new WebException(
                        string.IsNullOrEmpty(error)
                            ? "The remote server returned an error: (" + httpStatus + ")."
                            : error,
                        WebExceptionStatus.ProtocolError);
                }

                byte[] managed = new byte[length];
                if (length > 0 && nativeBuffer != IntPtr.Zero)
                {
                    Marshal.Copy(nativeBuffer, managed, 0, length);
                }

                return managed;
            }
            finally
            {
                if (nativeBuffer != IntPtr.Zero)
                {
                    AuroraHttpFree(nativeBuffer);
                }
            }
        }

        public string DownloadString(string address)
        {
            return DecodeUtf8(DownloadData(address));
        }

        public Stream OpenRead(string address)
        {
            return new MemoryStream(DownloadData(address), false);
        }

        private static string DecodeError(byte[] bytes)
        {
            if (bytes == null || bytes.Length == 0 || bytes[0] == 0)
            {
                return string.Empty;
            }

            int length = Array.IndexOf(bytes, (byte)0);
            if (length < 0)
            {
                length = bytes.Length;
            }

            return Encoding.UTF8.GetString(bytes, 0, length);
        }

        private static string DecodeUtf8(byte[] bytes)
        {
            if (bytes == null || bytes.Length == 0)
            {
                return string.Empty;
            }

            int offset = (bytes.Length >= 3 &&
                          bytes[0] == 0xEF &&
                          bytes[1] == 0xBB &&
                          bytes[2] == 0xBF)
                             ? 3
                             : 0;

            return Encoding.UTF8.GetString(bytes, offset, bytes.Length - offset);
        }

        public void Dispose()
        {
            // No unmanaged fields: the native buffers are freed per call.
        }
    }
}
