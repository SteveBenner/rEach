param(
    [Parameter(Mandatory = $true)]
    [string]$Url,

    [Parameter(Mandatory = $true)]
    [string]$Token,

    [Parameter(Mandatory = $true)]
    [ValidateSet('win10', 'win11')]
    [string]$Label,

    [Parameter(Mandatory = $true)]
    [string]$Name
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 2.0

$RunnerDir = 'C:\actions-runner'
$config = Join-Path $RunnerDir 'config.cmd'

try {
    if (-not (Test-Path -LiteralPath $config)) {
        throw ('config.cmd was not found in ' + $RunnerDir + '; run bootstrap.ps1 first')
    }
    Push-Location $RunnerDir
    try {
        & $config --unattended --url $Url --token $Token --labels $Label --name $Name --runasservice --replace
        if ($LASTEXITCODE -ne 0) {
            throw ('config.cmd exited ' + $LASTEXITCODE)
        }
    } finally {
        Pop-Location
    }
    Write-Host ('register: runner ' + $Name + ' registered with label ' + $Label)
    exit 0
} catch {
    Write-Host ('register: FAILED: ' + $_.Exception.Message)
    exit 1
}
