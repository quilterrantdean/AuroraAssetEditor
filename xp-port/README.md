# xp-port

Sistema de build auxiliar para uma release **Windows XP SP3 32 bits** do
Aurora Asset Editor, optimizada para um **Intel Pentium 4 HT "Prescott"** e
com suporte nativo a **TLS 1.2 / TLS 1.3**.

Tudo nesta pasta está deliberadamente separado das fontes upstream.  Os
ficheiros upstream nunca são editados em Git, pelo que um **Sync fork** contra
`XboxUnity/AuroraAssetEditor` fica sem conflitos.  Todas as alterações são
aplicadas em tempo de build a um checkout fresco do upstream pelo
`apply-xp-fixes.ps1`.

## Ficheiros

| Ficheiro | Função |
| --- | --- |
| `build-tls.sh` | Build MSYS2 MINGW32 de zlib 1.3.1, OpenSSL 1.1.1w, libcurl 8.11.0 e `AuroraTls.dll`, tudo estático, `-march=prescott`, PE Subsystem 5.01. |
| `aurora_tls.c` | Fonte da `AuroraTls.dll`: `AuroraHttpGet`, `AuroraHttpGetEx`, `AuroraHttpFree`, partilha thread-safe `CRITICAL_SECTION` + `CURLSH*` (DNS, sessão TLS, cache de ligações), validação com `cacert.pem` e fallback para relógios de XP desregulados. |
| `AuroraHttpClient.cs` | Substituto de `WebClient` para .NET 4.0 que faz P/Invoke à `AuroraTls.dll` com buffers UTF-8 `byte[]`. |
| `Net40Polyfills.cs` | Polyfills mínimos de .NET 4.0 (`CallerMemberName` etc.) para atributos do compilador que só existem no .NET 4.5+ e que as fontes upstream usam. |
| `App.config` | Configuração do runtime .NET 4.0 (`useLegacyV2RuntimeActivationPolicy`). |
| `apply-xp-fixes.ps1` | Patcher baseado em regras: recupera as DLLs XP do commit `52cd4ac`, copia o shim/polyfills/config, substitui `WebClient`, troca `WebUtility.UrlEncode/UrlDecode` (.NET 4.5+) por `System.Web.HttpUtility`, passa xboxunity para HTTPS, remove o `ServicePointManager.SecurityProtocol` que rebenta no XP e reescreve o csproj para `net40`/`x86`. |
| `verify-xp.ps1` | Carimbagem `editbin`/`CorFlags`, auditoria completa com `objdump` (PE32, Subsystem <= 5.01, allowlist de imports, blocklist de APIs Vista+, blocklist de instruções pós-Prescott) e um smoke-test real TLS 1.3 em PowerShell 32 bits contra `https://archive.org`. |

## Como a release é produzida

`.github/workflows/auroraedit-xp.yml` é deliberadamente curto:

1. Faz checkout deste fork e copia `xp-port/` para um diretório temporário.
2. Faz checkout de `XboxUnity/AuroraAssetEditor` com `fetch-depth: 0` para que
   o commit histórico `52cd4ac` esteja disponível.
3. Configura o MSYS2 MINGW32 e repõe a cache `C:/xp-prescott-deps`.
4. Corre `build-tls.sh` (as dependências são saltadas quando a cache está quente).
5. Corre `apply-xp-fixes.ps1` no checkout fresco do upstream.
6. Publica a app com `dotnet publish -f net40 -p:Platform=x86`.
7. Corre `verify-xp.ps1` (auditoria PE + smoke-test TLS 1.3).
8. Empacota o ZIP, escreve o `.sha256`, envia um Artefacto e, opcionalmente,
   cria uma GitHub Release.

### Correr o workflow

* **Release:** criar uma tag `v…` neste fork (`git tag v1.4.3-xp-prescott &&
  git push origin v1.4.3-xp-prescott`) — a release é publicada com o ZIP.
* **Só o artefacto:** Actions → *Aurora Asset Editor XP* → *Run workflow* com
  `create_release = false`.

## Correr localmente

### 1. Compilar a pilha TLS (MSYS2 MINGW32)

