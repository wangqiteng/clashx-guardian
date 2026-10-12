param([ValidateSet('win-x64','win-arm64')][string]$Runtime = 'win-x64')
$ErrorActionPreference = 'Stop'
$projectRoot = Split-Path $PSScriptRoot -Parent
$version = '0.1.4'
$temporaryRoot = Join-Path ([IO.Path]::GetTempPath()) ('ikuuu-guardian-' + [guid]::NewGuid())
$packageDirectory = Join-Path $temporaryRoot "IKuuu-Guardian-$version-$Runtime"
try {
    dotnet run --project "$PSScriptRoot/Guardian.Tests/Guardian.Tests.csproj" -c Release
    if ($LASTEXITCODE -ne 0) { throw 'Tests failed' }
    dotnet publish "$PSScriptRoot/Guardian.Windows/Guardian.Windows.csproj" -c Release -r $Runtime --self-contained true '-p:PublishSingleFile=true' '-p:IncludeNativeLibrariesForSelfExtract=true' '-p:DebugType=None' '-p:DebugSymbols=false' -o $packageDirectory
    if ($LASTEXITCODE -ne 0) { throw 'Publish failed' }
    Copy-Item "$PSScriptRoot/README.md" "$packageDirectory/README.md"
    $outputDirectory = Join-Path $projectRoot 'outputs'
    New-Item -ItemType Directory -Path $outputDirectory -Force | Out-Null
    $archive = Join-Path $outputDirectory "IKuuu-Guardian-v$version-$Runtime.zip"
    Compress-Archive -Path $packageDirectory -DestinationPath $archive -Force
    $hash = (Get-FileHash $archive -Algorithm SHA256).Hash.ToLowerInvariant()
    Set-Content -Path "$archive.sha256" -Value "$hash  $([IO.Path]::GetFileName($archive))" -Encoding ASCII
    Write-Output $archive
} finally {
    if (Test-Path $temporaryRoot) { Remove-Item -LiteralPath $temporaryRoot -Recurse -Force }
}
