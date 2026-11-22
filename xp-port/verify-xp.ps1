[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$PublishDir,

    [string]$ObjdumpPath = "",

    [switch]$SkipEditBin,

    [switch]$SkipSmokeTest
)

$ErrorActionPreference = "Stop"

# Em caso de erro, emitir também uma anotação ##[error] do GitHub Actions com a
# mensagem e a posição (o log completo do passo só é visível na página Actions).
trap {
    $details = ($_ | Out-String).Trim() -replace "`r?`n", ' | '
    Write-Host "##[error]$details"
    break
}

function Write-Step {
    param([string]$Message)
    Write-Host "==> $Message"
}

function Resolve-FullPath {
    param([string]$Path)

    if (-not (Test-Path -LiteralPath $Path)) {
        throw "Caminho inexistente: $Path"
    }

    return (Resolve-Path -LiteralPath $Path).Path
}

function Find-Objdump {
    # O explicito (-ObjdumpPath, ficheiro ou diretório) tem prioridade; depois
    # o root devolvido pelo msys2/setup-msys2 (MSYS2_LOCATION) e as localizações
    # habituais.  O -ObjdumpPath inexistente não aborta logo: cai para a busca.
    $candidates = @()
    if (-not [string]::IsNullOrWhiteSpace($ObjdumpPath)) {
        $candidates += $ObjdumpPath
        $candidates += (Join-Path $ObjdumpPath "objdump.exe")
    }

    $roots = @()
    if (-not [string]::IsNullOrWhiteSpace($env:MSYS2_LOCATION)) {
        $roots += $env:MSYS2_LOCATION
    }
    $roots += @("C:\msys64", "D:\msys64")

    foreach ($root in $roots) {
        $candidates += (Join-Path $root "mingw32\bin\objdump.exe")
        $candidates += (Join-Path $root "usr\bin\objdump.exe")
    }

    foreach ($candidate in $candidates) {
        if (Test-Path -LiteralPath $candidate -PathType Leaf) {
            return (Resolve-Path -LiteralPath $candidate).Path
        }
    }

    $command = Get-Command objdump.exe -ErrorAction SilentlyContinue
    if ($command) {
        return $command.Source
    }

    throw "objdump.exe não encontrado. Instala o MSYS2/MINGW32, define MSYS2_LOCATION ou passa -ObjdumpPath. Procurei em: $($candidates -join ', ')"
}

function Find-EditBin {
    $vswhere = Join-Path ${env:ProgramFiles(x86)} "Microsoft Visual Studio\Installer\vswhere.exe"
    if (-not (Test-Path -LiteralPath $vswhere)) {
        throw "vswhere.exe não encontrado: $vswhere"
    }

    $vsPath = & $vswhere -latest -products * `
        -requires Microsoft.VisualStudio.Component.VC.Tools.x86.x64 `
        -property installationPath
    if ([string]::IsNullOrWhiteSpace($vsPath)) {
        throw "Ferramentas C++ do Visual Studio não encontradas (componente VC.Tools.x86.x64)."
    }

    $msvcRoot = Join-Path $vsPath "VC\Tools\MSVC"
    $editbins = @(Get-ChildItem -LiteralPath $msvcRoot -Recurse -Filter "editbin.exe" `
            -ErrorAction SilentlyContinue)
    if ($editbins.Count -eq 0) {
        throw "editbin.exe não encontrado em $msvcRoot"
    }

    $preferred = $editbins |
        Where-Object { $_.FullName -match "Hostx64\\x86" } |
        Select-Object -First 1
    if (-not $preferred) {
        $preferred = $editbins |
            Where-Object { $_.FullName -match "Hostx86\\x86" } |
            Select-Object -First 1
    }
    if (-not $preferred) {
        $preferred = $editbins | Select-Object -First 1
    }

    return $preferred.FullName
}

function Find-CorFlags {
    $roots = @(
        (Join-Path ${env:ProgramFiles(x86)} "Microsoft SDKs\Windows"),
        (Join-Path ${env:ProgramFiles(x86)} "Windows Kits"),
        (Join-Path ${env:ProgramFiles(x86)} "Microsoft Visual Studio"),
        (Join-Path ${env:ProgramFiles} "Microsoft Visual Studio")
    )

    foreach ($root in $roots) {
        if (Test-Path -LiteralPath $root) {
            $found = Get-ChildItem -LiteralPath $root -Recurse -Filter "CorFlags.exe" `
                -ErrorAction SilentlyContinue |
                Sort-Object FullName -Descending |
                Select-Object -First 1
            if ($found) {
                return $found.FullName
            }
        }
    }

    throw "CorFlags.exe não encontrado. Instala o Windows SDK / .NET Framework SDK."
}

