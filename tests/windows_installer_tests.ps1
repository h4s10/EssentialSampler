$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
$temporary = Join-Path ([IO.Path]::GetTempPath()) ('EssentialSampler-' + [Guid]::NewGuid().ToString('N'))
$package = Join-Path $temporary 'package with spaces'
$destination = Join-Path $temporary 'VST3'
$relative = 'Essential Sampler.vst3/Contents/x86_64-win/Essential Sampler.vst3'
$binary = Join-Path $package $relative
try {
    New-Item -ItemType Directory -Path (Split-Path -Parent $binary) -Force | Out-Null
    $bytes = New-Object byte[] 256
    $bytes[0] = 0x4D; $bytes[1] = 0x5A; $bytes[0x3C] = 0x80
    $bytes[0x80] = 0x50; $bytes[0x81] = 0x45; $bytes[0x84] = 0x64; $bytes[0x85] = 0x86
    [IO.File]::WriteAllBytes($binary, $bytes)
    $hashes = @{}; $hashes[$relative] = (Get-FileHash -LiteralPath $binary).Hash
    $hashes | ConvertTo-Json | Set-Content -Encoding UTF8 (Join-Path $package 'checksums.json')
    $installer = Join-Path $root 'scripts/install-windows.ps1'
    & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $installer -Destination $destination -PackageRoot $package -NoPause
    if ($LASTEXITCODE -ne 0) { throw 'Clean installation failed' }
    $target = Join-Path $destination 'Essential Sampler.vst3'
    'old version' | Set-Content -LiteralPath (Join-Path $target 'old.txt')
    & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $installer -Destination $destination -PackageRoot $package -NoPause
    if ($LASTEXITCODE -ne 0) { throw 'Upgrade failed' }
    $backups = @(Get-ChildItem -LiteralPath $destination -Directory | Where-Object Name -Like '*.backup-*')
    if ($backups.Count -ne 1 -or -not (Test-Path -LiteralPath (Join-Path $backups[0].FullName 'old.txt'))) { throw 'Old installation was not backed up' }
    $bytes[200] = 1; [IO.File]::WriteAllBytes($binary, $bytes)
    & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $installer -Destination $destination -PackageRoot $package -NoPause
    if ($LASTEXITCODE -eq 0) { throw 'Corrupted package was accepted' }
    if ((Get-FileHash -LiteralPath (Join-Path $destination $relative)).Hash -ne $hashes[$relative]) { throw 'Rejected package modified the installed plugin' }
    if (@(Get-ChildItem -LiteralPath $destination -Force -Directory | Where-Object Name -Like '.EssentialSampler-install-*').Count) { throw 'Installer left staging folders' }
    Write-Host 'PASS: Windows clean install, upgrade backup, checksum rejection and previous-version preservation.'
} finally { if (Test-Path -LiteralPath $temporary) { Remove-Item -LiteralPath $temporary -Recurse -Force } }
