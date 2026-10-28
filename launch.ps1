$ErrorActionPreference = 'Stop'
$appDirectory = $PSScriptRoot
$runtime = Join-Path $appDirectory 'runtime\pythonw.exe'
$serverFile = Join-Path $appDirectory 'server.py'
$prefixArguments = @()
if (-not (Test-Path -LiteralPath $runtime)) {
    $pythonCommand = Get-Command pythonw.exe, python.exe, py.exe -ErrorAction SilentlyContinue | Select-Object -First 1
    if (-not $pythonCommand) {
        throw 'Please install Python 3.12+ or download the complete Windows portable release.'
    }
    $runtime = $pythonCommand.Source
    if ($pythonCommand.Name -eq 'py.exe') { $prefixArguments = @('-3') }
}
Start-Process -FilePath $runtime -ArgumentList ($prefixArguments + @('-X', 'utf8', ('"' + $serverFile + '"'), '--open')) -WorkingDirectory $appDirectory -WindowStyle Hidden