# ---------------------------------------------------------------------------
# Resolver entradas
# ---------------------------------------------------------------------------
$PublishDir = Resolve-FullPath $PublishDir
$objdump = Find-Objdump

$exePath = Join-Path $PublishDir "AuroraAssetEditor.exe"
if (-not (Test-Path -LiteralPath $exePath)) {
    throw "AuroraAssetEditor.exe não encontrado em $PublishDir"
}
$exePath = (Resolve-Path -LiteralPath $exePath).Path

# ---------------------------------------------------------------------------
# editbin + CorFlags: tornar o EXE gerido carregável no XP SP3
# ---------------------------------------------------------------------------
if (-not $SkipEditBin) {
    $editbin = Find-EditBin
    $corflags = Find-CorFlags

    Write-Step "CorFlags /32BITREQ+ em $exePath"
    & $corflags /32BITREQ+ /nologo $exePath
    if ($LASTEXITCODE -ne 0) {
        throw "CorFlags falhou (exit $LASTEXITCODE)"
    }

    Write-Step "editbin /SUBSYSTEM:WINDOWS,5.01 /OSVERSION:5.1 /TSAWARE"
    # Os argumentos com vírgula têm de ficar entre aspas: em PowerShell uma
    # vírgula nua cria um array.
    & $editbin /NOLOGO '/SUBSYSTEM:WINDOWS,5.01' '/OSVERSION:5.1' /TSAWARE $exePath
    if ($LASTEXITCODE -ne 0) {
        throw "editbin falhou (exit $LASTEXITCODE)"
    }

    $corflagsOutput = (& $corflags $exePath | Out-String)
    if ($corflagsOutput -notmatch "32BITREQ") {
        throw "CorFlags não reportou 32BITREQ para $exePath"
    }
}

# ---------------------------------------------------------------------------
# Auditar todos os .exe/.dll com o objdump
# ---------------------------------------------------------------------------
Write-Step "A auditar binários em $PublishDir com $objdump"

$binaries = @(Get-ChildItem -LiteralPath $PublishDir -Recurse -File |
    Where-Object { $_.Extension -in @(".exe", ".dll") })
if ($binaries.Count -eq 0) {
    throw "Nenhum .exe/.dll encontrado em $PublishDir"
}

# Allowlist de imports: tudo tem de vir do conjunto de DLLs de sistema do XP SP3.
$allowedImports = @(
    "KERNEL32.dll",
    "USER32.dll",
    "ADVAPI32.dll",
    "WS2_32.dll",
    "CRYPT32.dll",
    "GDI32.dll",
    "SHELL32.dll",
    "OLE32.dll",
    "OLEAUT32.dll",
    "MSVCRT.dll",
    "MSVCR100.dll",
    "MSCOREE.dll",
    "NTDLL.dll",
    "SHLWAPI.dll",
    "WINMM.dll",
    "VERSION.dll"
)

