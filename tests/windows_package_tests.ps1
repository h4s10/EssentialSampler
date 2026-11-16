param([string]$BuildDir = 'build/windows/Release')
$ErrorActionPreference = 'Stop'
Set-Location (Split-Path -Parent $PSScriptRoot)
$package = (Resolve-Path -LiteralPath 'build/package-windows/EssentialSampler-0.7.0-Windows-x64-all').Path
$target = Join-Path ([IO.Path]::GetTempPath()) ('EssentialSampler-package-' + [Guid]::NewGuid().ToString('N'))
try {
    & powershell.exe -NoProfile -ExecutionPolicy Bypass -File (Join-Path $package 'Install.ps1') -PackageRoot $package -Destination $target -NoPause
    if ($LASTEXITCODE -ne 0) { throw 'The actual release package did not install' }
    $contents = Join-Path $target 'Essential Sampler.vst3/Contents'
    $module = Get-Content -LiteralPath (Join-Path $contents 'Resources/moduleinfo.json') -Raw | ConvertFrom-Json
    if ($module.Name -ne 'Essential Sampler' -or $module.Version -ne '0.7.0' -or $module.Classes[0].CID -ne '484153494F4C4F4F5056535433000001') { throw 'Packaged module metadata mismatch' }
    $installed = Join-Path $contents 'x86_64-win/Essential Sampler.vst3'
    if ((Get-FileHash -LiteralPath $installed).Hash -ne (Get-FileHash -LiteralPath (Join-Path $BuildDir 'Essential Sampler.vst3')).Hash) { throw 'Installed binary differs from tested build' }
    & (Join-Path $BuildDir 'windows_host_tests.exe') $installed
    if ($LASTEXITCODE -ne 0) { throw 'The installed plugin failed the native VST3 host suite' }
    Write-Host 'PASS: real release installation, module metadata, binary identity and installed VST3 rendering/editor lifecycle.'
} finally { if (Test-Path -LiteralPath $target) { Remove-Item -LiteralPath $target -Recurse -Force } }
