[CmdletBinding()]
param(
    [string]$Destination = '',
    [string]$Harness = 'claude-code'
)

$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'
try {
    [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
} catch {
}

$RawBase = 'https://raw.githubusercontent.com/SteveBenner/rEach/main'
$LockStaleSeconds = 900

function Write-Plain([string]$Text) {
    [Console]::Error.WriteLine($Text)
}

function Stop-Install([string]$Text) {
    Write-Plain ('rEach install: ' + $Text)
    exit 1
}

function Get-WorkspaceBase {
    if ($env:REACH_WORKSPACE_ROOT) {
        return $env:REACH_WORKSPACE_ROOT
    }
    return (Join-Path $env:USERPROFILE 'reach-work')
}

function Get-ReachHome {
    if ($env:REACH_HOME) {
        return $env:REACH_HOME
    }
    $newHome = Join-Path (Get-WorkspaceBase) '.reach-home'
    $pointer = Join-Path $newHome 'state\relocation.json'
    if (Test-Path -LiteralPath $pointer) {
        try {
            $data = [IO.File]::ReadAllText($pointer) | ConvertFrom-Json
            if ($data.phase -eq 'completed') {
                return $newHome
            }
        } catch {
        }
    }
    $legacy = Join-Path $env:USERPROFILE '.reach'
    if ((Test-Path -LiteralPath (Join-Path $legacy 'install.yml')) -or (Test-Path -LiteralPath (Join-Path $legacy 'plugin') -PathType Container)) {
        return $legacy
    }
    return $newHome
}

function Test-RubyOk([string]$Path) {
    try {
        & $Path -e 'exit((RUBY_VERSION.split(''.'').map { |part| part.to_i } <=> [2, 6, 10]) >= 0 ? 0 : 1)' 2>$null | Out-Null
        return ($LASTEXITCODE -eq 0)
    } catch {
        return $false
    }
}

function Get-PathRuby {
    $command = Get-Command ruby -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($command -and $command.Source -and (Test-RubyOk $command.Source)) {
        return $command.Source
    }
    return $null
}

function Get-KitRuby([string]$ReachHome) {
    $currentFile = Join-Path $ReachHome 'runtime\current'
    if (-not (Test-Path -LiteralPath $currentFile)) {
        return $null
    }
    $id = ([IO.File]::ReadAllText($currentFile)).Trim()
    if ($id -notmatch '^[A-Za-z0-9._-]+$') {
        return $null
    }
    $kit = Join-Path (Join-Path $ReachHome 'runtime') $id
    if (-not (Test-Path -LiteralPath (Join-Path $kit '.complete'))) {
        return $null
    }
    $exe = Join-Path $kit 'ruby\bin\ruby.exe'
    if (Test-Path -LiteralPath $exe) {
        return $exe
    }
    return $null
}

function Save-File([string]$Url, [string]$Path) {
    $last = $null
    for ($attempt = 1; $attempt -le 3; $attempt++) {
        try {
            Invoke-WebRequest -UseBasicParsing -Uri $Url -OutFile $Path
            return
        } catch {
            $last = $_.Exception.Message
            Start-Sleep -Seconds ($attempt * 2)
        }
    }
    throw ('could not download ' + $Url + ' (' + $last + ')')
}

function Find-Sibling([string]$Name, [string]$RemotePath, [string]$BootstrapDir) {
    if ($PSScriptRoot) {
        $checkout = Split-Path -Parent $PSScriptRoot
        if (Test-Path -LiteralPath (Join-Path $checkout 'exe\reach')) {
            $local = Join-Path $checkout ($RemotePath -replace '/', '\')
            if (Test-Path -LiteralPath $local) {
                return $local
            }
        }
    }
    New-Item -ItemType Directory -Force -Path $BootstrapDir | Out-Null
    $target = Join-Path $BootstrapDir $Name
    Save-File ($RawBase + '/' + $RemotePath) $target
    return $target
}

function Read-Pins([string]$Path) {
    $pins = @{}
    foreach ($line in [IO.File]::ReadAllLines($Path)) {
        if (-not $line -or $line.StartsWith('#')) {
            continue
        }
        $at = $line.IndexOf('=')
        if ($at -lt 1) {
            continue
        }
        $value = $line.Substring($at + 1).Trim()
        if ($value.Length -ge 2 -and $value.StartsWith("'") -and $value.EndsWith("'")) {
            $value = $value.Substring(1, $value.Length - 2)
        }
        $pins[$line.Substring(0, $at).Trim()] = $value
    }
    return $pins
}

function Enter-Lock([string]$ReachHome) {
    $stateDir = Join-Path $ReachHome 'state'
    New-Item -ItemType Directory -Force -Path $stateDir | Out-Null
    $lock = Join-Path $stateDir 'bootstrap.lock'
    $deadline = (Get-Date).AddSeconds($LockStaleSeconds)
    while ($true) {
        try {
            New-Item -ItemType Directory -Path $lock -ErrorAction Stop | Out-Null
            $epoch = [DateTimeOffset]::UtcNow.ToUnixTimeSeconds()
            [IO.File]::WriteAllText((Join-Path $lock 'info'), ('0 ' + $epoch + "`n"), (New-Object Text.UTF8Encoding($false)))
            return $lock
        } catch {
            if (-not (Test-Path -LiteralPath $lock)) {
                throw
            }
        }
        if (Get-KitRuby $ReachHome) {
            return $null
        }
        $info = Join-Path $lock 'info'
        if (Test-Path -LiteralPath $info) {
            $parts = ([IO.File]::ReadAllText($info)).Trim() -split '\s+'
            if ($parts.Length -ge 2 -and $parts[1] -match '^[0-9]+$') {
                $age = [DateTimeOffset]::UtcNow.ToUnixTimeSeconds() - [int64]$parts[1]
                if ($age -gt $LockStaleSeconds) {
                    Remove-Item -Recurse -Force -LiteralPath $lock -ErrorAction SilentlyContinue
                    continue
                }
            }
        }
        if ((Get-Date) -gt $deadline) {
            throw 'another rEach Ruby setup has been running for too long'
        }
        Write-Plain 'rEach install: waiting for the Ruby setup already in progress'
        Start-Sleep -Seconds 3
    }
}

function Add-UserPath([string]$Bin) {
    $userPath = [Environment]::GetEnvironmentVariable('Path', 'User')
    $entries = @()
    if ($userPath) {
        $entries = @($userPath -split ';' | Where-Object { $_ })
    }
    $wanted = $Bin.TrimEnd('\')
    $present = @($entries | Where-Object { $_.TrimEnd('\') -ieq $wanted })
    if ($present.Count -eq 0) {
        $updated = (@($Bin) + $entries) -join ';'
        [Environment]::SetEnvironmentVariable('Path', $updated, 'User')
    }
    $processEntries = @($env:Path -split ';' | Where-Object { $_ })
    $inProcess = @($processEntries | Where-Object { $_.TrimEnd('\') -ieq $wanted })
    if ($inProcess.Count -eq 0) {
        $env:Path = $Bin + ';' + $env:Path
    }
}

function Install-KitRuby([string]$ReachHome, [string]$BootstrapDir) {
    $pinsPath = Find-Sibling 'runtime-pins' 'exe/runtime-pins' $BootstrapDir
    $pins = Read-Pins $pinsPath
    $plat = 'windows_x86_64'
    $runtimeId = $pins['RUNTIME_ID']
    $asset = $pins['ASSET_' + $plat]
    $sha = $pins['SHA256_' + $plat]
    $size = $pins['SIZE_' + $plat]
    $rubyExeRel = $pins['RUBY_EXE_' + $plat]
    if (-not $runtimeId -or -not $asset -or -not $sha -or -not $size -or -not $rubyExeRel) {
        throw 'exe/runtime-pins has no Windows Ruby kit'
    }
    if ($runtimeId -notmatch '^[A-Za-z0-9._-]+$') {
        throw 'exe/runtime-pins names an invalid runtime id'
    }

    $runtimeDir = Join-Path $ReachHome 'runtime'
    $downloads = Join-Path $ReachHome 'downloads'
    New-Item -ItemType Directory -Force -Path $runtimeDir, $downloads | Out-Null
    $lock = Enter-Lock $ReachHome
    if ($null -eq $lock) {
        return (Get-KitRuby $ReachHome)
    }
    $part = Join-Path $downloads ($asset + '.part')
    $stage = Join-Path $runtimeDir ('.stage-' + $PID)
    try {
        $url = $pins['RELEASE_BASE'] + '/' + $pins['RUNTIME_TAG'] + '/' + $asset
        Write-Plain ('rEach install: downloading its Ruby (' + $asset + ')')
        Save-File $url $part
        $haveSize = (Get-Item -LiteralPath $part).Length
        if ($haveSize -ne [int64]$size) {
            throw ('size mismatch for ' + $asset + ' (expected ' + $size + ', got ' + $haveSize + ')')
        }
        $haveSha = (Get-FileHash -Algorithm SHA256 -LiteralPath $part).Hash.ToLower()
        if ($haveSha -ne $sha.ToLower()) {
            throw ('sha256 mismatch for ' + $asset)
        }

        Write-Plain 'rEach install: unpacking'
        New-Item -ItemType Directory -Force -Path $stage | Out-Null
        $tar = Join-Path $env:SystemRoot 'System32\tar.exe'
        if (-not (Test-Path -LiteralPath $tar)) {
            $tar = 'tar.exe'
        }
        & $tar -xzf $part -C $stage
        if ($LASTEXITCODE -ne 0) {
            throw 'tar.exe could not unpack the Ruby kit'
        }
        $root = Join-Path $stage 'runtime'
        $stagedRuby = Join-Path $stage ($rubyExeRel -replace '/', '\')
        if (-not (Test-Path -LiteralPath $stagedRuby)) {
            throw ('the bundle has no ' + $rubyExeRel)
        }
        $haveVersion = (& $stagedRuby -e 'print RUBY_VERSION') -join ''
        if ($LASTEXITCODE -ne 0 -or $haveVersion -ne $pins['RUBY_VERSION']) {
            throw ('the bundle Ruby reported ' + $haveVersion + ', expected ' + $pins['RUBY_VERSION'])
        }

        $installedAt = [DateTime]::UtcNow.ToString('yyyy-MM-ddTHH:mm:ssZ')
        $marker = @"
{
  "runtime_id": "$runtimeId",
  "platform": "windows-x86_64",
  "components": [
    "ruby"
  ],
  "ruby_version": "$($pins['RUBY_VERSION'])",
  "chrome_version": null,
  "profiles": $($pins['PROFILES_JSON']),
  "installed_at": "$installedAt",
  "bundler_version": "$($pins['BUNDLER_VERSION'])"
}
"@
        $utf8 = New-Object Text.UTF8Encoding($false)
        [IO.File]::WriteAllText((Join-Path $root '.complete'), $marker, $utf8)

        $final = Join-Path $runtimeDir $runtimeId
        $previous = $null
        if (Test-Path -LiteralPath $final) {
            $previous = $final + '.old-' + [DateTime]::UtcNow.ToString('yyyyMMddTHHmmssZ')
            Move-Item -LiteralPath $final -Destination $previous
        }
        try {
            Move-Item -LiteralPath $root -Destination $final
        } catch {
            if ($previous -and -not (Test-Path -LiteralPath $final)) {
                Move-Item -LiteralPath $previous -Destination $final
            }
            throw
        }
        $currentTemp = Join-Path $runtimeDir ('current.tmp-' + $PID)
        [IO.File]::WriteAllText($currentTemp, ($runtimeId + "`n"), $utf8)
        Move-Item -Force -LiteralPath $currentTemp -Destination (Join-Path $runtimeDir 'current')
        Remove-Item -Force -LiteralPath $part -ErrorAction SilentlyContinue
        return (Join-Path $final 'ruby\bin\ruby.exe')
    } catch {
        $logs = Join-Path $ReachHome 'logs'
        New-Item -ItemType Directory -Force -Path $logs | Out-Null
        $line = [DateTime]::UtcNow.ToString('yyyy-MM-ddTHH:mm:ssZ') + ' failed: ' + $_.Exception.Message
        Add-Content -LiteralPath (Join-Path $logs 'bootstrap.log') -Value $line
        throw
    } finally {
        if (Test-Path -LiteralPath $stage) {
            Remove-Item -Recurse -Force -LiteralPath $stage -ErrorAction SilentlyContinue
        }
        if (Test-Path -LiteralPath $part) {
            Remove-Item -Force -LiteralPath $part -ErrorAction SilentlyContinue
        }
        Remove-Item -Recurse -Force -LiteralPath $lock -ErrorAction SilentlyContinue
    }
}

try {
    $reachHome = Get-ReachHome
    if (-not $Destination) {
        $Destination = Join-Path $reachHome 'plugin'
    }
    $bootstrapDir = Join-Path (Join-Path (Get-WorkspaceBase) '.reach-home') 'bootstrap'

    $ruby = Get-PathRuby
    if (-not $ruby) {
        $ruby = Get-KitRuby $reachHome
        if (-not $ruby) {
            $ruby = Install-KitRuby $reachHome $bootstrapDir
        }
        if (-not $ruby) {
            Stop-Install 'rEach could not set up its Ruby.'
        }
        Add-UserPath (Split-Path -Parent $ruby)
    }

    $installer = Find-Sibling 'reach-install' 'scripts/reach-install' $bootstrapDir
    & $ruby $installer --destination $Destination
    if ($LASTEXITCODE -ne 0) {
        Stop-Install 'reach-install failed.'
    }
    & $ruby (Join-Path $Destination 'exe\reach') setup --harness $Harness
    if ($LASTEXITCODE -ne 0) {
        Stop-Install 'reach setup failed.'
    }
    $codexHome = if ($env:CODEX_HOME) { $env:CODEX_HOME } else { Join-Path $env:USERPROFILE '.codex' }
    if ((Get-Command codex -ErrorAction SilentlyContinue) -or (Test-Path -LiteralPath $codexHome)) {
        $reachExe = Join-Path $Destination 'exe\reach'
        if ([Environment]::UserInteractive -and -not [Console]::IsInputRedirected) {
            & $ruby $reachExe codex configure
        } else {
            Write-Plain ('rEach install: to let rEach set up Codex, run this in a terminal: "' + $ruby + '" "' + $reachExe + '" codex configure')
        }
    }
    exit 0
} catch {
    Stop-Install $_.Exception.Message
}