# APIs introduzidas depois do XP.  Importar qualquer uma delas impede o
# binário de carregar no XP (ou força uma DLL Vista+ como o bcrypt.dll).
$vistaApis = @(
    "AcquireSRWLockExclusive",
    "AcquireSRWLockShared",
    "ReleaseSRWLockExclusive",
    "ReleaseSRWLockShared",
    "InitializeSRWLock",
    "InitializeConditionVariable",
    "SleepConditionVariableCS",
    "WakeConditionVariable",
    "WakeAllConditionVariable",
    "InitOnceExecuteOnce",
    "InitOnceInitialize",
    "GetTickCount64",
    "GetSystemTimePreciseAsFileTime",
    "QueryUnbiasedInterruptTime",
    "InitializeCriticalSectionEx",
    "SetFileInformationByHandle",
    "GetFinalPathNameByHandleW",
    "CompareStringEx",
    "LCMapStringEx",
    "GetLocaleInfoEx",
    "GetUserDefaultLocaleName",
    "IsValidLocaleName",
    "ResolveLocaleName",
    "BCryptGenRandom",
    "BCryptOpenAlgorithmProvider",
    "WSAPoll",
    "inet_pton",
    "inet_ntop",
    "if_nametoindex",
    "GetAddrinfoEx",
    "GetAddrinfoExW",
    "CancelIoEx",
    "CancelSynchronousIo",
    "GetOverlappedResultEx",
    "CreateEventExW",
    "CreateMutexExW",
    "CreateSemaphoreExW",
    "CreateThreadpoolWork",
    "SubmitThreadpoolWork",
    "WaitForThreadpoolWorkCallbacks",
    "CloseThreadpoolWork",
    "TrySubmitThreadpoolCallback",
    "CreateThreadpoolTimer",
    "SetThreadpoolTimer",
    "RaiseFailFastException",
    "GetProductInfo",
    "SetThreadDescription",
    "GetThreadDescription",
    "CreateFile2",
    "CopyFile2",
    "GetTempPath2W",
    "AddDllDirectory",
    "SetDefaultDllDirectories",
    "SetThreadErrorMode",
    "GetThreadErrorMode",
    "GetErrorMode",
    "SetProcessDpiAwareness",
    "GetDpiForMonitor",
    "GetDpiForWindow",
    "SetProcessDpiAwarenessContext",
    "SetThreadDpiAwarenessContext",
    "GetSystemMetricsForDpi",
    "AdjustWindowRectExForDpi",
    "RoInitialize",
    "RoUninitialize",
    "RoGetActivationFactory",
    "WindowsCreateString",
    "WindowsDeleteString",
    "GetCurrentPackageId",
    "GetCurrentPackageFullName",
    "GetPackageFamilyName",
    "PackageIdFromFullName",
    "CompareObjectHandles",
    "WaitOnAddress",
    "WakeByAddressSingle",
    "WakeByAddressAll",
    "GetNumaHighestNodeNumber",
    "GetNumaNodeProcessorMask",
    "VirtualAllocExNuma",
    "GetThreadGroupAffinity",
    "SetThreadGroupAffinity",
    "GetActiveProcessorCount",
    "GetActiveProcessorGroupCount",
    "GetMaximumProcessorGroupCount",
    "GetMaximumProcessorCount",
    "SetThreadIdealProcessorEx",
    "GetThreadIdealProcessorEx",
    "SetThreadInformation",
    "GetThreadInformation",
    "SetProcessInformation",
    "GetProcessInformation",
    "CreateRemoteThreadEx",
    "UpdateProcThreadAttribute",
    "InitializeProcThreadAttributeList",
    "DeleteProcThreadAttributeList",
    "QueryUnbiasedInterruptTimePrecise"
)

# Só as imagens nativas / mixed-mode são desassembladas.  Assemblies geridos
# puros têm metadados em .text que podem descodificar como instruções
# arbitrárias e gerar falsos positivos.
$nativeAudit = @(
    "AuroraTls.dll",
    "AuroraAsset.dll",
    "msvcr100.dll",
    "System.Data.SQLite.dll",
    "SQLite.Interop.dll"
)

# Instruções posteriores ao Prescott, ancoradas na coluna do mnemonic do
# objdump (endereço: bytes  mnemonic operandos) para não apanhar nomes de
# símbolos ou operandos.  SSSE3 (pshufb, phadd*, pmulhrsw, …), SSE4.1/4.2
# (pblend*, pextr*, pmov*, popcnt, crc32, …), AES-NI, CLMUL, ABM (lzcnt) e
# tudo o que seja VEX/AVX (mnemonics começados por "v") são rejeitados.
$postPrescott = '(?m)^\s*[0-9a-f]+:\s+((?:[0-9a-f]{2} )+)\s+(pshufb|palignr|phaddd|phaddsw|phsubd|phsubsw|phsubw|pmaddubsw|pmulhrsw|psignb|psignw|psignd|pblendvb|pblendw|ptest|packusdw|pcmpeqq|pinsr[bdq]|pextr[bdq]|extractps|insertps|movntdqa|mpsadbw|phminposuw|pmov[sz][a-z]+|pmulld|pmuldq|roundss|roundsd|pmax[su][bdq]|pmin[su][bdq]|dpps|dppd|popcnt|lzcnt|aesenc|aesdeclast|aesimc|aeskeygenassist|pclmulqdq|crc32|movbe|xsave|xrstor|v(?!er[rw]\b)[a-z0-9]+)\b'

