[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$ServerUrl,
    [string]$AgentToken,
    [string]$DiscoveryToken,
    [string]$InstallDir = (Join-Path $env:ProgramFiles 'OpenFlare\Agent'),
    [string]$OpenRestyPath,
    [string]$Repo = 'Rain-kl/OpenFlare',
    [string]$Version,
    [switch]$NoService,
    [switch]$SkipOpenRestyCheck
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$serviceName = 'OpenFlareAgent'
$binaryName = 'openflare-agent.exe'
$downloadRoot = Join-Path $env:TEMP ('openflare-agent-' + [guid]::NewGuid().ToString('N'))

function Assert-Administrator {
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = New-Object Security.Principal.WindowsPrincipal($identity)
    if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
        throw 'Please run PowerShell as Administrator.'
    }
}

function Get-AgentArchitecture {
    $architecture = $env:PROCESSOR_ARCHITEW6432
    if ([string]::IsNullOrWhiteSpace($architecture)) {
        $architecture = $env:PROCESSOR_ARCHITECTURE
    }
    switch ($architecture.ToUpperInvariant()) {
        'AMD64' { return 'amd64' }
        'ARM64' { return 'arm64' }
        default { throw "Unsupported Windows architecture: $architecture" }
    }
}

function Resolve-OpenRestyPath {
    param([string]$ConfiguredPath)

    if (-not [string]::IsNullOrWhiteSpace($ConfiguredPath)) {
        if (Test-Path -LiteralPath $ConfiguredPath -PathType Leaf) {
            return (Resolve-Path -LiteralPath $ConfiguredPath).Path
        }
        $command = Get-Command $ConfiguredPath -ErrorAction SilentlyContinue
        if ($null -ne $command) {
            return $command.Source
        }
        throw "OpenResty executable was not found: $ConfiguredPath"
    }

    foreach ($candidate in @('openresty.exe', 'openresty', 'nginx.exe', 'nginx')) {
        $command = Get-Command $candidate -ErrorAction SilentlyContinue
        if ($null -ne $command) {
            return $command.Source
        }
    }
    if ($SkipOpenRestyCheck) {
        return 'openresty.exe'
    }
    throw 'OpenResty was not found in PATH. Install it or pass -OpenRestyPath.'
}

function Get-Release {
    param([string]$Repository, [string]$ReleaseVersion)

    $encodedRepository = $Repository.Trim()
    if ([string]::IsNullOrWhiteSpace($ReleaseVersion)) {
        $uri = "https://api.github.com/repos/$encodedRepository/releases/latest"
    }
    else {
        $encodedVersion = [uri]::EscapeDataString($ReleaseVersion.Trim())
        $uri = "https://api.github.com/repos/$encodedRepository/releases/tags/$encodedVersion"
    }
    return Invoke-RestMethod -Uri $uri -Headers @{ Accept = 'application/vnd.github+json' }
}

function Set-RestrictedAcl {
    param([string]$Path, [switch]$Directory)

    if ($Directory) {
        & icacls.exe $Path /inheritance:r /grant:r '*S-1-5-18:(OI)(CI)F' '*S-1-5-32-544:(OI)(CI)F' | Out-Null
    }
    else {
        & icacls.exe $Path /inheritance:r /grant:r '*S-1-5-18:F' '*S-1-5-32-544:F' | Out-Null
    }
    if ($LASTEXITCODE -ne 0) {
        throw "Failed to restrict ACL: $Path"
    }
}

function Remove-AgentService {
    $service = Get-Service -Name $serviceName -ErrorAction SilentlyContinue
    if ($null -eq $service) {
        return
    }
    if ($service.Status -ne 'Stopped') {
        Stop-Service -Name $serviceName -Force -ErrorAction SilentlyContinue
        $service.WaitForStatus('Stopped', [TimeSpan]::FromSeconds(30))
    }
    & sc.exe delete $serviceName | Out-Null
    if ($LASTEXITCODE -ne 0) {
        throw "Failed to remove service: $serviceName"
    }
    Start-Sleep -Milliseconds 500
}

