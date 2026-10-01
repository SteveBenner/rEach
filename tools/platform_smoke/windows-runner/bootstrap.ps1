$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 2.0
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

$GitVersion = '2.56.0'
$GitUrl = 'https://github.com/git-for-windows/git/releases/download/v2.56.0.windows.1/Git-2.56.0-64-bit.exe'
$GitSha256 = 'bfe94e7b419b16eee9fecbd1253a98e3d4f49ba8f029630549052278ffe286a6'
$RubyVersion = '4.0.7'
$RubyUrl = 'https://github.com/oneclick/rubyinstaller2/releases/download/RubyInstaller-4.0.7-1/rubyinstaller-4.0.7-1-x64.exe'
$RubySha256 = '552911af94cbc419b9d631a29ee1f09ea75eb541e030c4cb6ea62a50d05f12fa'
$RubyDir = 'C:\Ruby40-x64'
$RunnerVersion = '2.337.0'
$RunnerUrl = 'https://github.com/actions/runner/releases/download/v2.337.0/actions-runner-win-x64-2.337.0.zip'
$RunnerSha256 = '1150692afa94e71f872017e254ea55b6eece1eece3fe7e3a6d4c93d0a1b85cfc'
$RunnerDir = 'C:\actions-runner'
$Work = Join-Path $env:TEMP 'reach-runner-bootstrap'

function Say([string]$Message) {
    Write-Host ('bootstrap: ' + $Message)
}

function Assert-Administrator {
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = New-Object Security.Principal.WindowsPrincipal($identity)
    if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
        throw 'run this script from an elevated PowerShell (Run as Administrator)'
    }
}

function Get-Sha256([string]$Path) {
    $stream = [IO.File]::OpenRead($Path)
    try {
        $sha = [Security.Cryptography.SHA256]::Create()
        try {
            $bytes = $sha.ComputeHash($stream)
        } finally {
            $sha.Dispose()
        }
    } finally {
        $stream.Dispose()
    }
    return (($bytes | ForEach-Object { $_.ToString('x2') }) -join '')
}

function Save-Download([string]$Url, [string]$Path, [string]$Sha256) {
    if (Test-Path -LiteralPath $Path) {
        if ((Get-Sha256 $Path) -eq $Sha256) {
            Say ('already downloaded ' + $Path)
            return
        }
        Remove-Item -LiteralPath $Path -Force
    }
    $curl = Join-Path $env:SystemRoot 'System32\curl.exe'
    $lastError = ''
    for ($attempt = 1; $attempt -le 3; $attempt++) {
        try {
            Say ('downloading ' + $Url + ' (attempt ' + $attempt + ' of 3)')
            if (Test-Path -LiteralPath $curl) {
                & $curl -fsSL --connect-timeout 30 --max-time 900 -o $Path $Url
                if ($LASTEXITCODE -ne 0) {
                    throw ('curl.exe exited ' + $LASTEXITCODE)
                }
            } else {
                Invoke-WebRequest -Uri $Url -OutFile $Path -UseBasicParsing -TimeoutSec 900
            }
            $actual = Get-Sha256 $Path
            if ($actual -ne $Sha256) {
                throw ('SHA-256 mismatch for ' + $Url + ': expected ' + $Sha256 + ', got ' + $actual)
            }
            Say ('verified SHA-256 ' + $Sha256)
            return
        } catch {
            $lastError = $_.Exception.Message
            Say ('attempt ' + $attempt + ' failed: ' + $lastError)
            if (Test-Path -LiteralPath $Path) {
                Remove-Item -LiteralPath $Path -Force
            }
            if ($attempt -lt 3) {
                Start-Sleep -Seconds (5 * $attempt)
            }
        }
    }
    throw ('could not download ' + $Url + ': ' + $lastError)
}

function Install-OpenSsh {
    $capability = Get-WindowsCapability -Online -Name 'OpenSSH.Server*' | Select-Object -First 1
    if ($null -eq $capability) {
        throw 'the OpenSSH Server capability is not available on this Windows'
    }
    if ($capability.State -ne 'Installed') {
        Say 'installing the OpenSSH Server capability'
        Add-WindowsCapability -Online -Name $capability.Name | Out-Null
    } else {
        Say 'OpenSSH Server capability already installed'
    }
    Set-Service -Name sshd -StartupType Automatic
    if ((Get-Service -Name sshd).Status -ne 'Running') {
        Start-Service -Name sshd
    }
    $rule = Get-NetFirewallRule -Name 'OpenSSH-Server-In-TCP' -ErrorAction SilentlyContinue
    if ($null -eq $rule) {
        New-NetFirewallRule -Name 'OpenSSH-Server-In-TCP' -DisplayName 'OpenSSH Server (sshd)' -Enabled True -Direction Inbound -Protocol TCP -Action Allow -LocalPort 22 | Out-Null
        Say 'added the firewall rule for port 22'
    } else {
        Enable-NetFirewallRule -Name 'OpenSSH-Server-In-TCP'
        Say 'firewall rule for port 22 already present'
    }
    $shell = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
    if (-not (Test-Path 'HKLM:\SOFTWARE\OpenSSH')) {
        New-Item -Path 'HKLM:\SOFTWARE\OpenSSH' -Force | Out-Null
    }
    New-ItemProperty -Path 'HKLM:\SOFTWARE\OpenSSH' -Name DefaultShell -Value $shell -PropertyType String -Force | Out-Null
    Say ('OpenSSH default shell is ' + $shell)
}

