$ErrorActionPreference = 'Stop'
$ayaRoot = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
$ayaEndpointPath = Join-Path $ayaRoot '.work\endpoint.json'
if (Test-Path -LiteralPath $ayaEndpointPath) {
  try {
    $ayaEndpoint = Get-Content -LiteralPath $ayaEndpointPath -Raw -Encoding UTF8 | ConvertFrom-Json
    if ($ayaEndpoint.url -match '^http://127\.0\.0\.1:[0-9]{1,5}$') {
      Invoke-RestMethod -Uri ($ayaEndpoint.url + '/api/shutdown') -Method Post -ContentType 'application/json' -Body '{}' -TimeoutSec 5 | Out-Null
    }
  } catch { }
}