try {
    Assert-Administrator
    if ($env:OS -ne 'Windows_NT') {
        throw 'This installer only supports Windows.'
    }
    if ([string]::IsNullOrWhiteSpace($AgentToken) -and [string]::IsNullOrWhiteSpace($DiscoveryToken)) {
        throw 'Pass either -AgentToken or -DiscoveryToken.'
    }
    if (-not [string]::IsNullOrWhiteSpace($AgentToken) -and -not [string]::IsNullOrWhiteSpace($DiscoveryToken)) {
        throw 'Pass only one of -AgentToken and -DiscoveryToken.'
    }

    $resolvedOpenRestyPath = Resolve-OpenRestyPath $OpenRestyPath
    $architecture = Get-AgentArchitecture
    $release = Get-Release $Repo $Version
    $assetName = "openflare-agent-windows-$architecture.exe"
    $asset = @($release.assets | Where-Object { $_.name -eq $assetName }) | Select-Object -First 1
    $checksumAsset = @($release.assets | Where-Object { $_.name -eq "$assetName.sha256" }) | Select-Object -First 1
    if ($null -eq $asset -or [string]::IsNullOrWhiteSpace($asset.browser_download_url)) {
        throw "Release $($release.tag_name) does not contain $assetName."
    }
    if ($null -eq $checksumAsset -or [string]::IsNullOrWhiteSpace($checksumAsset.browser_download_url)) {
        throw "Release $($release.tag_name) does not contain $assetName.sha256."
    }

    New-Item -ItemType Directory -Path $downloadRoot -Force | Out-Null
    $downloadedBinary = Join-Path $downloadRoot $binaryName
    $downloadedChecksum = Join-Path $downloadRoot "$binaryName.sha256"
    Invoke-WebRequest -UseBasicParsing -Uri $asset.browser_download_url -OutFile $downloadedBinary
    Invoke-WebRequest -UseBasicParsing -Uri $checksumAsset.browser_download_url -OutFile $downloadedChecksum
    $expectedHash = (Get-Content -LiteralPath $downloadedChecksum -Raw).Trim().Split()[0].ToLowerInvariant()
    $actualHash = (Get-FileHash -Algorithm SHA256 -LiteralPath $downloadedBinary).Hash.ToLowerInvariant()
    if ($expectedHash -ne $actualHash) {
        throw "SHA-256 mismatch for $assetName."
    }

    New-Item -ItemType Directory -Path $InstallDir -Force | Out-Null
    $dataDir = Join-Path $InstallDir 'data'
    New-Item -ItemType Directory -Path $dataDir -Force | Out-Null
    $configPath = Join-Path $InstallDir 'agent.json'
    $binaryPath = Join-Path $InstallDir $binaryName
    $existing = $null
    if (Test-Path -LiteralPath $configPath -PathType Leaf) {
        $existing = Get-Content -LiteralPath $configPath -Raw | ConvertFrom-Json
    }

    $configuration = [ordered]@{
        server_url = $ServerUrl.TrimEnd('/')
        data_dir = $dataDir
        openresty_path = $resolvedOpenRestyPath
        heartbeat_interval = 3000
        request_timeout = 10000
    }
    if ($null -ne $existing) {
        foreach ($property in @('node_name', 'node_ip', 'main_config_path', 'route_config_path', 'access_log_path', 'cert_dir', 'openresty_cert_dir', 'lua_dir', 'openresty_lua_dir', 'runtime_config_dir', 'pages_dir', 'mmdb_path', 'city_mmdb_path', 'openresty_observability_port', 'observability_buffer_path', 'observability_replay_minutes', 'state_path', 'heartbeat_interval', 'request_timeout')) {
            $existingProperty = $existing.PSObject.Properties[$property]
            if ($null -ne $existingProperty -and $null -ne $existingProperty.Value -and -not [string]::IsNullOrWhiteSpace([string]$existingProperty.Value)) {
                $configuration[$property] = $existingProperty.Value
            }
        }
    }
    if (-not [string]::IsNullOrWhiteSpace($AgentToken)) {
        $configuration.agent_token = $AgentToken
    }
    else {
        $configuration.discovery_token = $DiscoveryToken
    }

    Remove-AgentService
    Copy-Item -LiteralPath $downloadedBinary -Destination $binaryPath -Force
    $utf8NoBom = New-Object System.Text.UTF8Encoding -ArgumentList $false
    [System.IO.File]::WriteAllText($configPath, ($configuration | ConvertTo-Json -Depth 5), $utf8NoBom)
    Set-RestrictedAcl $InstallDir -Directory
    Set-RestrictedAcl $configPath

    if (-not $NoService) {
        $serviceArguments = '"{0}" -config "{1}"' -f $binaryPath, $configPath
        New-Service -Name $serviceName -BinaryPathName $serviceArguments -DisplayName 'OpenFlare Agent' -Description 'OpenFlare Windows edge agent' -StartupType Automatic | Out-Null
        & sc.exe failure $serviceName reset= 86400 actions= restart/5000/restart/10000/restart/30000 | Out-Null
        Start-Service -Name $serviceName
        Write-Host "OpenFlare Agent installed and started: $serviceName"
    }
    else {
        Write-Host "OpenFlare Agent installed: $binaryPath"
        Write-Host "Run: `"$binaryPath`" -config `"$configPath`""
    }
}
finally {
    if (Test-Path -LiteralPath $downloadRoot) {
        Remove-Item -LiteralPath $downloadRoot -Recurse -Force -ErrorAction SilentlyContinue
    }
}