foreach ($binary in $binaries) {
    $file = $binary.FullName
    $name = $binary.Name
    $header = (& $objdump -p $file 2>$null | Out-String)
    if ($LASTEXITCODE -ne 0) {
        throw "objdump falhou ao ler $name (exit $LASTEXITCODE)"
    }

    if ($header -notmatch "file format pei-i386") {
        throw "$name não é um binário 32-bit (pei-i386)."
    }

    $majorMatch = [regex]::Match($header, "MajorSubsystemVersion\s+(\d+)")
    $minorMatch = [regex]::Match($header, "MinorSubsystemVersion\s+(\d+)")
    if (-not $majorMatch.Success) {
        throw "$name não expõe MajorSubsystemVersion no cabeçalho PE."
    }
    $majorSubsystem = [int]$majorMatch.Groups[1].Value
    $minorSubsystem = if ($minorMatch.Success) { [int]$minorMatch.Groups[1].Value } else { 0 }
    if ($majorSubsystem -gt 5 -or ($majorSubsystem -eq 5 -and $minorSubsystem -gt 1)) {
        throw "$name exige Subsystem $majorSubsystem.$minorSubsystem (> 5.01, incompatível com Windows XP)."
    }

    $importNames = @([regex]::Matches($header, "DLL Name:\s*([^\r\n]+)") |
        ForEach-Object { $_.Groups[1].Value.Trim() })

    if ($importNames.Count -eq 0) {
        throw "$name não importa nenhuma DLL (cabeçalho PE inesperado?)."
    }

    foreach ($import in $importNames) {
        if ($import -match "^(api-ms-win-|bcrypt\.)") {
            throw "$name depende de uma DLL inexistente no Windows XP: $import"
        }
        $matched = $false
        foreach ($allowed in $allowedImports) {
            if ([string]::Equals($allowed, $import, [System.StringComparison]::OrdinalIgnoreCase)) {
                $matched = $true
                break
            }
        }
        if (-not $matched) {
            throw "$name importa uma DLL não permitida no Windows XP: $import"
        }
    }

    foreach ($api in $vistaApis) {
        if ($header -match ("\b" + [regex]::Escape($api) + "\b")) {
            throw "$name importa uma API exclusiva do Windows Vista+: $api"
        }
    }

    if ($nativeAudit -contains $name) {
        # A desassemblagem de uma DLL estática de vários MB produz dezenas de
        # MB de texto: passar por um ficheiro temporário em vez de manter tudo
        # em memória como array de linhas do PowerShell.
        $disasmFile = Join-Path ([System.IO.Path]::GetTempPath()) ("aurora-audit-" + $name + ".asm")
        try {
            & $objdump -d -M intel $file 2>$null | Out-File -FilePath $disasmFile -Encoding ascii
            $instructionMatch = Select-String -LiteralPath $disasmFile -Pattern $postPrescott | Select-Object -First 1
            if ($instructionMatch) {
                $mnemonic = $instructionMatch.Matches[0].Groups[2].Value
                throw "$name contém instruções de CPU posteriores ao Pentium 4 Prescott: $mnemonic"
            }
        }
        finally {
            Remove-Item -LiteralPath $disasmFile -Force -ErrorAction SilentlyContinue
        }
    }

    Write-Host "OK [WinXP SP3 5.01 | i386 | P4 Prescott]: $name ($($importNames -join ', '))"
}

# ---------------------------------------------------------------------------
# Sanidade: tabela de exportação da AuroraTls.dll
# ---------------------------------------------------------------------------
$tlsPath = Join-Path $PublishDir "AuroraTls.dll"
if (-not (Test-Path -LiteralPath $tlsPath)) {
    throw "AuroraTls.dll em falta em $PublishDir"
}
$tlsPath = (Resolve-Path -LiteralPath $tlsPath).Path

$tlsHeader = (& $objdump -p $tlsPath 2>$null | Out-String)
if ($LASTEXITCODE -ne 0) {
    throw "objdump falhou ao ler AuroraTls.dll (exit $LASTEXITCODE)"
}
foreach ($export in @("AuroraHttpGet", "AuroraHttpGetEx", "AuroraHttpFree")) {
    if ($tlsHeader -notmatch "\b$export\b") {
        throw "AuroraTls.dll não exporta $export"
    }
}

