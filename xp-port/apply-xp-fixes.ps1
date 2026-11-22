[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$RepoRoot,

    [Parameter(Mandatory = $true)]
    [string]$XpPortDir,

    [string]$LibsDir,

    [string]$Commit = "52cd4ac"
)

$ErrorActionPreference = "Stop"

# Em caso de erro, emitir também uma anotação ##[error] do GitHub Actions com a
# mensagem e a posição (o log completo do passo só é visível na página Actions).
trap {
    $details = ($_ | Out-String).Trim() -replace "`r?`n", ' | '
    Write-Host "##[error]$details"
    break
}

$Utf8NoBom = New-Object System.Text.UTF8Encoding $false

function Write-Step {
    param([string]$Message)
    Write-Host "==> $Message"
}

function Set-ProjectProperty {
    param(
        [System.Xml.XmlElement]$Group,
        [string]$Name,
        [string]$Value
    )
    $node = $Group.SelectSingleNode($Name)
    if ($null -eq $node) {
        $node = $Group.OwnerDocument.CreateElement($Name)
        $node.InnerText = $Value
        [void]$Group.AppendChild($node)
    }
    else {
        $node.InnerText = $Value
    }
}

function Write-TextFile {
    param(
        [string]$Path,
        [string]$Text
    )
    # UTF-8 sem BOM, idêntico em Windows PowerShell 5.1 e PowerShell 7.
    [System.IO.File]::WriteAllText($Path, $Text, $Utf8NoBom)
}

function Export-GitBlob {
    param(
        [string]$Repository,
        [string]$Spec,
        [string]$OutFile
    )

    $startInfo = New-Object System.Diagnostics.ProcessStartInfo
    $startInfo.FileName = "git"
    $startInfo.Arguments = "cat-file blob `"$Spec`""
    $startInfo.WorkingDirectory = $Repository
    $startInfo.RedirectStandardOutput = $true
    $startInfo.RedirectStandardError = $true
    $startInfo.UseShellExecute = $false
    $startInfo.CreateNoWindow = $true

    $process = [System.Diagnostics.Process]::Start($startInfo)
    try {
        # Ler o stderr em paralelo para nunca bloquear o pipe.
        $stderrTask = $process.StandardError.ReadToEndAsync()

        $stream = [System.IO.File]::Create($OutFile)
        try {
            $process.StandardOutput.BaseStream.CopyTo($stream)
        }
        finally {
            $stream.Dispose()
        }

        $stderr = $stderrTask.Result
        $process.WaitForExit()
        if ($process.ExitCode -ne 0) {
            throw "git cat-file falhou para '$Spec': $stderr"
        }
    }
    finally {
        $process.Dispose()
    }

    if (-not (Test-Path -LiteralPath $OutFile) -or
        (Get-Item -LiteralPath $OutFile).Length -eq 0) {
        throw "Blob vazio ou inexistente: $Spec"
    }
}

# ---------------------------------------------------------------------------
# Resolver caminhos
# ---------------------------------------------------------------------------
$RepoRoot = (Resolve-Path -LiteralPath $RepoRoot).Path
$XpPortDir = (Resolve-Path -LiteralPath $XpPortDir).Path
$projectDir = Join-Path $RepoRoot "AuroraAssetEditor"

if (-not (Test-Path -LiteralPath $projectDir)) {
    throw "AuroraAssetEditor não encontrado em: $projectDir"
}

if ([string]::IsNullOrWhiteSpace($LibsDir)) {
    $LibsDir = Join-Path $RepoRoot "xp-libs"
}
else {
    $LibsDir = [System.IO.Path]::GetFullPath($LibsDir)
}

New-Item -ItemType Directory -Force -Path $LibsDir | Out-Null

# ---------------------------------------------------------------------------
# (a) Recuperar as DLLs XP/.NET 4.0 a partir do commit histórico
#
# Porquê este commit:
#   - Ookii.Dialogs.Wpf 1.0 aponta para .NET 4.0 (a 5.0.1 exige net462).
#   - System.Net.FtpClient 1.0 aponta para .NET 4.0.
#   - System.Data.SQLite 1.0.97 é a build estática x86 com o código nativo
#     ligado dentro da DLL gerida e PE Subsystem 5.01.  A 1.0.118 traz um
#     SQLite.Interop.dll com Subsystem 6.0 (Vista+).
# ---------------------------------------------------------------------------
Write-Step "A verificar o commit histórico $Commit"
$commitOk = $false
try {
    $null = & git -C $RepoRoot rev-parse --verify --quiet "${Commit}^{commit}" 2>&1
    $commitOk = ($LASTEXITCODE -eq 0)
}
catch {
    $commitOk = $false
}
if (-not $commitOk) {
    throw "Commit $Commit não encontrado em $RepoRoot. Usa um checkout com fetch-depth: 0."
}

$dllNames = @(
    "Ookii.Dialogs.Wpf.dll",
    "System.Net.FtpClient.dll",
    "System.Data.SQLite.dll"
)

foreach ($name in $dllNames) {
    Write-Step "A extrair ${Commit}:AuroraAssetEditor/$name"
    Export-GitBlob `
        -Repository $RepoRoot `
        -Spec "${Commit}:AuroraAssetEditor/$name" `
        -OutFile (Join-Path $LibsDir $name)
}

