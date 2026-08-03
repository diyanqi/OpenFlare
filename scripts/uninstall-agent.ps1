[CmdletBinding()]
param(
    [string]$InstallDir = (Join-Path $env:ProgramFiles 'OpenFlare\Agent'),
    [switch]$KeepData
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
$serviceName = 'OpenFlareAgent'

$identity = [Security.Principal.WindowsIdentity]::GetCurrent()
$principal = New-Object Security.Principal.WindowsPrincipal($identity)
if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    throw 'Please run PowerShell as Administrator.'
}

$service = Get-Service -Name $serviceName -ErrorAction SilentlyContinue
if ($null -ne $service) {
    if ($service.Status -ne 'Stopped') {
        Stop-Service -Name $serviceName -Force
        $service.WaitForStatus('Stopped', [TimeSpan]::FromSeconds(30))
    }
    & sc.exe delete $serviceName | Out-Null
    if ($LASTEXITCODE -ne 0) {
        throw "Failed to remove service: $serviceName"
    }
}

if (Test-Path -LiteralPath $InstallDir) {
    if ($KeepData) {
        Get-ChildItem -LiteralPath $InstallDir -Force | Where-Object { $_.Name -ne 'data' } | Remove-Item -Recurse -Force
        Write-Host "OpenFlare Agent removed; data kept at $(Join-Path $InstallDir 'data')."
    }
    else {
        Remove-Item -LiteralPath $InstallDir -Recurse -Force
        Write-Host 'OpenFlare Agent and its local data were removed.'
    }
}