# ---------------------------------------------------------------------------
# Smoke-test real: PowerShell 32 bits + GET TLS 1.3 através da AuroraTls.dll
# ---------------------------------------------------------------------------
if (-not $SkipSmokeTest) {
    $tempRoot = if ($env:RUNNER_TEMP) { $env:RUNNER_TEMP } else { [System.IO.Path]::GetTempPath() }
    $smokeScript = Join-Path $tempRoot "aurora_tls_smoke_x86.ps1"

    # O conteúdo deste script é deliberadamente ASCII puro; é gravado com BOM
    # UTF-8 para que o Windows PowerShell 5.1 o interprete correctamente.
    $smokeContent = @'
param(
    [Parameter(Mandatory = $true)]
    [string]$PublishDir
)

$ErrorActionPreference = "Stop"

Set-Location -LiteralPath $PublishDir

Add-Type -TypeDefinition @"
using System;
using System.Runtime.InteropServices;

public static class AuroraTlsSmokeTest
{
    [DllImport("kernel32.dll", SetLastError = true, CharSet = CharSet.Unicode)]
    public static extern IntPtr LoadLibrary(string lpLibFileName);

    [DllImport("AuroraTls.dll", CallingConvention = CallingConvention.Cdecl)]
    public static extern int AuroraHttpGetEx(
        byte[] url,
        int minTlsMajor,
        int minTlsMinor,
        out IntPtr data,
        out int length,
        out int httpStatus,
        byte[] error,
        int errorCapacity);

    [DllImport("AuroraTls.dll", CallingConvention = CallingConvention.Cdecl)]
    public static extern void AuroraHttpFree(IntPtr ptr);
}
"@

$dllPath = Join-Path (Get-Location) "AuroraTls.dll"
if ([AuroraTlsSmokeTest]::LoadLibrary($dllPath) -eq [IntPtr]::Zero) {
    $errorCode = [Runtime.InteropServices.Marshal]::GetLastWin32Error()
    throw "LoadLibrary failed for $dllPath (Win32 error $errorCode)"
}

$urlBytes = [System.Text.Encoding]::UTF8.GetBytes("https://archive.org" + [char]0)
$errorBytes = New-Object byte[] 512
$nativeBuffer = [IntPtr]::Zero
$length = 0
$httpStatus = 0

try {
    $rc = [AuroraTlsSmokeTest]::AuroraHttpGetEx(
        $urlBytes, 1, 3,
        [ref]$nativeBuffer, [ref]$length, [ref]$httpStatus,
        $errorBytes, $errorBytes.Length)

    if ($rc -ne 0) {
        $message = [System.Text.Encoding]::UTF8.GetString($errorBytes).TrimEnd([char]0)
        throw "AuroraTls failed (rc=$rc, status=$httpStatus, error=$message)"
    }
    if ($length -le 0) {
        throw "AuroraTls received no data (status=$httpStatus)"
    }

    $bitness = if ([IntPtr]::Size -eq 4) { "32-bit" } else { "64-bit" }
    Write-Host "Smoke-test HTTPS/TLS 1.3 OK [$bitness]: HTTP $httpStatus, $length bytes from https://archive.org"
}
finally {
    if ($nativeBuffer -ne [IntPtr]::Zero) {
        [AuroraTlsSmokeTest]::AuroraHttpFree($nativeBuffer)
    }
}
'@

    [System.IO.File]::WriteAllText(
        $smokeScript, $smokeContent, (New-Object System.Text.UTF8Encoding $true))

    $ps32 = Join-Path $env:SystemRoot "SysWOW64\WindowsPowerShell\v1.0\powershell.exe"
    if (-not (Test-Path -LiteralPath $ps32)) {
        throw "PowerShell 32 bits não encontrado: $ps32"
    }

    Write-Step "Smoke-test TLS 1.3 em PowerShell 32 bits (https://archive.org)"
    & $ps32 -NoProfile -NonInteractive -ExecutionPolicy Bypass `
        -File $smokeScript -PublishDir $PublishDir
    if ($LASTEXITCODE -ne 0) {
        throw "Smoke-test x86 da AuroraTls.dll falhou (exit $LASTEXITCODE)."
    }
}

Write-Step "Verificação Windows XP SP3 / Pentium 4 Prescott concluída com sucesso"
