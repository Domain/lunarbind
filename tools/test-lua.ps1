#requires -Version 5.1
<#
.SYNOPSIS
    Fetch Lua runtimes and run the lunarbind test suite for every profile.

.DESCRIPTION
    Lua 5.1-5.5 are downloaded as prebuilt Visual Studio import libraries and
    DLLs from LuaBinaries. LuaJIT is built from its official git source with
    MSVC (the same toolchain LDC uses on Windows).

    Downloaded/built runtimes are cached under .lua/ in the repository and are
    not committed. Use -Force to refresh them. Pass -Bench to also build and
    run bench/bench.d against each profile after its tests pass. After the
    profile loop, samples/hello.d and samples/stubs.d are compiled and run
    against the first profile so they cannot drift from the public API.

.EXAMPLE
    .\tools\test-lua.ps1
    .\tools\test-lua.ps1 -Profiles lua54,luajit
    .\tools\test-lua.ps1 -Compiler dmd -Profiles lua54
    .\tools\test-lua.ps1 -Bench -Profiles lua54
#>
param(
    [string[]]$Profiles = @("lua51", "lua52", "lua53", "lua54", "lua55", "luajit"),
    [string]$Compiler = "ldc2",
    [string]$Dub = "dub",
    [switch]$Force,
    [switch]$Bench
)

$ErrorActionPreference = "Stop"

$Root = Split-Path -Parent $PSScriptRoot
$RuntimeRoot = Join-Path $Root ".lua"
$DownloadRoot = Join-Path $RuntimeRoot "downloads"
$SourceRoot = Join-Path $RuntimeRoot "src"

New-Item -ItemType Directory -Force $DownloadRoot | Out-Null
New-Item -ItemType Directory -Force $SourceRoot | Out-Null

$Arch = if ([Environment]::Is64BitProcess) { "Win64" } else { "Win32" }

# LuaBinaries packages built with Visual Studio 2022 (dll17). Lua 5.1 names its
# files lua5.1.*; the import library is copied to lua51.lib so the dub `lua51`
# configuration and LuaJIT share one library name. The DLL keeps its original
# name because that is the name embedded in the import library.
$LuaPackages = @{
    lua51 = @{
        Version    = "5.1.5"
        Package    = "lua-5.1.5_${Arch}_dll17_lib.zip"
        PackageLib = "lua5.1.lib"
        PackageDll = "lua5.1.dll"
        Lib        = "lua51.lib"
        Dll        = "lua5.1.dll"
    }
    lua52 = @{
        Version    = "5.2.4"
        Package    = "lua-5.2.4_${Arch}_dll17_lib.zip"
        PackageLib = "lua52.lib"
        PackageDll = "lua52.dll"
        Lib        = "lua52.lib"
        Dll        = "lua52.dll"
    }
    lua53 = @{
        Version    = "5.3.6"
        Package    = "lua-5.3.6_${Arch}_dll17_lib.zip"
        PackageLib = "lua53.lib"
        PackageDll = "lua53.dll"
        Lib        = "lua53.lib"
        Dll        = "lua53.dll"
    }
    lua54 = @{
        Version    = "5.4.8"
        Package    = "lua-5.4.8_${Arch}_dll17_lib.zip"
        PackageLib = "lua54.lib"
        PackageDll = "lua54.dll"
        Lib        = "lua54.lib"
        Dll        = "lua54.dll"
    }
    lua55 = @{
        Version    = "5.5.0"
        Package    = "lua-5.5.0_${Arch}_dll17_lib.zip"
        PackageLib = "lua55.lib"
        PackageDll = "lua55.dll"
        Lib        = "lua55.lib"
        Dll        = "lua55.dll"
    }
}

