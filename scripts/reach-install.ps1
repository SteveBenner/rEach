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
$LogThreshold = 3
$LogEnvKeep = '^(?i)(PATH|HOME|USERPROFILE|SHELL|LANG|LC_ALL|TERM|TMPDIR|TEMP|XDG_[A-Z_]+|RUBY[A-Z_]*|GEM_[A-Z_]+|BUNDLE_[A-Z_]+|REACH_[A-Z_]+|CLAUDE[A-Z_]*|CODEX[A-Z_]*|HERMES[A-Z_]*|ANTIGRAVITY[A-Z_]*|HTTP_PROXY|HTTPS_PROXY|NO_PROXY|SSL_CERT_FILE|SSL_CERT_DIR)$'
$LogEnvDrop = '(?i)(token|key|secret|password|passphrase|signature|pem|credential|passkey|course_code|enroll_code|enrollment_code)'
$script:LogEnabled = ($env:REACH_SETUP_LOG -ne '0')
$script:LogHome = $null
$script:LogFile = $null
$script:LogStarted = [DateTime]::UtcNow
$script:LogEnded = $false
$script:LogCode = $null
$script:LogMessage = $null
$script:ChildCounted = $false

function Write-Plain([string]$Text) {
    [Console]::Error.WriteLine($Text)
}

