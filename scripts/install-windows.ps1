param(
    [string]$Destination = '',
    [string]$PackageRoot = $PSScriptRoot,
    [switch]$NoPause
)
$ErrorActionPreference = 'Stop'
try {
    if (-not [Environment]::Is64BitOperatingSystem) { throw 'Essential Sampler requires 64-bit Windows.' }
    $source = Join-Path $PackageRoot 'Essential Sampler.vst3'
    $relativeBinary = 'Contents/x86_64-win/Essential Sampler.vst3'
    $binary = Join-Path $source $relativeBinary
    $manifestPath = Join-Path $PackageRoot 'checksums.json'
    if (-not (Test-Path -LiteralPath $binary -PathType Leaf)) { throw 'Extract the complete release archive before installing.' }
    $manifest = Get-Content -LiteralPath $manifestPath -Raw | ConvertFrom-Json
    $expected = $manifest.'Essential Sampler.vst3/Contents/x86_64-win/Essential Sampler.vst3'
    $actual = (Get-FileHash -LiteralPath $binary -Algorithm SHA256).Hash
    if (-not $expected -or $actual -ne $expected) { throw 'The plugin checksum does not match. Download and extract the release again.' }
    $bytes = [IO.File]::ReadAllBytes($binary)
    if ($bytes.Length -lt 128 -or $bytes[0] -ne 0x4D -or $bytes[1] -ne 0x5A) { throw 'Invalid Windows plugin binary.' }
    $offset = [BitConverter]::ToInt32($bytes, 0x3C)
    if ($offset -lt 64 -or $offset -gt $bytes.Length - 6 -or [BitConverter]::ToUInt32($bytes, $offset) -ne 0x4550 -or [BitConverter]::ToUInt16($bytes, $offset + 4) -ne 0x8664) { throw 'Expected an x64 Windows plugin.' }
    if (-not $Destination) {
        $admin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
        if (-not $admin) {
            Write-Host 'Administrator access is required to install into Common Files\VST3.'
            $arguments = '-NoProfile -ExecutionPolicy Bypass -File "{0}" -PackageRoot "{1}"' -f $PSCommandPath, $PackageRoot
            if ($NoPause) { $arguments += ' -NoPause' }
            $process = Start-Process powershell.exe -ArgumentList $arguments -Verb RunAs -Wait -PassThru
            exit $process.ExitCode
        }
        $common = $env:CommonProgramW6432
        if (-not $common) { $common = $env:CommonProgramFiles }
        $Destination = Join-Path $common 'VST3'
    }
    New-Item -ItemType Directory -Force -Path $Destination | Out-Null
    $target = Join-Path $Destination 'Essential Sampler.vst3'
    $stage = Join-Path $Destination ('.EssentialSampler-install-' + [Guid]::NewGuid().ToString('N'))
    $backup = $null
    try {
        Copy-Item -LiteralPath $source -Destination $stage -Recurse
        if ((Get-FileHash -LiteralPath (Join-Path $stage $relativeBinary) -Algorithm SHA256).Hash -ne $expected) { throw 'The staged plugin failed verification.' }
        if (Test-Path -LiteralPath $target) {
            $backup = $target + '.backup-' + (Get-Date -Format 'yyyyMMdd-HHmmss') + '-' + [Guid]::NewGuid().ToString('N').Substring(0, 8)
            Move-Item -LiteralPath $target -Destination $backup
        }
        try { Move-Item -LiteralPath $stage -Destination $target }
        catch {
            if ($backup -and -not (Test-Path -LiteralPath $target)) { Move-Item -LiteralPath $backup -Destination $target; $backup = $null }
            throw
        }
    } finally { if (Test-Path -LiteralPath $stage) { Remove-Item -LiteralPath $stage -Recurse -Force } }
    Write-Host "Installed: $target"
    if ($backup) { Write-Host "Previous version: $backup" }
    Write-Host 'Reopen your DAW and rescan VST3 plugins. Look for hasio > Essential Sampler.'
    if (-not $NoPause) { Read-Host 'Press Enter to close' | Out-Null }
    exit 0
} catch {
    Write-Host "Installation failed: $($_.Exception.Message)" -ForegroundColor Red
    Write-Host 'Close your DAW and try again, or copy the complete Essential Sampler.vst3 folder into Common Files\VST3 manually.'
    if (-not $NoPause) { Read-Host 'Press Enter to close' | Out-Null }
    exit 1
}