function Download-File {
    param([string]$Url, [string]$Destination)

    if ((Test-Path $Destination) -and -not $Force) {
        Write-Host "  cached: $Destination"
        return
    }

    Write-Host "  downloading: $Url"
    $tmp = "$Destination.part"
    Remove-Item -Force $tmp -ErrorAction SilentlyContinue

    if (Get-Command curl.exe -ErrorAction SilentlyContinue) {
        & curl.exe -L --fail --silent --show-error --connect-timeout 15 `
            --retry 3 --retry-delay 2 -o $tmp $Url
        if ($LASTEXITCODE -ne 0) {
            Remove-Item -Force $tmp -ErrorAction SilentlyContinue
            throw "download failed: $Url"
        }
    }
    else {
        Invoke-WebRequest -UseBasicParsing -Uri $Url -OutFile $tmp
    }

    Move-Item -Force $tmp $Destination
}

function Expand-Package {
    param([string]$Archive, [string]$Destination)

    Remove-Item -Recurse -Force $Destination -ErrorAction SilentlyContinue
    New-Item -ItemType Directory -Force $Destination | Out-Null
    Expand-Archive -Path $Archive -DestinationPath $Destination -Force
}

function Get-RuntimeDir {
    param([string]$Profile)
    $dir = Join-Path $RuntimeRoot $Profile
    New-Item -ItemType Directory -Force $dir | Out-Null
    return $dir
}

function Ensure-LuaRuntime {
    param([string]$Profile)

    $spec = $LuaPackages[$Profile]
    if ($null -eq $spec) {
        throw "unknown Lua profile: $Profile"
    }

    $dir = Get-RuntimeDir $Profile
    $lib = Join-Path $dir $spec.Lib
    $dll = Join-Path $dir $spec.Dll
    if ((Test-Path $lib) -and (Test-Path $dll) -and -not $Force) {
        Write-Host "  runtime ready: $dir"
        return
    }

    $archive = Join-Path $DownloadRoot $spec.Package
    $url = "https://sourceforge.net/projects/luabinaries/files/$($spec.Version)/Windows%20Libraries/Dynamic/$($spec.Package)/download"
    Download-File $url $archive

    $extract = Join-Path $DownloadRoot ($spec.Package -replace '\.zip$', '')
    Expand-Package $archive $extract

    $foundLib = Get-ChildItem -Recurse -File -Filter $spec.PackageLib $extract | Select-Object -First 1
    $foundDll = Get-ChildItem -Recurse -File -Filter $spec.PackageDll $extract | Select-Object -First 1
    if ($null -eq $foundLib -or $null -eq $foundDll) {
        throw "package $($spec.Package) does not contain $($spec.PackageLib) and $($spec.PackageDll)"
    }

    Copy-Item -Force $foundLib.FullName $lib
    Copy-Item -Force $foundDll.FullName $dll
    Write-Host "  runtime ready: $dir"
}

function Find-VcVars {
    $vswhere = Join-Path ${env:ProgramFiles(x86)} "Microsoft Visual Studio\Installer\vswhere.exe"
    if (Test-Path $vswhere) {
        $install = & $vswhere -latest -products * `
            -requires Microsoft.VisualStudio.Component.VC.Tools.x86.x64 `
            -property installationPath
        if ($install) {
            $vcvars = Join-Path $install "VC\Auxiliary\Build\vcvars64.bat"
            if (Test-Path $vcvars) {
                return $vcvars
            }
        }
    }
    return $null
}

function Ensure-LuaJitRuntime {
    $dir = Get-RuntimeDir "luajit"
    $lib = Join-Path $dir "lua51.lib"
    $dll = Join-Path $dir "lua51.dll"
    if ((Test-Path $lib) -and (Test-Path $dll) -and -not $Force) {
        Write-Host "  runtime ready: $dir"
        return
    }

    # Allow callers to point at an existing LuaJIT build.
    if ($env:LUNARBIND_LUAJIT_LIB -and $env:LUNARBIND_LUAJIT_DLL) {
        if (!(Test-Path $env:LUNARBIND_LUAJIT_LIB) -or !(Test-Path $env:LUNARBIND_LUAJIT_DLL)) {
            throw "LUNARBIND_LUAJIT_LIB/LUNARBIND_LUAJIT_DLL do not point at existing files"
        }
        Copy-Item -Force $env:LUNARBIND_LUAJIT_LIB $lib
        Copy-Item -Force $env:LUNARBIND_LUAJIT_DLL $dll
        Write-Host "  runtime ready: $dir"
        return
    }

    $source = Join-Path $SourceRoot "LuaJIT-2.1"
    if (!(Test-Path (Join-Path $source "src\msvcbuild.bat")) -or $Force) {
        $archive = Join-Path $DownloadRoot "LuaJIT-v2.1.tar.gz"
        $url = "https://codeload.github.com/LuaJIT/LuaJIT/tar.gz/refs/heads/v2.1"
        Download-File $url $archive
        Remove-Item -Recurse -Force $source -ErrorAction SilentlyContinue
        New-Item -ItemType Directory -Force $SourceRoot | Out-Null
        & tar.exe -xzf $archive -C $SourceRoot
        if ($LASTEXITCODE -ne 0) {
            throw "failed to extract $archive"
        }
    }

    $vcvars = Find-VcVars
    if ($null -eq $vcvars) {
        throw @"
LuaJIT needs MSVC to build. Install the Visual Studio C++ tools, or set
LUNARBIND_LUAJIT_LIB and LUNARBIND_LUAJIT_DLL to an existing LuaJIT build.
"@
    }

    Write-Host "  building LuaJIT with MSVC"
    $cmd = "call `"$vcvars`" >nul && cd /d `"$source\src`" && msvcbuild.bat"
    & cmd.exe /c $cmd
    if ($LASTEXITCODE -ne 0) {
        throw "LuaJIT build failed"
    }

    $builtLib = Join-Path $source "src\lua51.lib"
    $builtDll = Join-Path $source "src\lua51.dll"
    if (!(Test-Path $builtLib) -or !(Test-Path $builtDll)) {
        throw "LuaJIT build did not produce lua51.lib/lua51.dll"
    }

    Copy-Item -Force $builtLib $lib
    Copy-Item -Force $builtDll $dll
    Write-Host "  runtime ready: $dir"
}

function Get-ProfileVersions {
    param([string]$Profile)

    switch ($Profile) {
        "lua51" { return @("LUA_51") }
        "lua52" { return @("LUA_52") }
        "lua53" { return @("LUA_53") }
        "lua54" { return @("LUA_54") }
        "lua55" { return @("LUA_55") }
        "luajit" { return @("LUA_51", "LUAJIT") }
        default { throw "unknown Lua profile: $Profile" }
    }
}

function Invoke-ProfileBench {
    param([string]$Profile, [string]$Runtime)

    $libName = if ($Profile -eq "luajit") { "lua51.lib" }
               else { "lua$($Profile.Substring(3)).lib" }
    $lib = Join-Path $Runtime $libName
    $exe = Join-Path $Runtime "lunarbind-bench.exe"
    $source = Join-Path $Root "source"
    $entry = Join-Path $Root "bench\bench.d"

    $versionFlag = if ($Compiler -match "dmd") { "-version=" } else { "-d-version=" }
    $args = @("-i", "-I$source", "-O")
    foreach ($version in Get-ProfileVersions $Profile) {
        $args += "$versionFlag$version"
    }
    $args += @($entry, $lib, "-of=$exe")

    Write-Host "  building benchmark"
    & $Compiler @args
    if ($LASTEXITCODE -ne 0) {
        throw "benchmark build failed for $Profile"
    }

    & $exe
    if ($LASTEXITCODE -ne 0) {
        throw "benchmark failed for $Profile"
    }
}

function Invoke-Samples {
    param([string]$Profile, [string]$Runtime)

    $libName = if ($Profile -eq "luajit") { "lua51.lib" }
               else { "lua$($Profile.Substring(3)).lib" }
    $lib = Join-Path $Runtime $libName
    $source = Join-Path $Root "source"

    $versionFlag = if ($Compiler -match "dmd") { "-version=" } else { "-d-version=" }
    $compileArgs = @("-i", "-I$source", "-O")
    foreach ($version in Get-ProfileVersions $Profile) {
        $compileArgs += "$versionFlag$version"
    }

    $oldPath = $env:PATH
    try {
        $env:PATH = "$Runtime;$oldPath"
        foreach ($sample in @("hello", "stubs")) {
            $exe = Join-Path $Runtime "sample-$sample.exe"
            $entry = Join-Path $Root "samples\$sample.d"
            Write-Host "  building sample: $sample"
            & $Compiler @compileArgs $entry $lib "-of=$exe"
            if ($LASTEXITCODE -ne 0) {
                throw "sample build failed: $sample ($Profile)"
            }
            & $exe
            if ($LASTEXITCODE -ne 0) {
                throw "sample run failed: $sample ($Profile)"
            }
        }
    }
    finally {
        $env:PATH = $oldPath
    }
}

function Invoke-ProfileTest {
    param([string]$Profile)

    Write-Host ""
    Write-Host "== $Profile =="

    if ($Profile -eq "luajit") {
        Ensure-LuaJitRuntime
    }
    else {
        Ensure-LuaRuntime $Profile
    }

    $runtime = Join-Path $RuntimeRoot $Profile
    $oldPath = $env:PATH
    $oldLib = $env:LIB
    try {
        $env:PATH = "$runtime;$oldPath"
        $env:LIB = "$runtime;$oldLib"
        & $Dub test --root=$Root --config=$Profile --compiler=$Compiler
        if ($LASTEXITCODE -ne 0) {
            throw "tests failed for $Profile"
        }

        if ($Bench) {
            Invoke-ProfileBench $Profile $runtime
        }
    }
    finally {
        $env:PATH = $oldPath
        $env:LIB = $oldLib
    }
}

Write-Host "lunarbind Lua runtime test"
Write-Host "  root:     $Root"
Write-Host "  compiler: $Compiler"
Write-Host "  profiles: $($Profiles -join ', ')"
Write-Host "  bench:    $(if ($Bench) { 'yes' } else { 'no' })"

foreach ($profile in $Profiles) {
    Invoke-ProfileTest $profile
}

if ($Profiles.Count -gt 0) {
    $sampleProfile = $Profiles[0]
    Write-Host ""
    Write-Host "== samples ($sampleProfile) =="
    Invoke-Samples $sampleProfile (Join-Path $RuntimeRoot $sampleProfile)
}

Write-Host ""
Write-Host "all profiles passed"
