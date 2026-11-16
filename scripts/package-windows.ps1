param([string]$BuildDir = 'build/windows/Release')
$ErrorActionPreference = 'Stop'
Set-Location (Split-Path -Parent $PSScriptRoot)
$version = '0.7.0'
$build = (Resolve-Path -LiteralPath $BuildDir).Path
foreach ($format in @('VST3', 'all')) {
    $name = "EssentialSampler-$version-Windows-x64-$format"
    $stage = Join-Path 'build/package-windows' $name
    if (Test-Path -LiteralPath $stage) { Remove-Item -LiteralPath $stage -Recurse -Force }
    $contents = Join-Path $stage 'Essential Sampler.vst3/Contents'
    $binaryDir = Join-Path $contents 'x86_64-win'
    $licenses = Join-Path $contents 'Resources/Licenses'
    New-Item -ItemType Directory -Force -Path $binaryDir, $licenses, (Join-Path $stage 'docs'), 'releases' | Out-Null
    Copy-Item -LiteralPath (Join-Path $build 'Essential Sampler.vst3') -Destination $binaryDir
    Copy-Item -LiteralPath 'LICENSE' -Destination (Join-Path $licenses 'EssentialSampler-MIT.txt')
    Copy-Item -LiteralPath 'third_party/pluginterfaces/LICENSE.txt' -Destination (Join-Path $licenses 'VST3.txt')
    Copy-Item -LiteralPath 'third_party/dr_libs/LICENSE' -Destination (Join-Path $licenses 'dr_libs.txt')
    $module = @{
        Name = 'Essential Sampler'; Version = $version
        'Factory Info' = @{ Vendor = 'hasio'; URL = ''; 'E-Mail' = ''; Flags = @{ Unicode = $true; 'Classes Discardable' = $false; 'Component Non Discardable' = $false } }
        Classes = @(@{ CID = '484153494F4C4F4F5056535433000001'; Category = 'Audio Module Class'; Name = 'Essential Sampler'; Vendor = 'hasio'; Version = $version; SDKVersion = 'VST 3.8.0'; 'Sub Categories' = @('Instrument','Sampler'); 'Class Flags' = 0; Cardinality = 2147483647 })
    }
    $module | ConvertTo-Json -Depth 8 | Set-Content -Encoding UTF8 (Join-Path $contents 'Resources/moduleinfo.json')
    Copy-Item -LiteralPath 'README.md','CHANGELOG.md','LICENSE','THIRD_PARTY_NOTICES.md' -Destination $stage
    Copy-Item -LiteralPath 'docs/USAGE.md','docs/DEVELOPMENT.md','docs/VERIFICATION.md','docs/preview.png','docs/fx-preview.png' -Destination (Join-Path $stage 'docs')
    Copy-Item -LiteralPath 'scripts/install-windows.cmd' -Destination (Join-Path $stage 'Install.cmd')
    Copy-Item -LiteralPath 'scripts/install-windows.ps1' -Destination (Join-Path $stage 'Install.ps1')
    $hashes = @{}
    $relative = 'Essential Sampler.vst3/Contents/x86_64-win/Essential Sampler.vst3'
    $hashes[$relative] = (Get-FileHash -LiteralPath (Join-Path $stage $relative) -Algorithm SHA256).Hash
    if ($format -eq 'all') {
        Copy-Item -LiteralPath (Join-Path $build 'Essential Sampler.exe') -Destination $stage
        Copy-Item -LiteralPath $licenses -Destination (Join-Path $stage 'Licenses') -Recurse
        $hashes['Essential Sampler.exe'] = (Get-FileHash -LiteralPath (Join-Path $stage 'Essential Sampler.exe') -Algorithm SHA256).Hash
    }
    $hashes | ConvertTo-Json | Set-Content -Encoding UTF8 (Join-Path $stage 'checksums.json')
    Compress-Archive -LiteralPath $stage -DestinationPath "releases/$name.zip" -Force
    Write-Host "Packaged releases/$name.zip"
}
