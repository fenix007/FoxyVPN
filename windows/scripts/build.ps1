param([ValidateSet('x64', 'arm64')][string]$Architecture = 'x64')
$ErrorActionPreference = 'Stop'
$WindowsRoot = Split-Path $PSScriptRoot -Parent
$RepositoryRoot = Split-Path $WindowsRoot -Parent
$GoArch = if ($Architecture -eq 'x64') { 'amd64' } else { 'arm64' }
$Output = Join-Path $WindowsRoot "dist/FoxyVPN-win-$Architecture"
Push-Location $WindowsRoot
try {
    python (Join-Path $PSScriptRoot 'prepare-backends.py') --arch $GoArch
    if ($LASTEXITCODE -ne 0) { throw 'Backend build failed' }
    dotnet run --project FoxyVPN.Tests -c Release
    if ($LASTEXITCODE -ne 0) { throw 'Core checks failed' }
    dotnet publish FoxyVPN/FoxyVPN.csproj -c Release -r "win-$Architecture" --self-contained true -p:PublishSingleFile=true -p:IncludeNativeLibrariesForSelfExtract=true -o $Output
    if ($LASTEXITCODE -ne 0) { throw 'Windows app build failed' }
    Copy-Item (Join-Path $WindowsRoot ".build/backends/$GoArch/*.exe") $Output
    Copy-Item (Join-Path $WindowsRoot 'README.md') $Output
    Copy-Item (Join-Path $WindowsRoot 'THIRD_PARTY.md') $Output
    Copy-Item (Join-Path $RepositoryRoot 'LICENSE') $Output
    Get-ChildItem $Output -Include *.pdb,*.xml -Recurse | Remove-Item
    if ($IsWindows -or $env:OS -eq 'Windows_NT') {
        $process = Start-Process -FilePath (Join-Path $Output 'FoxyVPN.exe') -ArgumentList '--self-test' -Wait -PassThru
        if ($process.ExitCode -ne 0) { throw 'Windows backend self-test failed' }
    }
    $Archive = Join-Path $WindowsRoot "dist/FoxyVPN-win-$Architecture.zip"
    Compress-Archive -Path "$Output/*" -DestinationPath $Archive -Force
    $Checksum = Get-FileHash $Archive -Algorithm SHA256
    $ChecksumLine = $Checksum.Hash.ToLowerInvariant() + '  ' + (Split-Path $Archive -Leaf) + "`n"
    [System.IO.File]::WriteAllText("$Archive.sha256", $ChecksumLine, [System.Text.Encoding]::ASCII)
    $Checksum
    Write-Host "Built $Archive"
} finally { Pop-Location }
