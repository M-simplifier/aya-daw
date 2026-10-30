function Initialize-AyaEncoding {
  [Console]::InputEncoding = [System.Text.UTF8Encoding]::new($false)
  [Console]::OutputEncoding = [System.Text.UTF8Encoding]::new($false)
  $env:GHC_CHARENC = 'UTF-8'
  $env:LANG = 'C.UTF-8'
}

function Get-AyaToolchain {
  $ayaCabalCommand = Get-Command cabal.exe -ErrorAction Stop
  $ayaGhcCommand = Get-Command ghc.exe -ErrorAction Stop
  $ayaLibDir = (& $ayaGhcCommand.Source --print-libdir | Select-Object -Last 1).Trim()
  if ($LASTEXITCODE -ne 0) { throw 'Could not query the GHC library directory.' }
  $ayaGhcRoot = Split-Path $ayaLibDir -Parent
  $ayaMingw = Join-Path $ayaGhcRoot 'mingw\bin'
  $ayaPaths = & $ayaCabalCommand.Source path --output-format=json | ConvertFrom-Json
  if ($LASTEXITCODE -ne 0) { throw 'Could not query Cabal paths.' }
  [pscustomobject]@{
    Cabal = $ayaCabalCommand.Source
    Ghc = $ayaGhcCommand.Source
    GhcLibDir = $ayaLibDir
    GhcRoot = $ayaGhcRoot
    MingwBin = $ayaMingw
    Inspector = Join-Path $ayaMingw 'llvm-readobj.exe'
    Strip = Join-Path $ayaMingw 'llvm-strip.exe'
    Nm = Join-Path $ayaMingw 'llvm-nm.exe'
    Cache = $ayaPaths.'remote-repo-cache'
  }
}
