param([string]$Root)
$ErrorActionPreference = 'Stop'
if (-not $Root) { $Root = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..')) }
$ayaLock = Get-Content -LiteralPath (Join-Path $Root 'third-party\runtime-lock.json') -Raw -Encoding UTF8 | ConvertFrom-Json
$ayaRuntime = Join-Path $Root '.work\runtime'
$ayaArchive = Join-Path $ayaRuntime 'gmp.pkg.tar.zst'
$ayaExtracted = Join-Path $ayaRuntime 'gmp'
$ayaSource = Join-Path $Root ('third-party\' + $ayaLock.gmp.sourceFile.Replace('/','\'))
$ayaBundledBinary = Join-Path $Root ('third-party\' + $ayaLock.gmp.binaryFile.Replace('/','\'))
New-Item -ItemType Directory -Path $ayaRuntime,$ayaExtracted -Force | Out-Null
if ((Get-FileHash -LiteralPath $ayaSource -Algorithm SHA256).Hash -ne $ayaLock.gmp.sourceSha256) {
  throw 'The committed GMP corresponding source archive does not match runtime-lock.json.'
}
if ((Get-FileHash -LiteralPath $ayaBundledBinary -Algorithm SHA256).Hash -ne $ayaLock.gmp.binarySha256) {
  throw 'The committed original GMP binary package does not match runtime-lock.json.'
}
if (-not (Test-Path -LiteralPath $ayaArchive)) {
  Copy-Item -LiteralPath $ayaBundledBinary -Destination $ayaArchive
}
if ((Get-FileHash -LiteralPath $ayaArchive -Algorithm SHA256).Hash -ne $ayaLock.gmp.binarySha256) {
  throw 'GMP runtime checksum mismatch. Remove .work/runtime/gmp.pkg.tar.zst before retrying.'
}
$ayaTar = (Get-Command tar.exe -ErrorAction Stop).Source
$ayaMembers = & $ayaTar -tf $ayaArchive
if ($LASTEXITCODE -ne 0) { throw 'Could not inspect the GMP runtime archive.' }
foreach ($ayaMember in $ayaMembers) {
  if ($ayaMember -match '(^[/\\])|(^|[/\\])\.\.([/\\]|$)|:') { throw 'Unsafe path in GMP archive.' }
}
& $ayaTar -xf $ayaArchive -C $ayaExtracted
if ($LASTEXITCODE -ne 0) { throw 'Could not extract the verified GMP runtime.' }
$ayaDll = Join-Path $ayaExtracted $ayaLock.gmp.dll.Replace('/','\')
$ayaImport = Join-Path $ayaExtracted $ayaLock.gmp.importLibrary.Replace('/','\')
if (-not (Test-Path -LiteralPath $ayaDll) -or -not (Test-Path -LiteralPath $ayaImport)) { throw 'GMP runtime files are missing.' }
[pscustomobject]@{ Dll=$ayaDll; ImportLibrary=$ayaImport; Source=$ayaSource; Root=$ayaRuntime; Lock=$ayaLock }