function Get-GitExe {
    foreach ($candidate in @((Join-Path $env:ProgramFiles 'Git\cmd\git.exe'), (Join-Path $env:ProgramFiles 'Git\bin\git.exe'))) {
        if (Test-Path -LiteralPath $candidate) {
            return $candidate
        }
    }
    return $null
}

function Install-Git {
    $git = Get-GitExe
    if ($git) {
        $reported = (& $git --version) | Out-String
        if ($reported -match [regex]::Escape($GitVersion)) {
            Say ('Git for Windows ' + $GitVersion + ' already installed')
            return
        }
    }
    $installer = Join-Path $Work 'Git-installer.exe'
    Save-Download $GitUrl $installer $GitSha256
    Say 'installing Git for Windows'
    $process = Start-Process -FilePath $installer -ArgumentList '/VERYSILENT', '/NORESTART', '/SUPPRESSMSGBOXES', '/NOCANCEL', '/SP-' -Wait -PassThru
    if ($process.ExitCode -ne 0) {
        throw ('the Git installer exited ' + $process.ExitCode)
    }
    $git = Get-GitExe
    if (-not $git) {
        throw 'git.exe was not found after the Git installer finished'
    }
    $bash = Join-Path $env:ProgramFiles 'Git\bin\bash.exe'
    if (-not (Test-Path -LiteralPath $bash)) {
        throw ('Git Bash was not found at ' + $bash)
    }
    Say ('installed ' + ((& $git --version) | Out-String).Trim())
}

function Add-MachinePath([string]$Directory) {
    $current = [Environment]::GetEnvironmentVariable('Path', 'Machine')
    $parts = $current -split ';' | Where-Object { $_ -ne '' }
    if ($parts -notcontains $Directory) {
        [Environment]::SetEnvironmentVariable('Path', ($current.TrimEnd(';') + ';' + $Directory), 'Machine')
        Say ('added ' + $Directory + ' to the machine PATH')
    } else {
        Say ($Directory + ' already on the machine PATH')
    }
}

function Install-Ruby {
    $rubyExe = Join-Path $RubyDir 'bin\ruby.exe'
    $installed = $false
    if (Test-Path -LiteralPath $rubyExe) {
        $reported = (& $rubyExe -e 'print RUBY_VERSION') | Out-String
        if ($reported.Trim() -eq $RubyVersion) {
            $installed = $true
        }
    }
    if ($installed) {
        Say ('Ruby ' + $RubyVersion + ' already installed')
    } else {
        $installer = Join-Path $Work 'rubyinstaller.exe'
        Save-Download $RubyUrl $installer $RubySha256
        Say 'installing RubyInstaller'
        $arguments = @('/verysilent', '/allusers', ('/dir="' + $RubyDir + '"'), '/tasks="modpath,assocfiles"')
        $process = Start-Process -FilePath $installer -ArgumentList $arguments -Wait -PassThru
        if ($process.ExitCode -ne 0) {
            throw ('the RubyInstaller exited ' + $process.ExitCode)
        }
        if (-not (Test-Path -LiteralPath $rubyExe)) {
            throw ('ruby.exe was not found at ' + $rubyExe)
        }
        $reported = ((& $rubyExe -e 'print RUBY_VERSION') | Out-String).Trim()
        if ($reported -ne $RubyVersion) {
            throw ('installed Ruby reports ' + $reported + ', expected ' + $RubyVersion)
        }
        Say ('installed Ruby ' + $reported)
    }
    Add-MachinePath (Join-Path $RubyDir 'bin')
}

function Install-Runner {
    $config = Join-Path $RunnerDir 'config.cmd'
    $versionMarker = Join-Path $RunnerDir '.runner-version'
    if ((Test-Path -LiteralPath $config) -and (Test-Path -LiteralPath $versionMarker) -and ((Get-Content -Raw -LiteralPath $versionMarker).Trim() -eq $RunnerVersion)) {
        Say ('GitHub Actions runner ' + $RunnerVersion + ' already downloaded')
        return
    }
    $zip = Join-Path $Work 'actions-runner.zip'
    Save-Download $RunnerUrl $zip $RunnerSha256
    New-Item -ItemType Directory -Path $RunnerDir -Force | Out-Null
    Add-Type -AssemblyName System.IO.Compression.FileSystem
    $archive = [IO.Compression.ZipFile]::OpenRead($zip)
    try {
        foreach ($entry in $archive.Entries) {
            $target = [IO.Path]::GetFullPath((Join-Path $RunnerDir $entry.FullName))
            if (-not $target.StartsWith($RunnerDir, [StringComparison]::OrdinalIgnoreCase)) {
                throw ('unsafe path in the runner archive: ' + $entry.FullName)
            }
            if ($entry.FullName.EndsWith('/')) {
                New-Item -ItemType Directory -Path $target -Force | Out-Null
            } else {
                New-Item -ItemType Directory -Path (Split-Path -Parent $target) -Force | Out-Null
                [IO.Compression.ZipFileExtensions]::ExtractToFile($entry, $target, $true)
            }
        }
    } finally {
        $archive.Dispose()
    }
    if (-not (Test-Path -LiteralPath $config)) {
        throw ('config.cmd was not found in ' + $RunnerDir)
    }
    Set-Content -LiteralPath $versionMarker -Value $RunnerVersion -Encoding ASCII
    Say ('GitHub Actions runner ' + $RunnerVersion + ' is in ' + $RunnerDir)
}

try {
    Assert-Administrator
    New-Item -ItemType Directory -Path $Work -Force | Out-Null
    Install-OpenSsh
    Install-Git
    Install-Ruby
    Install-Runner
    Say 'done'
    exit 0
} catch {
    Write-Host ('bootstrap: FAILED: ' + $_.Exception.Message)
    exit 1
}