```bash
pacman -S --needed mingw-w64-i686-toolchain perl make diffutils curl
bash xp-port/build-tls.sh
```

> **Nota (2026):** a MSYS2 está a descontinuar o ambiente MINGW32 e já
> retirou vários pacotes i686 (`mingw-w64-i686-make`, `mingw-w64-i686-gdb`,
> …).  O toolchain (`mingw-w64-i686-gcc`) ainda existe, mas se um dia
> desaparecer, o `build-tls.sh` também corre **em Linux** com o cross-compiler
> oficial, sem alterações: `sudo apt install gcc-mingw-w64-i686 perl make
> curl` e `DEPS_PREFIX=$HOME/xp-prescott-deps bash xp-port/build-tls.sh`.
> O mesmo `HOST` (`i686-w64-mingw32`) e as mesmas flags são usadas; a única
> diferença é que o Linux não precisa de `cygpath`.

Por omissão o output vai para `${RUNNER_TEMP:-/tmp}/xp-native`.  Sobrepor com:

```bash
DEPS_PREFIX='C:/xp-prescott-deps' \
XP_NATIVE_OUT='C:/xp-native' \
bash xp-port/build-tls.sh
```

Os tarballs são descarregados dos sites oficiais (`zlib.net`, `curl.se`,
GitHub do OpenSSL) com espelhos de fallback; o `cacert.pem` vem sempre de
`https://curl.se/ca/cacert.pem`.

### 2. Aplicar os patches a um checkout fresco do upstream

```powershell
git clone https://github.com/XboxUnity/AuroraAssetEditor.git src
cd src
git fetch --unshallow            # ou clonar com --fetch-depth=0
pwsh ../xp-port/apply-xp-fixes.ps1 -RepoRoot . -XpPortDir ../xp-port
```

### 3. Compilar e verificar

```powershell
dotnet restore .\AuroraAssetEditor\AuroraAssetEditor.csproj
dotnet publish .\AuroraAssetEditor\AuroraAssetEditor.csproj `
    -c Release -f net40 -p:Platform=x86 -p:PlatformTarget=x86 -p:Optimize=true -o publish

Copy-Item C:\xp-native\AuroraTls.dll publish\ -Force
Copy-Item C:\xp-native\cacert.pem publish\ -Force

pwsh ..\xp-port\verify-xp.ps1 -PublishDir publish `
    -ObjdumpPath 'C:\msys64\mingw32\bin\objdump.exe'
```

## Notas de desenho

* **Zero edições ao upstream.** O `apply-xp-fixes.ps1` trabalha sobre um
  checkout descartável.  O `master` do fork pode ser sincronizado a qualquer
  momento sem conflitos.
* **DLLs XP do histórico.** Ookii 1.0, System.Net.FtpClient 1.0 e
  System.Data.SQLite 1.0.97 (build estática x86, Subsystem 5.01) são extraídos
  do commit `52cd4ac` com `git cat-file blob` — nada é guardado em binário
  neste fork.
* **Imports seguros para XP.** O `verify-xp.ps1` falha o build perante qualquer
  DLL fora de uma allowlist explícita de DLLs de sistema do XP, o que apanha
  também dependências acidentais em `libgcc_s_dw2-1.dll` / `libwinpthread-1.dll`.
* **APIs Vista+ bloqueadas.** `AcquireSRWLock*`, `GetTickCount64`,
  `BCryptGenRandom`, `WSAPoll`, `inet_pton`, `inet_ntop`, `GetAddrinfoEx`,
  `InitializeCriticalSectionEx` e muitas outras são rejeitadas.
* **Instruções pós-Prescott bloqueadas.** `pshufb`, `palignr`, `pmulld`,
  `popcnt`, `aesenc`, AVX e companhia são rejeitadas nas DLLs nativas
  (desassemblagem ancorada na coluna do mnemonic para evitar falsos positivos).
* **Fallback de certificados.** Se a máquina XP tiver a pilha do CMOS morta e o
  relógio anos fora do sítio, a validação falha; a camada nativa repete uma vez
  sem verificação em vez de abortar o download em massa.  A validação com
  `cacert.pem` continua a ser o comportamento por omissão.
