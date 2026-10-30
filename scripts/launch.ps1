$ErrorActionPreference = 'Stop'
$ayaRoot = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
Set-Location -LiteralPath $ayaRoot
New-Item -ItemType Directory -Path (Join-Path $ayaRoot '.work') -Force | Out-Null
$ayaEndpointPath = Join-Path $ayaRoot '.work\endpoint.json'
function Read-AyaUrl {
  if (Test-Path -LiteralPath $ayaEndpointPath) {
    try {
      $ayaValue = Get-Content -LiteralPath $ayaEndpointPath -Raw -Encoding UTF8 | ConvertFrom-Json
      if ($ayaValue.url -match '^http://127\.0\.0\.1:[0-9]{1,5}$') {
        $ayaHealth = Invoke-RestMethod -Uri ($ayaValue.url + '/api/status') -TimeoutSec 2
        if ($null -ne $ayaHealth.engine) { return $ayaValue.url }
      }
    } catch { }
  }
  return $null
}
try {
  $ayaUrl = Read-AyaUrl
  if ($ayaUrl) { Start-Process $ayaUrl; exit 0 }
  $ayaBinary = Join-Path $ayaRoot 'aya.exe'
  if (-not (Test-Path -LiteralPath $ayaBinary)) { $ayaBinary = Join-Path $ayaRoot '.work\bin\aya.exe' }
  if (-not (Test-Path -LiteralPath $ayaBinary)) {
    & (Join-Path $PSScriptRoot 'build.ps1') *> (Join-Path $ayaRoot '.work\build.log')
    if (-not (Test-Path -LiteralPath $ayaBinary)) { throw 'Aya could not be built. See .work\build.log.' }
  }
  if (Test-Path -LiteralPath $ayaEndpointPath) { Remove-Item -LiteralPath $ayaEndpointPath -Force }
  $ayaArguments = @('--root', ('"' + $ayaRoot + '"'))
  $ayaProcess = Start-Process -FilePath $ayaBinary -ArgumentList $ayaArguments -WorkingDirectory $ayaRoot -WindowStyle Hidden -PassThru `
    -RedirectStandardOutput (Join-Path $ayaRoot '.work\server.stdout.log') -RedirectStandardError (Join-Path $ayaRoot '.work\server.stderr.log')
  for ($ayaAttempt = 0; $ayaAttempt -lt 80; $ayaAttempt++) {
    Start-Sleep -Milliseconds 250
    $ayaUrl = Read-AyaUrl
    if ($ayaUrl) { Start-Process $ayaUrl; exit 0 }
    if ($ayaProcess.HasExited) { throw 'Aya stopped during startup. See .work\server.stderr.log.' }
  }
  throw 'Aya did not respond. See .work\server.stderr.log.'
} catch {
  Add-Type -AssemblyName PresentationFramework
  [System.Windows.MessageBox]::Show($_.Exception.Message, 'Aya') | Out-Null
  exit 1
}