function Get-LogText($Value) {
    if ($null -eq $Value) {
        return ''
    }
    $text = [string]$Value
    $text = [regex]::Replace($text, '(?<=://)[^/@\s]+@', '[scrubbed]@')
    $text = [regex]::Replace($text, '(?s)-----BEGIN [A-Z0-9 ]+-----.*?(?:-----END [A-Z0-9 ]+-----|$)', '[scrubbed]')
    $text = [regex]::Replace($text, '[A-Z0-9]{3,}-[A-Z0-9]{4}-[A-Z0-9]{4}', '[scrubbed]')
    $homes = @()
    try { $homes += (Get-UserHome) } catch { }
    $homes += $env:USERPROFILE
    $homes += $env:HOME
    foreach ($homeDir in ($homes | Where-Object { $_ -and $_.Length -ge 3 } | Select-Object -Unique | Sort-Object Length -Descending)) {
        $trimmed = $homeDir.TrimEnd('\', '/')
        foreach ($form in @($trimmed, $trimmed.Replace('\', '/'))) {
            $text = [regex]::Replace($text, [regex]::Escape($form) + '(?=[\\/]|$|[^A-Za-z0-9._-])', '~', 'IgnoreCase')
        }
    }
    return $text
}

function Test-LogAnchor {
    if ($env:REACH_HOME) {
        $anchor = Split-Path -Parent $env:REACH_HOME
    } elseif ($env:REACH_WORKSPACE_ROOT) {
        $anchor = Split-Path -Parent $env:REACH_WORKSPACE_ROOT
    } else {
        $anchor = Get-UserHome
    }
    return [bool]($anchor -and (Test-Path -LiteralPath $anchor -PathType Container))
}

function Write-Log([hashtable]$Record) {
    if (-not $script:LogEnabled -or -not $script:LogHome) {
        return
    }
    try {
        if (-not (Test-LogAnchor)) {
            return
        }
        $dir = Join-Path $script:LogHome 'setup-log'
        New-Item -ItemType Directory -Force -Path $dir | Out-Null
        if (-not $script:LogFile) {
            $script:LogFile = Join-Path $dir ('install-' + [DateTime]::UtcNow.ToString('yyyyMMddTHHmmssZ') + '-ps.jsonl')
        }
        $entry = @{ at = [DateTime]::UtcNow.ToString('yyyy-MM-ddTHH:mm:ss.fffZ'); pid = $PID }
        foreach ($name in $Record.Keys) {
            $entry[$name] = $Record[$name]
        }
        $line = ConvertTo-Json -InputObject $entry -Compress -Depth 6
        [IO.File]::AppendAllText($script:LogFile, $line + "`n", (New-Object Text.UTF8Encoding($false)))
    } catch {
    }
}

function Write-LogStep([string]$Step, [DateTime]$Began, [hashtable]$Fields) {
    $record = @{ kind = 'step'; step = $Step; duration_ms = [int]([DateTime]::UtcNow - $Began).TotalMilliseconds }
    if ($Fields) {
        foreach ($name in $Fields.Keys) {
            $record[$name] = $Fields[$name]
        }
    }
    Write-Log $record
}

function Start-Log([string]$LogRoot, [string]$Dest, [string]$HarnessName) {
    $script:LogHome = $LogRoot
    $variables = @{}
    try {
        foreach ($item in Get-ChildItem Env:) {
            if ($item.Name -match $LogEnvKeep) {
                if ($item.Name -match $LogEnvDrop) {
                    $variables[$item.Name] = '[redacted]'
                } else {
                    $variables[$item.Name] = Get-LogText $item.Value
                }
            }
        }
    } catch {
    }
    $os = ''
    try {
        $os = [Environment]::OSVersion.VersionString
    } catch {
    }
    Write-Log @{
        kind = 'start'; script = 'reach-install.ps1'; destination = (Get-LogText $Dest); harness = $HarnessName
        powershell = $PSVersionTable.PSVersion.ToString(); os = $os; arch = $env:PROCESSOR_ARCHITECTURE; env = $variables
    }
}

function Update-Streak([bool]$Success) {
    if (-not $script:LogEnabled -or -not $script:LogHome) {
        return
    }
    try {
        if (-not (Test-LogAnchor)) {
            return
        }
        $dir = Join-Path $script:LogHome 'setup-log'
        New-Item -ItemType Directory -Force -Path $dir | Out-Null
        $path = Join-Path $dir 'state.json'
        $state = @{}
        if (Test-Path -LiteralPath $path) {
            try {
                $parsed = [IO.File]::ReadAllText($path) | ConvertFrom-Json
                foreach ($property in $parsed.PSObject.Properties) {
                    $state[$property.Name] = $property.Value
                }
            } catch {
                $state = @{}
            }
        }
        $streak = 0
        if ($state.ContainsKey('streak') -and $state['streak']) {
            $streak = [int]$state['streak']
        }
        $stamp = [DateTime]::UtcNow.ToString('yyyy-MM-ddTHH:mm:ss.fffZ')
        if ($Success) {
            $state['streak'] = 0
            $state['last_success_at'] = $stamp
            $streak = 0
        } elseif ($script:ChildCounted) {
            return
        } else {
            $streak = $streak + 1
            $state['streak'] = $streak
            $list = @()
            if ($state.ContainsKey('failures') -and $state['failures']) {
                $list = @($state['failures'])
            }
            $list = @($list + @(@{ at = $stamp; where = 'installer'; error = (Get-LogText $script:LogMessage) }))
            $state['failures'] = @($list | Select-Object -Last 10)
        }
        $json = ConvertTo-Json -InputObject $state -Compress -Depth 6
        $tmp = $path + '.tmp.' + $PID
        [IO.File]::WriteAllText($tmp, $json, (New-Object Text.UTF8Encoding($false)))
        Move-Item -Force -LiteralPath $tmp -Destination $path
        if (-not $Success -and $streak -gt 0 -and ($streak % $LogThreshold) -eq 0) {
            Write-Plain ('rEach has hit a problem ' + $streak + ' times in a row while getting set up. Once it runs, `reach debug export` saves a report for your instructor in Downloads.')
        }
    } catch {
    }
}

function Complete-Log {
    if ($script:LogEnded) {
        return
    }
    $script:LogEnded = $true
    try {
        $success = ($script:LogCode -eq 0)
        $record = @{
            kind = 'end'; outcome = $(if ($success) { 'success' } else { 'failure' }); exit = $script:LogCode
            duration_ms = [int]([DateTime]::UtcNow - $script:LogStarted).TotalMilliseconds
        }
        if (-not $success) {
            $record['error'] = @{ message = (Get-LogText $script:LogMessage) }
        }
        Write-Log $record
        Update-Streak $success
    } catch {
    }
}

function Stop-Install([string]$Text) {
    Write-Plain ('rEach install: ' + $Text)
    $script:LogCode = 1
    $script:LogMessage = $Text
    Complete-Log
    exit 1
}

function Get-UserHome {
    try {
        $known = [Environment]::GetFolderPath('UserProfile')
        if ($known -and (Test-Path -LiteralPath $known -PathType Container)) {
            return $known
        }
    } catch {
    }
    return $env:USERPROFILE
}

function Get-WorkspaceBase {
    if ($env:REACH_WORKSPACE_ROOT) {
        return $env:REACH_WORKSPACE_ROOT
    }
    return (Join-Path (Get-UserHome) 'reach-work')
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
    $legacy = Join-Path (Get-UserHome) '.reach'
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
        $began = [DateTime]::UtcNow
        try {
            Invoke-WebRequest -UseBasicParsing -Uri $Url -OutFile $Path
            $bytes = $null
            $hash = $null
            try {
                $bytes = (Get-Item -LiteralPath $Path).Length
                $hash = (Get-FileHash -Algorithm SHA256 -LiteralPath $Path).Hash.ToLower()
            } catch {
            }
            Write-LogStep 'download' $began @{ attempt = $attempt; url = (Get-LogText $Url); status = 200; bytes = $bytes; sha256 = $hash }
            return
        } catch {
            $last = $_.Exception.Message
            $status = $null
            try {
                $status = [int]$_.Exception.Response.StatusCode
            } catch {
            }
            Write-LogStep 'download' $began @{ attempt = $attempt; url = (Get-LogText $Url); status = $status; error = (Get-LogText $last) }
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
        $unpackBegan = [DateTime]::UtcNow
        & $tar -xzf $part -C $stage
        Write-LogStep 'extract' $unpackBegan @{ what = 'ruby-kit'; exit = $LASTEXITCODE }
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
        $moveBegan = [DateTime]::UtcNow
        try {
            Move-Item -LiteralPath $root -Destination $final
            Write-LogStep 'move' $moveBegan @{ what = 'ruby-kit' }
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
    try {
        Start-Log (Split-Path -Parent $Destination) $Destination $Harness
    } catch {
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
    $installerBegan = [DateTime]::UtcNow
    & $ruby $installer --destination $Destination
    Write-LogStep 'installer' $installerBegan @{ exit = $LASTEXITCODE }
    if ($LASTEXITCODE -ne 0) {
        $script:ChildCounted = $true
        Stop-Install 'reach-install failed.'
    }
    $setupBegan = [DateTime]::UtcNow
    & $ruby (Join-Path $Destination 'exe\reach') setup --harness $Harness
    Write-LogStep 'setup' $setupBegan @{ exit = $LASTEXITCODE }
    if ($LASTEXITCODE -ne 0) {
        Stop-Install 'reach setup failed.'
    }
    $codexHome = if ($env:CODEX_HOME) { $env:CODEX_HOME } else { Join-Path (Get-UserHome) '.codex' }
    if ((Get-Command codex -ErrorAction SilentlyContinue) -or (Test-Path -LiteralPath $codexHome)) {
        $reachExe = Join-Path $Destination 'exe\reach'
        if ([Environment]::UserInteractive -and -not [Console]::IsInputRedirected) {
            $codexBegan = [DateTime]::UtcNow
            & $ruby $reachExe codex configure
            Write-LogStep 'codex' $codexBegan @{ ran = $true; exit = $LASTEXITCODE }
        } else {
            Write-Log @{ kind = 'step'; step = 'codex'; ran = $false }
            Write-Plain ('rEach install: to let rEach set up Codex, run this in a terminal: "' + $ruby + '" "' + $reachExe + '" codex configure')
        }
    }
    $script:LogCode = 0
    Complete-Log
    exit 0
} catch {
    Stop-Install $_.Exception.Message
} finally {
    Complete-Log
}
