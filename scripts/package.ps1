param([switch]$SkipBuild, [string]$Binary)
$ErrorActionPreference = 'Stop'
$ayaRoot = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
Set-Location -LiteralPath $ayaRoot
. (Join-Path $PSScriptRoot 'toolchain.ps1')
Initialize-AyaEncoding
$ayaTools = Get-AyaToolchain
if (-not $SkipBuild) { & (Join-Path $PSScriptRoot 'build.ps1') -Release -Tests }
$ayaRuntime = & (Join-Path $PSScriptRoot 'prepare-release-runtime.ps1') -Root $ayaRoot
$ayaBinarySource = if ($Binary) { [System.IO.Path]::GetFullPath($Binary) } else { Join-Path $ayaRoot '.work\release-bin\aya.exe' }
$ayaGmpSource = Join-Path (Split-Path $ayaBinarySource -Parent) 'libgmp-10.dll'
if (-not (Test-Path -LiteralPath $ayaGmpSource)) { throw 'Use a -Release build; replaceable GMP DLL is missing beside the executable.' }
if ((Get-FileHash -LiteralPath $ayaGmpSource -Algorithm SHA256).Hash -ne (Get-FileHash -LiteralPath $ayaRuntime.Dll -Algorithm SHA256).Hash) {
  throw 'Release GMP DLL differs from the pinned corresponding-source runtime.'
}
$ayaAuditText = & python (Join-Path $PSScriptRoot 'audit-pe.py') $ayaBinarySource --nm $ayaTools.Nm
if ($LASTEXITCODE -ne 0) { throw 'The binary did not pass replaceable-GMP auditing.' }
$ayaAudit = ($ayaAuditText -join "`n") | ConvertFrom-Json
$ayaStage = Join-Path $ayaRoot 'dist\Aya'
if ((Test-Path -LiteralPath (Join-Path $ayaStage '.work')) -or (Test-Path -LiteralPath (Join-Path $ayaStage 'node_modules'))) {
  throw 'Distribution folder contains runtime state. Use a fresh dist/Aya directory.'
}
if (Test-Path -LiteralPath $ayaStage) {
  $ayaResolved = (Resolve-Path -LiteralPath $ayaStage).ProviderPath
  $ayaExpected = [System.IO.Path]::GetFullPath((Join-Path $ayaRoot 'dist\Aya'))
  if ($ayaResolved -ne $ayaExpected -or -not $ayaResolved.StartsWith($ayaRoot+[System.IO.Path]::DirectorySeparatorChar)) {
    throw 'Distribution cleanup target is outside this project.'
  }
  if ((Get-Item -LiteralPath $ayaStage).Attributes -band [System.IO.FileAttributes]::ReparsePoint) { throw 'Refusing to clean a linked distribution folder.' }
  Remove-Item -LiteralPath $ayaResolved -Recurse -Force
}
New-Item -ItemType Directory -Path $ayaStage -Force | Out-Null
foreach ($ayaFolder in @('web','examples','scripts','docs','licenses','third-party\sources')) { New-Item -ItemType Directory -Path (Join-Path $ayaStage $ayaFolder) -Force | Out-Null }
Copy-Item -LiteralPath $ayaBinarySource -Destination (Join-Path $ayaStage 'aya.exe') -Force
Copy-Item -LiteralPath $ayaGmpSource -Destination $ayaStage -Force
foreach ($ayaName in @('Launch.cmd','Close.cmd','README.md','README.ja.md','LICENSE','THIRD-PARTY.md')) { Copy-Item -LiteralPath (Join-Path $ayaRoot $ayaName) -Destination $ayaStage -Force }
foreach ($ayaFolder in @('web','examples')) { Get-ChildItem -LiteralPath (Join-Path $ayaRoot $ayaFolder) -File -Recurse | Where-Object { $ayaFolder -ne 'examples' -or $_.Extension -eq '.json' } | ForEach-Object {
  $ayaRelative = $_.FullName.Substring((Join-Path $ayaRoot $ayaFolder).Length + 1)
  $ayaTarget = Join-Path (Join-Path $ayaStage $ayaFolder) $ayaRelative
  New-Item -ItemType Directory -Path (Split-Path $ayaTarget -Parent) -Force | Out-Null
  Copy-Item -LiteralPath $_.FullName -Destination $ayaTarget -Force
} }
foreach ($ayaName in @('launch.ps1','stop.ps1')) { Copy-Item -LiteralPath (Join-Path $PSScriptRoot $ayaName) -Destination (Join-Path $ayaStage 'scripts') -Force }
Get-ChildItem -LiteralPath (Join-Path $ayaRoot 'docs') -File -Filter 'audio-*.md' | Copy-Item -Destination (Join-Path $ayaStage 'docs') -Force
Get-ChildItem -LiteralPath (Join-Path $ayaRoot 'docs') -File -Filter 'developer-guide.*.md' | Copy-Item -Destination (Join-Path $ayaStage 'docs') -Force
Copy-Item -LiteralPath (Join-Path $ayaRoot 'docs\INTERFACES.md') -Destination (Join-Path $ayaStage 'docs') -Force
foreach ($ayaName in @('runtime-lock.json','GMP-REPLACEMENT.md')) { Copy-Item -LiteralPath (Join-Path $ayaRoot ('third-party\'+$ayaName)) -Destination (Join-Path $ayaStage 'third-party') -Force }
Copy-Item -LiteralPath $ayaRuntime.Source -Destination (Join-Path $ayaStage 'third-party\sources') -Force
$ayaPending = [System.Collections.Generic.Queue[string]]::new()
$ayaSeen = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
$ayaPending.Enqueue((Join-Path $ayaStage 'aya.exe'))
while ($ayaPending.Count -gt 0) {
  $ayaFile = $ayaPending.Dequeue()
  $ayaImports = & $ayaTools.Inspector --coff-imports $ayaFile
  if ($LASTEXITCODE -ne 0) { throw ('Could not inspect runtime imports: '+$ayaFile) }
  foreach ($ayaLine in $ayaImports) {
    if ($ayaLine -match '^\s+Name: (.+\.dll)$') {
      $ayaDll = $Matches[1]
      if (-not $ayaSeen.Add($ayaDll)) { continue }
      if ((Test-Path -LiteralPath (Join-Path $env:SystemRoot ('System32\' + $ayaDll))) -or $ayaDll -like 'api-ms-win-*' -or $ayaDll -like 'ext-ms-*') { continue }
      $ayaSource = @((Join-Path (Split-Path $ayaBinarySource -Parent) $ayaDll),(Join-Path $ayaTools.MingwBin $ayaDll),(Join-Path $ayaTools.GhcRoot ('bin\' + $ayaDll))) | Where-Object { Test-Path -LiteralPath $_ } | Select-Object -First 1
      if (-not $ayaSource) { throw ('Missing runtime DLL: ' + $ayaDll) }
      $ayaTarget = Join-Path $ayaStage $ayaDll
      Copy-Item -LiteralPath $ayaSource -Destination $ayaTarget -Force
      $ayaPending.Enqueue($ayaTarget)
    }
  }
}
& python (Join-Path $PSScriptRoot 'package-licenses.py') (Join-Path $ayaStage 'licenses') --plan (Join-Path $ayaRoot '.work\release-build\cache\plan.json') --cache $ayaTools.Cache --ghc-libdir $ayaTools.GhcLibDir
if ($LASTEXITCODE -ne 0) { throw 'Could not collect dependency notices.' }
$ayaCommit = 'source-archive'
if (Get-Command git -ErrorAction SilentlyContinue) {
  $ayaCommit = & git rev-parse HEAD 2>$null
  if ($LASTEXITCODE -ne 0) { $ayaCommit = 'uncommitted' }
}
$ayaBuildInfo = [ordered]@{version='0.1.0';packageVersion='0.1.0.0';source='https://github.com/M-simplifier/aya-daw';commit=([string]$ayaCommit).Trim();compiler=(& $ayaTools.Ghc --numeric-version).Trim();binaryAudit=$ayaAudit;gmp=$ayaRuntime.Lock.gmp}
[System.IO.File]::WriteAllText((Join-Path $ayaStage 'BUILD-INFO.json'),($ayaBuildInfo | ConvertTo-Json -Depth 8),[System.Text.UTF8Encoding]::new($false))
$ayaZip = Join-Path $ayaRoot 'dist\Aya-Windows-x64.zip'
Compress-Archive -LiteralPath $ayaStage -DestinationPath $ayaZip -Force
$ayaChecksums = @()
foreach ($ayaAsset in @($ayaZip,(Join-Path $ayaRoot 'examples\Glass-Tides.wav'),(Join-Path $ayaRoot 'examples\glass-tides.aya.json'))) {
  $ayaChecksums += ((Get-FileHash -LiteralPath $ayaAsset -Algorithm SHA256).Hash.ToLowerInvariant()+'  '+(Split-Path $ayaAsset -Leaf))
}
[System.IO.File]::WriteAllText((Join-Path $ayaRoot 'dist\SHA256SUMS.txt'),($ayaChecksums -join "`n")+"`n",[System.Text.UTF8Encoding]::new($false))
[pscustomobject]@{Path=$ayaZip;Bytes=(Get-Item -LiteralPath $ayaZip).Length;SHA256=(Get-FileHash -LiteralPath $ayaZip -Algorithm SHA256).Hash;GmpThunks=$ayaAudit.gmpFunctionThunks;SourceCommit=$ayaBuildInfo.commit}