# ---------------------------------------------------------------------------
# (c) Injetar AuroraHttpClient.cs + polyfills .NET 4.0 + App.config,
#     substituir WebClient e corrigir URLs / TLS
# ---------------------------------------------------------------------------
$httpClientSource = Join-Path $XpPortDir "AuroraHttpClient.cs"
$polyfillsSource = Join-Path $XpPortDir "Net40Polyfills.cs"
$appConfigSource = Join-Path $XpPortDir "App.config"

foreach ($source in @($httpClientSource, $polyfillsSource, $appConfigSource)) {
    if (-not (Test-Path -LiteralPath $source)) {
        throw "Ficheiro em falta no xp-port: $source"
    }
}

Copy-Item `
    -LiteralPath $httpClientSource `
    -Destination (Join-Path $projectDir "Classes\AuroraHttpClient.cs") `
    -Force
Copy-Item `
    -LiteralPath $polyfillsSource `
    -Destination (Join-Path $projectDir "Net40Polyfills.cs") `
    -Force
Copy-Item `
    -LiteralPath $appConfigSource `
    -Destination (Join-Path $projectDir "App.config") `
    -Force

# System.Net.WebClient só fala TLS 1.0 no .NET 4.0/XP: trocar pelo shim nativo.
$downloaderFiles = @(
    "Classes\InternetArchiveAssetDownloader.cs",
    "Classes\XboxAssetDownloader.cs",
    "Classes\XboxUnity.cs"
)

foreach ($relative in $downloaderFiles) {
    $path = Join-Path $projectDir $relative
    if (-not (Test-Path -LiteralPath $path)) {
        throw "Ficheiro de download em falta: $path"
    }

    $text = Get-Content -LiteralPath $path -Raw -Encoding UTF8
    $text = [regex]::Replace($text, '\bWebClient\b', 'AuroraHttpClient')
    $text = $text.Replace('http://xboxunity.net', 'https://xboxunity.net')
    Write-TextFile -Path $path -Text $text

    Write-Step "AuroraHttpClient aplicado a $relative"
}

# Remover a atribuição ServicePointManager.SecurityProtocol que rebenta no XP:
# o TLS 1.2/1.3 é tratado pela camada nativa; o .NET 4.0 no XP lança exceção
# para 768/3072.
$mainWindowPath = Join-Path $projectDir "MainWindow.xaml.cs"
$mainWindow = Get-Content -LiteralPath $mainWindowPath -Raw -Encoding UTF8

$mainWindow = [regex]::Replace(
    $mainWindow,
    '(?m)^[ \t]*//[^\r\n]*add support for TLS 1\.1 and TLS 1\.2[^\r\n]*\r?\n',
    ''
)
$mainWindow = [regex]::Replace(
    $mainWindow,
    '(?m)^([ \t]*)ServicePointManager\.SecurityProtocol\s*=\s*ServicePointManager\.SecurityProtocol[\s\S]*?;[ \t]*(?://[^\r\n]*)?',
    '$1// TLS 1.2/1.3 are handled natively by AuroraTls.dll (OpenSSL 1.1.1w) - avoids the XP crash'
)

Write-TextFile -Path $mainWindowPath -Text $mainWindow
Write-Step "ServicePointManager.SecurityProtocol removido de MainWindow.xaml.cs"

# ---------------------------------------------------------------------------
# (b) Adaptar AuroraAssetEditor.csproj para net40 / x86 / DLLs XP locais
# ---------------------------------------------------------------------------
$csprojPath = Join-Path $projectDir "AuroraAssetEditor.csproj"
[xml]$xml = Get-Content -LiteralPath $csprojPath -Raw -Encoding UTF8
$project = $xml.Project
if ($null -eq $project) {
    throw "csproj inválido: $csprojPath"
}

$propertyGroup = $project.PropertyGroup |
    Where-Object { $_.TargetFramework -ne $null } |
    Select-Object -First 1
if ($null -eq $propertyGroup) {
    throw "Não foi encontrado um PropertyGroup com <TargetFramework> em $csprojPath"
}

# O adaptador XML do PowerShell não cria elementos novos por atribuição de
# propriedade: procurar o filho e criá-lo se não existir.
Set-ProjectProperty $propertyGroup "TargetFramework" "net40"
Set-ProjectProperty $propertyGroup "PlatformTarget" "x86"
Set-ProjectProperty $propertyGroup "Platforms" "x86"
Set-ProjectProperty $propertyGroup "LangVersion" "latest"
Set-ProjectProperty $propertyGroup "Optimize" "true"
Set-ProjectProperty $propertyGroup "DebugType" "none"

# Remover todas as PackageReference (o upstream usa Ookii 5.0.1 e
# System.Data.SQLite 1.0.118, ambos incompatíveis com XP/.NET 4.0).
foreach ($group in @($project.ItemGroup)) {
    foreach ($package in @($group.PackageReference)) {
        $group.RemoveChild($package) | Out-Null
    }
}

$referenceNames = @(
    "Ookii.Dialogs.Wpf",
    "System.Data.SQLite",
    "System.Net.FtpClient",
    "System.Runtime.Serialization",
    "System.Web"
)

# Remover referências pré-existentes com o mesmo nome (script idempotente).
foreach ($group in @($project.ItemGroup)) {
    foreach ($reference in @($group.Reference)) {
        if ($referenceNames -contains $reference.Include) {
            $group.RemoveChild($reference) | Out-Null
        }
    }
}

# Remover ItemGroups que ficaram vazios.
foreach ($group in @($project.ItemGroup)) {
    if ($group.ChildNodes.Count -eq 0) {
        $project.RemoveChild($group) | Out-Null
    }
}

# Microsoft.NETFramework.ReferenceAssemblies.net40 1.0.3
$packageGroup = $xml.CreateElement("ItemGroup")
$package = $xml.CreateElement("PackageReference")
$package.SetAttribute("Include", "Microsoft.NETFramework.ReferenceAssemblies.net40")
$package.SetAttribute("Version", "1.0.3")
$package.SetAttribute("PrivateAssets", "all")
$packageGroup.AppendChild($package) | Out-Null
$project.AppendChild($packageGroup) | Out-Null

# As três DLLs XP mais as assemblies do framework que o código fonte usa.
# Nota: o App.config é detectado automaticamente pelo MSBuild (FindAppConfigFile)
# e copiado como AuroraAssetEditor.exe.config.
$projectUri = New-Object System.Uri($projectDir.TrimEnd('\') + '\')
$referenceGroup = $xml.CreateElement("ItemGroup")
foreach ($dll in $dllNames) {
    $name = [System.IO.Path]::GetFileNameWithoutExtension($dll)
    $dllUri = New-Object System.Uri((Join-Path $LibsDir $dll))
    $relativeHint = [System.Uri]::UnescapeDataString($projectUri.MakeRelativeUri($dllUri).ToString()).Replace('/', '\')
    $reference = $xml.CreateElement("Reference")
    $reference.SetAttribute("Include", $name)
    $hint = $xml.CreateElement("HintPath")
    $hint.InnerText = $relativeHint
    $private = $xml.CreateElement("Private")
    $private.InnerText = "True"
    $reference.AppendChild($hint) | Out-Null
    $reference.AppendChild($private) | Out-Null
    $referenceGroup.AppendChild($reference) | Out-Null
}
foreach ($frameworkReference in @("System.Runtime.Serialization", "System.Web")) {
    $reference = $xml.CreateElement("Reference")
    $reference.SetAttribute("Include", $frameworkReference)
    $referenceGroup.AppendChild($reference) | Out-Null
}
$project.AppendChild($referenceGroup) | Out-Null

$xml.Save($csprojPath)

Write-Step "AuroraAssetEditor.csproj adaptado para net40 | x86 | ReferenceAssemblies.net40 1.0.3"
Write-Step "Fixes XP aplicados com sucesso"
