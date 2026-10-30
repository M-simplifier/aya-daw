param([switch]$Tests, [switch]$Release, [string]$OutputDirectory)
$ErrorActionPreference = 'Stop'
$ayaRoot = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
Set-Location -LiteralPath $ayaRoot
. (Join-Path $PSScriptRoot 'toolchain.ps1')
Initialize-AyaEncoding
$ayaTools = Get-AyaToolchain
$ayaCabalArguments = @('--disable-response-files','--ar-options=--rsp-quoting=posix')
$ayaPreviousPath = $env:PATH
$ayaRuntime = $null
if ($Release) {
  if ((& $ayaTools.Ghc --numeric-version).Trim() -ne '9.14.1') { throw 'This release recipe is audited with GHC 9.14.1. Use that version or re-audit the runtime closure.' }
  $ayaRuntime = & (Join-Path $PSScriptRoot 'prepare-release-runtime.ps1') -Root $ayaRoot
  $ayaProject = Join-Path $ayaRuntime.Root 'release.project'
  $ayaPackages = 'packages: "' + $ayaRoot.Replace('\','/') + '" "' + (Join-Path $ayaRoot 'audio').Replace('\','/') + '"'
  $ayaConfiguration = Get-Content -LiteralPath (Join-Path $ayaRoot 'cabal.project') -Raw -Encoding UTF8
  $ayaConfiguration = [regex]::Replace($ayaConfiguration,'(?m)^packages:.*$',$ayaPackages)
  $ayaFreeze = Join-Path $ayaRoot 'cabal.project.freeze'
  if (Test-Path -LiteralPath $ayaFreeze) { $ayaConfiguration += "`n" + (Get-Content -LiteralPath $ayaFreeze -Raw -Encoding UTF8) }
  $ayaLink = '-optl-Wl,--whole-archive "-optl' + $ayaRuntime.ImportLibrary.Replace('\','/') + '" -optl-Wl,--no-whole-archive'
  $ayaConfiguration += "`npackage aya`n  ghc-options: $ayaLink`npackage aya-audio`n  ghc-options: $ayaLink`n"
  [System.IO.File]::WriteAllText($ayaProject,$ayaConfiguration,[System.Text.UTF8Encoding]::new($false))
  $ayaBuildDirectory = Join-Path $ayaRoot '.work\release-build'
  $ayaCabalArguments += @('--project-file=.work/runtime/release.project',"--builddir=$ayaBuildDirectory")
  $env:PATH = (Split-Path $ayaRuntime.Dll -Parent) + ';' + $env:PATH
}
if (-not $OutputDirectory) { $OutputDirectory = if ($Release) { '.work\release-bin' } else { '.work\bin' } }
$ayaOutput = [System.IO.Path]::GetFullPath((Join-Path $ayaRoot $OutputDirectory))
try {
  & $ayaTools.Cabal build exe:aya @ayaCabalArguments -j2
  if ($LASTEXITCODE -ne 0) { throw 'Aya build failed.' }
  if ($Tests) {
    & $ayaTools.Cabal test model-tests aya-audio:audio-tests @ayaCabalArguments --test-show-details=direct
    if ($LASTEXITCODE -ne 0) { throw 'Musical model or audio tests failed.' }
  }
  $ayaQueryArguments = @($ayaCabalArguments | Where-Object { $_ -notlike '--disable-response-files' -and $_ -notlike '--ar-options=*' })
  $ayaBinary = (& $ayaTools.Cabal list-bin exe:aya @ayaQueryArguments | Select-Object -Last 1).Trim()
  if ($LASTEXITCODE -ne 0) { throw 'Could not locate the built Aya executable.' }
  New-Item -ItemType Directory -Path $ayaOutput -Force | Out-Null
  Copy-Item -LiteralPath $ayaBinary -Destination (Join-Path $ayaOutput 'aya.exe') -Force
  if ($Release) {
    Copy-Item -LiteralPath $ayaRuntime.Dll -Destination $ayaOutput -Force
    & $ayaTools.Strip --strip-debug (Join-Path $ayaOutput 'aya.exe')
    if ($LASTEXITCODE -ne 0) { throw 'Could not remove build-machine debug paths from release executable.' }
    $ayaImports = & $ayaTools.Inspector --coff-imports (Join-Path $ayaOutput 'aya.exe')
    if (-not ($ayaImports -match 'Name: libgmp-10\.dll')) { throw 'Release executable does not import replaceable GMP.' }
  }
  Write-Output (Join-Path $ayaOutput 'aya.exe')
} finally { $env:PATH = $ayaPreviousPath }
