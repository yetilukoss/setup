<#
.SYNOPSIS
    VencordSetup - setup-only installer for Vencord plus selected userplugins.

.DESCRIPTION
    Console companion to the WPF GUI. Clones Vencord, clones selected plugins,
    installs dependencies, builds the bundle and injects with the official
    VencordInstallerCli.exe fetched by Vencord's installer helper.
    Supports install, update, uninstall, reinject,
    repair, repair-plugins and dry-run modes.

.NOTES
    Run: powershell -STA -ExecutionPolicy Bypass -File .\VencordSetup.ps1
    One-line: irm https://raw.githubusercontent.com/yetilukoss/vencord-setup/main/install.ps1 | iex

    Requires: Windows 10/11, PowerShell 5.1+, Node.js >= 22, Git, pnpm.
#>

param(
    [ValidateSet('install', 'update', 'uninstall', 'reinject', 'repair', 'repair-plugins', 'dry-run')]
    [string]$Mode = 'install',

    [ValidateSet('auto', 'stable', 'ptb', 'canary')]
    [string]$Branch = 'auto',

    [string]$Target = '',

    [switch]$Yes,

    [switch]$NoSound
)

$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'

try { [Console]::OutputEncoding = [System.Text.Encoding]::UTF8 } catch { }
try { $Host.UI.RawUI.WindowTitle = 'VencordSetup' } catch { }

$script:SoundEnabled = -not [bool]$NoSound
$script:ExitCode = 0
$script:FailedSteps = [System.Collections.Generic.List[string]]::new()

$SoundMap = @{
    boot     = @(@(262, 120), @(392, 120))
    click    = @(@(880, 60))
    success  = @(@(523, 90), @(659, 90), @(784, 120))
    error    = @(@(330, 120), @(220, 160))
    warning  = @(@(440, 80), @(440, 80))
    navigate = @(@(494, 70))
    complete = @(@(523, 100), @(659, 100), @(784, 100), @(1047, 160))
}

function Play-Sound([string]$Name) {
    if (-not $script:SoundEnabled) { return }
    if (-not $SoundMap.ContainsKey($Name)) { $Name = 'click' }
    try {
        foreach ($tone in $SoundMap[$Name]) {
            [Console]::Beep([int]$tone[0], [int]$tone[1])
            Start-Sleep -Milliseconds 30
        }
    } catch { }
}

function Write-Banner {
    $art = @'
 __     __            _                       ____            _           _
 \ \   / /           | |                     / ___|  ___  ___| |_   _  __| | ___ _ __
  \ \ / /__  _ __ ___| | ___  _ __   ___ ___\___ \ / _ \/ __| | | | |/ _` |/ _ \ '__|
   \ V / _ \| '__/ _ \ |/ _ \| '_ \ / __/ _ \___) |  __/ (__| | |_| | (_| |  __/ |
    \_/ \___/|_|  \___/_|\___/| .__/ \___\___|____/ \___|\___|_|\__,_|\___|_|
                              |_|
'@
    Write-Host $art -ForegroundColor Cyan
    Write-Host '  Vencord + community userplugins - setup only' -ForegroundColor DarkCyan
    Write-Host '  sounds: bencho.dev reference   |   icons: iconoir.com outline reference' -ForegroundColor DarkGray
    Write-Host '  made by: ! ayeti | @xiari.i' -ForegroundColor DarkGray
    Write-Host ''
}

function Write-Box([string]$title, [string[]]$lines, [ConsoleColor]$color = 'Cyan') {
    $width = 92
    $top = '+' + ('-' * ($width - 2)) + '+'
    Write-Host $top -ForegroundColor $color
    if ($title) {
        $t = ' ' + $title + ' '
        $pad = $width - 2 - $t.Length
        if ($pad -lt 0) { $pad = 0 }
        Write-Host ('|' + $t + (' ' * $pad) + '|') -ForegroundColor $color
        Write-Host $top -ForegroundColor $color
    }
    foreach ($line in $lines) {
        $text = if ($line.Length -gt ($width - 4)) { $line.Substring(0, $width - 4) } else { $line }
        $pad = $width - 4 - $text.Length
        if ($pad -lt 0) { $pad = 0 }
        Write-Host ('| ' + $text + (' ' * $pad) + ' |') -ForegroundColor White
    }
    Write-Host $top -ForegroundColor $color
    Write-Host ''
}

function Write-Step([string]$msg) { Write-Host '  >> ' -ForegroundColor Yellow -NoNewline; Write-Host $msg -ForegroundColor White }
function Write-Ok([string]$msg) { Write-Host '  [OK] ' -ForegroundColor Green -NoNewline; Write-Host $msg -ForegroundColor White }
function Write-Warn([string]$msg) { Write-Host '  [!!] ' -ForegroundColor Yellow -NoNewline; Write-Host $msg -ForegroundColor Yellow }
function Write-Err([string]$msg) { Write-Host '  [XX] ' -ForegroundColor Red -NoNewline; Write-Host $msg -ForegroundColor Red }
function Write-Info([string]$msg) { Write-Host '  ..  ' -ForegroundColor DarkGray -NoNewline; Write-Host $msg -ForegroundColor Gray }

function Invoke-NativeConsole {
    param([Parameter(Mandatory = $true)][scriptblock]$Command)
    $pref = $ErrorActionPreference
    try {
        $ErrorActionPreference = 'Continue'
        $global:LASTEXITCODE = 0
        & $Command 2>&1 | ForEach-Object { if ($null -ne $_) { Write-Host ('      ' + $_.ToString()) } }
        return [int]$global:LASTEXITCODE
    } finally {
        $ErrorActionPreference = $pref
    }
}

function Invoke-NativeCapture {
    param([Parameter(Mandatory = $true)][scriptblock]$Command)
    $pref = $ErrorActionPreference
    try {
        $ErrorActionPreference = 'Continue'
        $global:LASTEXITCODE = 0
        $raw = & $Command 2>&1
        $text = (($raw | ForEach-Object { if ($null -ne $_) { $_.ToString() } }) -join "`n")
        return [pscustomobject]@{ Text = $text.Trim(); ExitCode = [int]$global:LASTEXITCODE }
    } finally {
        $ErrorActionPreference = $pref
    }
}

function Confirm-Action([string]$message) {
    if ($Yes) { return $true }
    if (-not [Environment]::UserInteractive) { throw "Non-interactive session. Re-run with -Yes to accept: $message" }
    Write-Host "  $message (Y/N) " -NoNewline -ForegroundColor White
    $answer = Read-Host
    return ($answer -match '^[Yy]')
}

function Refresh-ProcessPath {
    $machinePath = [Environment]::GetEnvironmentVariable('Path', [EnvironmentVariableTarget]::Machine)
    $userPath = [Environment]::GetEnvironmentVariable('Path', [EnvironmentVariableTarget]::User)
    if ($machinePath -or $userPath) { $env:PATH = "$machinePath;$userPath" }
}

function Test-CommandExists([string]$name) {
    return [bool](Get-Command $name -ErrorAction SilentlyContinue)
}

function Assert-Prerequisites {
    Write-Box 'Prerequisites' @(
        'Node.js >= 22   https://nodejs.org',
        'Git             https://git-scm.com',
        'pnpm            npm install -g pnpm (invoked through cmd.exe)'
    ) 'Cyan'

    if (-not (Test-CommandExists 'node')) { throw 'Node.js not found. Install Node.js >= 22 from https://nodejs.org' }
    $nodeRes = Invoke-NativeCapture { node --version }
    if ($nodeRes.ExitCode -ne 0) { throw 'Could not read the Node.js version.' }
    $nodeRaw = $nodeRes.Text.Trim().TrimStart('v')
    $nodeMajor = 0
    if (-not [int]::TryParse(($nodeRaw -split '\.')[0], [ref]$nodeMajor) -or $nodeMajor -lt 22) {
        throw "Node.js >= 22 required. Found: $nodeRaw"
    }
    Write-Ok "Node.js $nodeRaw"

    if (-not (Test-CommandExists 'git')) { throw 'Git not found. Install Git from https://git-scm.com' }
    $gitRes = Invoke-NativeCapture { git --version }
    Write-Ok $gitRes.Text

    $pnpmOk = $false
    $pnpmRes = Invoke-NativeCapture { cmd.exe /c "pnpm --version" }
    if ($pnpmRes.ExitCode -eq 0 -and -not [string]::IsNullOrWhiteSpace($pnpmRes.Text)) {
        $pnpmOk = $true
        Write-Ok ("pnpm " + $pnpmRes.Text.Split("`n")[0].Trim())
    } else {
        Write-Warn 'pnpm not found. Installing with npm...'
        if (-not (Test-CommandExists 'npm')) { throw 'npm not found. Install pnpm manually: npm install -g pnpm' }
        $rc = Invoke-NativeConsole { cmd.exe /c "npm install -g pnpm" }
        Refresh-ProcessPath
        $check = Invoke-NativeCapture { cmd.exe /c "pnpm --version" }
        if ($rc -eq 0 -and $check.ExitCode -eq 0) {
            $pnpmOk = $true
            Write-Ok 'pnpm installed and PATH refreshed'
        } else {
            throw 'pnpm install failed. Install manually: npm install -g pnpm'
        }
    }
    if (-not $pnpmOk) { throw 'pnpm is required.' }
    Play-Sound 'success'
}

function Show-Terms {
    Write-Box 'WARNING - READ BEFORE CONTINUING' @(
        'This tool modifies your Discord client (client mod).',
        'Client mods violate Discord Terms of Service.',
        'Enforcement can include account bans. Your account is at risk.',
        'If your account is critical to you, do NOT proceed.',
        'This tool clones code from GitHub and runs pnpm build locally.',
        'Only use plugins you trust. Review the source yourself.'
    ) 'Yellow'
    Play-Sound 'warning'

    Write-Box 'WHAT THIS TOOL DOES (exact steps)' @(
        '1. Checks Node.js >= 22, Git and pnpm.',
        '2. git clone Vencord into the chosen folder.',
        '3. git clone selected plugins into src/userplugins.',
        '4. pnpm install (downloads packages from the npm registry).',
        '5. pnpm build (compiles the Vencord bundle).',
        '6. official VencordInstallerCli.exe patches a local Discord install.',
        '7. branch choice is auto, stable, ptb or canary.',
        'The one-line command fetches install.ps1 and its .sha256 file, then verifies the hash.',
        'The GUI and console are bundled inside install.ps1.',
        'No services, scheduled tasks, or persistent background agents are installed.',
        'Short-lived beeps and interactive prompts are the only background activity.',
        'The one-line GUI also runs one git fetch update check on launch.'
    ) 'Yellow'

    Write-Box 'PRIVACY POLICY (detailed)' @(
        'SCOPE: this script runs entirely on your local machine.',
        'DATA WE COLLECT: none. No telemetry, analytics, crash reports or tracking.',
        'NETWORK REQUESTS:',
        '  0. one-line launch only: raw.githubusercontent.com for install.ps1',
        '  1. git clone github.com/Vendicated/Vencord',
        '  2. git clone github.com/BlockTol/Quest-Auto-Complete',
        '  3. git clone github.com/BlockTol/Discord-Fake-Deafen',
        '  4. git clone github.com/BlockTol/Discord-Server-Cloner',
        '  5. git clone github.com/BlockTol/DiscordTabs',
        '  6. git clone github.com/ScattrdBlade/bigFileUpload',
        '  7. pnpm install -> npm registry (package downloads)',
        '  8. optional winget install if you choose to install prerequisites',
        '  9. Discord patching -> local files only, no network',
        'DiscordTabs checks api.github.com for its own releases at runtime and',
        'reads local Discord tokens. Tokens are not written to files or sent to',
        'a server by that plugin.',
        'STORED LOCALLY: chosen source folder, Discord config, pnpm/npm cache.',
        'THIRD PARTIES: Discord and GitHub may log their own requests.',
        'RIGHTS: delete the created folder to remove local setup data.'
    ) 'Cyan'

    Write-Box 'COOKIE POLICY (detailed)' @(
        'THIS SCRIPT: sets zero cookies, zero localStorage, zero sessionStorage.',
        'DISCORD CLIENT: Discord may set its own session cookies during normal use.',
        'VENCORD: may store plugin settings in Discord local storage.',
        'No cross-site cookies, ad cookies, analytics cookies, or consent banner.'
    ) 'Cyan'

    Write-Box 'TERMS OF USE (detailed)' @(
        '1. AS-IS: no warranty, no guarantee of fitness for purpose.',
        '2. ACCOUNT RISK: client mods violate Discord ToS. You accept all risk.',
        '3. THIRD-PARTY CODE: plugins are authored by others. Review source.',
        '4. NO REDISTRIBUTION of patched Discord binaries.',
        '5. LICENSES: setup code MIT; Vencord GPL-3.0; DiscordTabs source headers',
        '   declare GPL-3.0-or-later; other plugins have no license file.',
        '6. NO MALICIOUS USE: do not use this to harm others or violate terms.',
        '7. AGE: you must be old enough to use Discord in your region.',
        '8. ACCEPTANCE: continuing = you accept all terms above.'
    ) 'Cyan'

    Write-Box 'CREDITS' @(
        'Vencord by Vendicated (GPL-3.0) - github.com/Vendicated/Vencord',
        'Quest-Auto-Complete by BlockTol - github.com/BlockTol/Quest-Auto-Complete',
        'Discord-Fake-Deafen by BlockTol - github.com/BlockTol/Discord-Fake-Deafen',
        'Discord-Server-Cloner by BlockTol - github.com/BlockTol/Discord-Server-Cloner',
        'DiscordTabs by BlockTol - github.com/BlockTol/DiscordTabs',
        'bigFileUpload by ScattrdBlade - github.com/ScattrdBlade/bigFileUpload',
        'Icons: iconoir.com outline reference. Sounds: bencho.dev reference.',
        'Setup code: MIT (c) 2026 yetilukoss.'
    ) 'Cyan'

    if (-not $Yes) {
        Write-Host '  Type ' -NoNewline
        Write-Host 'AGREE' -ForegroundColor Yellow -NoNewline
        Write-Host ' to accept and continue, or anything else to exit.' -ForegroundColor White
        $answer = Read-Host '  >'
        if ($answer -ne 'AGREE') { throw 'Terms not accepted. No changes were made.' }
    }
    Play-Sound 'success'
}

function Test-SafeTarget([string]$path) {
    if ([string]::IsNullOrWhiteSpace($path)) { return $false }
    try {
        $full = [System.IO.Path]::GetFullPath($path).TrimEnd('\')
        if ($full -match '^[A-Za-z]:$') { return $false }
        $protected = @(
            $env:SystemRoot,
            $env:ProgramFiles,
            [Environment]::GetEnvironmentVariable('ProgramFiles(x86)'),
            $env:USERPROFILE,
            $env:APPDATA,
            $env:LOCALAPPDATA,
            $env:ProgramData
        )
        foreach ($base in $protected) {
            if ([string]::IsNullOrWhiteSpace($base)) { continue }
            $baseFull = [System.IO.Path]::GetFullPath($base).TrimEnd('\')
            if ($full -ieq $baseFull) { return $false }
            if ($full.StartsWith($baseFull + '\', [System.StringComparison]::OrdinalIgnoreCase) -and
                ($baseFull -ieq [System.IO.Path]::GetFullPath($env:SystemRoot).TrimEnd('\'))) { return $false }
        }
        $cursor = $full
        while ($cursor) {
            $item = Get-Item -LiteralPath $cursor -Force -ErrorAction SilentlyContinue
            if ($item -and ($item.Attributes -band [System.IO.FileAttributes]::ReparsePoint)) { return $false }
            $parent = Split-Path -Parent $cursor
            if (-not $parent -or $parent -eq $cursor) { break }
            $cursor = $parent
        }
        return $true
    } catch { return $false }
}

function Select-TargetFolder {
    if (-not [string]::IsNullOrWhiteSpace($Target)) {
        if (-not (Test-SafeTarget $Target)) { throw "Refusing to use unsafe target path: $Target" }
        Write-Ok "Target: $Target"
        return $Target
    }

    $parent = [Environment]::GetFolderPath('Desktop')
    try {
        Add-Type -AssemblyName System.Windows.Forms -ErrorAction Stop | Out-Null
        $dlg = New-Object System.Windows.Forms.FolderBrowserDialog
        try {
            $dlg.Description = 'Select parent folder for the Vencord setup'
            $dlg.RootFolder = [System.Environment+SpecialFolder]::Desktop
            $dlg.ShowNewFolderButton = $true
            $result = $dlg.ShowDialog()
            if ($result -eq [System.Windows.Forms.DialogResult]::OK -and $dlg.SelectedPath) { $parent = $dlg.SelectedPath }
        } finally {
            $dlg.Dispose()
        }
    } catch {
        Write-Warn 'Folder picker unavailable. Using Desktop.'
    }

    $target = Join-Path $parent 'Vencord'
    if (-not (Test-SafeTarget $target)) { throw "Refusing to use unsafe target path: $target" }
    Write-Ok "Target: $target"
    Play-Sound 'navigate'
    return $target
}

$Plugins = @(
    @{ Name = 'Quest-Auto-Complete';  Repo = 'https://github.com/BlockTol/Quest-Auto-Complete.git';   Enabled = $true }
    @{ Name = 'Discord-Fake-Deafen';   Repo = 'https://github.com/BlockTol/Discord-Fake-Deafen.git';    Enabled = $true }
    @{ Name = 'Discord-Server-Cloner'; Repo = 'https://github.com/BlockTol/Discord-Server-Cloner.git'; Enabled = $true }
    @{ Name = 'DiscordTabs';          Repo = 'https://github.com/BlockTol/DiscordTabs.git';            Enabled = $true }
    @{ Name = 'bigFileUpload';        Repo = 'https://github.com/ScattrdBlade/bigFileUpload.git';     Enabled = $true }
)

function Show-PluginMenu {
    if ($Yes) {
        Write-Info ('Plugins: ' + (($Plugins | Where-Object { $_.Enabled } | ForEach-Object { $_.Name }) -join ', '))
        return
    }
    while ($true) {
        Write-Box 'Plugins to install' @(
            'Toggle plugins with their number. All enabled by default.',
            'Press Enter when done.'
        ) 'Cyan'
        for ($i = 0; $i -lt $Plugins.Count; $i++) {
            $p = $Plugins[$i]
            $mark = if ($p.Enabled) { '[x]' } else { '[ ]' }
            Write-Host ("  {0}. {1} {2}" -f ($i + 1), $mark, $p.Name) -ForegroundColor White
        }
        Write-Host ''
        $answer = Read-Host '  Toggle number or Enter to continue'
        if ([string]::IsNullOrWhiteSpace($answer)) { break }
        $n = 0
        if ([int]::TryParse($answer, [ref]$n) -and $n -ge 1 -and $n -le $Plugins.Count) {
            $Plugins[$n - 1].Enabled = -not $Plugins[$n - 1].Enabled
            Play-Sound 'click'
        }
    }
    Play-Sound 'navigate'
}

function Get-EnabledPlugins {
    $enabled = @($Plugins | Where-Object { $_.Enabled })
    if ($enabled.Count -eq 0) { Write-Warn 'No plugins selected. Vencord core will still be installed.' }
    return $enabled
}

function Repair-PluginCompat([string]$userPluginsDir) {
    if ([string]::IsNullOrWhiteSpace($userPluginsDir) -or -not (Test-Path -LiteralPath $userPluginsDir)) { return }
    $patches = @(
        @{
            File  = 'Discord-Fake-Deafen\index.tsx'
            Rules = @(
                @{ Old = 'import { Button, Menu, React } from "@webpack/common";'; New = "import { Button } from `"@components/Button`";`nimport { Menu, React } from `"@webpack/common`";" }
                @{ Old = 'import { ModalContent, ModalFooter, ModalHeader, ModalProps, ModalRoot, openModal } from "@utils/modal";'; New = "import { ModalContent, ModalFooter, ModalHeader, ModalRoot, openModal } from `"@utils/modal`";`nimport type { RenderModalProps as ModalProps } from `"@vencord/discord-types`";" }
                @{ Old = '<Button color={Button.Colors.PRIMARY}'; New = '<Button variant="secondary"' }
                @{ Old = '<Button color={Button.Colors.GREEN}'; New = '<Button variant="positive"' }
            )
        }
        @{
            File  = 'Discord-Server-Cloner\components\CloneModal.tsx'
            Rules = @(
                @{ Old = 'import { React, GuildStore, GuildRoleStore, UserStore, SearchableSelect, Checkbox, Button } from "@webpack/common";'; New = "import { Button } from `"@components/Button`";`nimport { React, GuildStore, GuildRoleStore, UserStore, SearchableSelect, Checkbox } from `"@webpack/common`";" }
                @{ Old = 'import { ModalContent, ModalFooter, ModalHeader, ModalProps, ModalRoot, openModal } from "@utils/modal";'; New = "import { ModalContent, ModalFooter, ModalHeader, ModalRoot, openModal } from `"@utils/modal`";`nimport type { RenderModalProps as ModalProps } from `"@vencord/discord-types`";" }
                @{ Old = 'color={Button.Colors.PRIMARY}'; New = 'variant="secondary"' }
                @{ Old = 'color={Button.Colors.RED}'; New = 'variant="dangerPrimary"' }
                @{ Old = 'color={Button.Colors.BRAND}'; New = 'variant="primary"' }
            )
        }
    )
    foreach ($patch in $patches) {
        $file = Join-Path $userPluginsDir $patch.File
        if (-not (Test-Path -LiteralPath $file)) { continue }
        try {
            $raw = [System.IO.File]::ReadAllText($file)
            $nl = if ($raw.Contains("`r`n")) { "`r`n" } else { "`n" }
            $changed = $false
            foreach ($rule in $patch.Rules) {
                if ($raw.Contains($rule.New)) { continue }
                $count = ([regex]::Matches($raw, [regex]::Escape($rule.Old))).Count
                if ($count -eq 0) { continue }
                $raw = $raw.Replace($rule.Old, $rule.New.Replace("`n", $nl))
                $changed = $true
                Write-Ok ("  compat patch: {0} [{1} hit(s)]" -f $patch.File, $count)
            }
            if ($changed) { [System.IO.File]::WriteAllText($file, $raw, (New-Object System.Text.UTF8Encoding($false))) }
        } catch {
            Write-Warn ("  compat patch failed for {0}: {1}" -f $patch.File, $_.Exception.Message)
            $script:FailedSteps.Add("compat patch: $($patch.File)")
        }
    }
}

function Get-DiscordResourceDir([string]$branch = 'auto') {
    $rootName = switch ($branch) {
        'stable' { 'Discord' }
        'canary' { 'DiscordCanary' }
        'ptb'    { 'DiscordPTB' }
        default  { 'Discord' }
    }
    $roots = if ($branch -eq 'auto') {
        @(Join-Path $env:LOCALAPPDATA 'Discord'; Join-Path $env:LOCALAPPDATA 'DiscordCanary'; Join-Path $env:LOCALAPPDATA 'DiscordPTB')
    } else {
        @(Join-Path $env:LOCALAPPDATA $rootName)
    }
    foreach ($root in $roots) {
        if (-not (Test-Path -LiteralPath $root)) { continue }
        $dirs = [System.Collections.Generic.List[string]]::new()
        $appLink = Join-Path $root 'app'
        if (Test-Path -LiteralPath $appLink) { $dirs.Add($appLink) }
        Get-ChildItem -LiteralPath $root -Directory -Filter 'app-*' -ErrorAction SilentlyContinue | ForEach-Object { $dirs.Add($_.FullName) }
        foreach ($dir in ($dirs | Sort-Object { $_ } -Descending)) {
            $resources = Join-Path $dir 'resources'
            if (Test-Path -LiteralPath (Join-Path $resources 'app.asar')) { return $resources }
        }
    }
    return $null
}

function Backup-DiscordAsar([string]$branch = 'auto') {
    $resources = Get-DiscordResourceDir $branch
    if (-not $resources) { Write-Warn "Discord resources not found for $branch. Skipping asar backup."; return $null }
    $asar = Join-Path $resources 'app.asar'
    if (-not (Test-Path -LiteralPath $asar)) { Write-Warn 'app.asar not found. Skipping backup.'; return $null }
    $stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
    $backupRoot = Join-Path $env:APPDATA 'VencordSetup\Backups'
    New-Item -ItemType Directory -Path $backupRoot -Force | Out-Null
    $dest = Join-Path $backupRoot ("app.asar." + $branch + "." + $stamp)
    Copy-Item -LiteralPath $asar -Destination $dest -Force
    if (-not (Test-Path -LiteralPath $dest)) { throw 'Could not back up app.asar.' }
    Write-Ok "app.asar backup: $dest"
    return $dest
}

function Invoke-Build([string]$folder) {
    Push-Location -LiteralPath $folder
    try {
        Write-Step 'Installing dependencies (pnpm install)...'
        Play-Sound 'navigate'
        if ((Invoke-NativeConsole { cmd.exe /c "pnpm install" }) -ne 0) { throw 'pnpm install failed.' }
        Write-Ok 'Dependencies installed.'

        Write-Step 'Building Vencord (pnpm build)...'
        Play-Sound 'navigate'
        if ((Invoke-NativeConsole { cmd.exe /c "pnpm build" }) -ne 0) { throw 'pnpm build failed.' }
        Write-Ok 'Build complete.'
        Play-Sound 'success'
    } finally {
        Pop-Location
    }
}

function Invoke-VencordCli([string]$folder, [string]$useBranch, [switch]$Uninstall) {
    $cli = Join-Path $folder 'dist\Installer\VencordInstallerCli.exe'
    Push-Location -LiteralPath $folder
    try {
        Write-Step 'Checking official installer CLI (Vencord/Installer release)...'
        $rc = Invoke-NativeConsole { node scripts/runInstaller.mjs -- -version }
        if ($rc -ne 0 -or -not (Test-Path -LiteralPath $cli)) { throw 'Could not obtain VencordInstallerCli.exe.' }
        Backup-DiscordAsar $useBranch | Out-Null

        $oldData = $env:VENCORD_USER_DATA_DIR
        $oldDev = $env:VENCORD_DEV_INSTALL
        try {
            $env:VENCORD_USER_DATA_DIR = $folder
            $env:VENCORD_DEV_INSTALL = '1'
            $cliArgs = @('-branch', $useBranch)
            if ($Uninstall) {
                Write-Step "Uninstalling Vencord from local Discord ($useBranch)..."
                $cliArgs += @('-uninstall')
            } else {
                Write-Step "Injecting into local Discord ($useBranch)..."
                $cliArgs += @('-install')
            }
            Play-Sound 'navigate'
            $rc = Invoke-NativeConsole { & $cli @cliArgs }
            if ($rc -ne 0) { throw "VencordInstallerCli failed with exit $rc." }
            Write-Ok $(if ($Uninstall) { 'Vencord uninstalled.' } else { "Injected ($useBranch)." })
            Play-Sound 'success'
        } finally {
            $env:VENCORD_USER_DATA_DIR = $oldData
            $env:VENCORD_DEV_INSTALL = $oldDev
        }
    } finally {
        Pop-Location
    }
}

function Get-BuildTemp([string]$target) {
    $parent = Split-Path -Parent $target
    $leaf = Split-Path -Leaf $target
    return Join-Path $parent ($leaf + '.build_' + (Get-Date -Format 'yyyyMMdd-HHmmss'))
}

function Run-Install([string]$target, [array]$enabledPlugins) {
    Write-Box 'Install plan' @(
        "Target folder : $target",
        'Vencord clone : github.com/Vendicated/Vencord',
        "Plugins       : $($enabledPlugins.Count) selected",
        "Branch        : $Branch",
        'Steps         : clone -> compat -> build -> backup -> move -> inject'
    ) 'Cyan'
    if (-not (Confirm-Action 'Proceed')) { Write-Warn 'Cancelled.'; return }
    Play-Sound 'click'

    $temp = Get-BuildTemp $target
    $backupName = $null
    $moved = $false
    try {
        if (Test-Path -LiteralPath $temp) { throw "Temporary build folder already exists: $temp" }
        New-Item -ItemType Directory -Path $temp -Force | Out-Null

        Write-Step 'Cloning Vencord...'
        if ((Invoke-NativeConsole { git clone https://github.com/Vendicated/Vencord $temp }) -ne 0) { throw 'Vencord clone failed.' }
        Write-Ok 'Vencord cloned.'

        $up = Join-Path $temp 'src\userplugins'
        New-Item -ItemType Directory -Path $up -Force | Out-Null
        foreach ($plugin in $enabledPlugins) {
            Write-Step "Cloning $($plugin.Name)..."
            $dest = Join-Path $up $plugin.Name
            $rc = Invoke-NativeConsole { git clone $plugin.Repo $dest }
            if ($rc -ne 0) {
                Write-Warn "Clone failed for $($plugin.Name). Continuing."
                $script:FailedSteps.Add("clone: $($plugin.Name)")
                continue
            }
            Write-Ok "$($plugin.Name) cloned."
        }
        Repair-PluginCompat $up
        Invoke-Build $temp

        if (Test-Path -LiteralPath $target) {
            $items = @(Get-ChildItem -LiteralPath $target -Force -ErrorAction SilentlyContinue)
            if ($items.Count -gt 0) {
                if (-not (Confirm-Action "Target is not empty: $target. Overwrite")) { throw 'Overwrite declined.' }
                $backupName = 'Vencord.bak_' + (Get-Date -Format 'yyyyMMdd-HHmmss')
                $backupPath = Join-Path (Split-Path -Parent $target) $backupName
                Rename-Item -LiteralPath $target -NewName $backupName
                Write-Ok "Existing folder preserved as: $backupPath"
            }
        }

        Move-Item -LiteralPath $temp -Destination $target
        $moved = $true

        Invoke-VencordCli -folder $target -useBranch $Branch
    } catch {
        $script:FailedSteps.Add("install: $($_.Exception.Message)")
        throw
    } finally {
        if (-not $moved -and (Test-Path -LiteralPath $temp)) {
            try { Remove-Item -LiteralPath $temp -Recurse -Force } catch { }
        }
        if (-not $moved -and $backupName -and -not (Test-Path -LiteralPath $target)) {
            try { Rename-Item -LiteralPath (Join-Path (Split-Path -Parent $target) $backupName) -NewName (Split-Path -Leaf $target) } catch { }
        }
    }

    Write-Box 'DONE' @(
        'Setup complete. Fully close and reopen Discord.',
        'Enable plugins in: Settings -> Plugins.',
        "Folder: $target",
        'Update later with: .\VencordSetup.ps1 -Mode update'
    ) 'Green'
    Play-Sound 'complete'
}

function Run-Update([string]$target, [array]$enabledPlugins) {
    if (-not (Test-Path -LiteralPath $target)) { throw "Target folder does not exist: $target" }
    if (-not (Confirm-Action "Update Vencord and $($enabledPlugins.Count) selected plugins in $target")) { Write-Warn 'Cancelled.'; return }

    $up = Join-Path $target 'src\userplugins'
    New-Item -ItemType Directory -Path $up -Force | Out-Null
    $wanted = @($enabledPlugins | ForEach-Object { $_.Name })

    foreach ($plugin in $enabledPlugins) {
        $dir = Join-Path $up $plugin.Name
        if (-not (Test-Path -LiteralPath (Join-Path $dir '.git'))) {
            Write-Step "Cloning missing plugin: $($plugin.Name)"
            if ((Invoke-NativeConsole { git clone $plugin.Repo $dir }) -ne 0) {
                $script:FailedSteps.Add("update clone: $($plugin.Name)")
                Write-Warn "Clone failed: $($plugin.Name)"
            }
            continue
        }
        Write-Step "Updating $($plugin.Name)..."
        Push-Location -LiteralPath $dir
        try {
            $status = Invoke-NativeCapture { git status --porcelain }
            $stashed = $false
            if (-not [string]::IsNullOrWhiteSpace($status.Text)) {
                if ((Invoke-NativeConsole { git stash push -u -m 'VencordSetup auto-stash' }) -eq 0) { $stashed = $true }
            }
            if ((Invoke-NativeConsole { git pull --ff-only }) -ne 0) { $script:FailedSteps.Add("pull: $($plugin.Name)"); Write-Warn "Pull failed: $($plugin.Name)" }
            if ($stashed) {
                $pop = Invoke-NativeConsole { git stash pop }
                if ($pop -ne 0) { throw "Stash pop conflict in $($plugin.Name). Resolve manually before continuing." }
            }
        } finally { Pop-Location }
    }

    Get-ChildItem -LiteralPath $up -Directory | ForEach-Object {
        if ($wanted -notcontains $_.Name) { Write-Info "Skipped (not selected): $($_.Name)" }
    }

    Write-Step 'Updating Vencord core...'
    Push-Location -LiteralPath $target
    try {
        $status = Invoke-NativeCapture { git status --porcelain }
        $stashed = $false
        if (-not [string]::IsNullOrWhiteSpace($status.Text)) {
            if ((Invoke-NativeConsole { git stash push -u -m 'VencordSetup auto-stash' }) -eq 0) { $stashed = $true }
        }
        if ((Invoke-NativeConsole { git pull --ff-only }) -ne 0) { $script:FailedSteps.Add('pull: Vencord core'); Write-Warn 'Core pull failed.' }
        if ($stashed) {
            $pop = Invoke-NativeConsole { git stash pop }
            if ($pop -ne 0) { throw 'Stash pop conflict in Vencord core. Resolve manually before continuing.' }
        }
    } finally { Pop-Location }

    Repair-PluginCompat $up
    Invoke-Build $target
    Invoke-VencordCli -folder $target -useBranch $Branch
    Write-Ok 'Update complete.'
    Play-Sound 'complete'
}

function Run-Uninstall([string]$target) {
    if (-not (Test-Path -LiteralPath $target)) { throw "Target folder does not exist: $target" }
    if (-not (Confirm-Action "Uninject Vencord from local Discord (source folder stays at $target)")) { Write-Warn 'Cancelled.'; return }
    Invoke-VencordCli -folder $target -useBranch $Branch -Uninstall
    Write-Ok 'Uninstall complete. Source folder preserved.'
    Play-Sound 'complete'
}

function Run-Reinject([string]$target) {
    if (-not (Test-Path -LiteralPath $target)) { throw "Target folder does not exist: $target" }
    Invoke-VencordCli -folder $target -useBranch $Branch
    Write-Ok 'Reinject complete.'
    Play-Sound 'complete'
}

function Run-Repair([string]$target) {
    if (-not (Test-Path -LiteralPath $target)) { throw "Target folder does not exist: $target" }
    Repair-PluginCompat (Join-Path $target 'src\userplugins')
    Invoke-Build $target
    Invoke-VencordCli -folder $target -useBranch $Branch
    Write-Ok 'Repair complete.'
    Play-Sound 'complete'
}

function Run-RepairPlugins([string]$target) {
    if (-not (Test-Path -LiteralPath $target)) { throw "Target folder does not exist: $target" }
    Repair-PluginCompat (Join-Path $target 'src\userplugins')
    Write-Ok 'Plugin compatibility repair complete.'
    Play-Sound 'complete'
}

function Show-DryRun([string]$target, [array]$enabledPlugins) {
    Write-Box 'DRY RUN - no changes will be made' @(
        "Mode          : $Mode",
        "Target folder : $target",
        "Branch        : $Branch",
        "Plugins       : $($enabledPlugins.Count) selected",
        'Would clone   : Vencord + selected plugins',
        'Would run     : pnpm install, pnpm build',
        'Would back up : app.asar and any replaced target folder',
        'Would inject  : official VencordInstallerCli.exe'
    ) 'Yellow'
    Write-Ok 'Dry run complete.'
}

function Invoke-Main {
    Clear-Host
    Write-Banner
    Play-Sound 'boot'

    Assert-Prerequisites
    Show-Terms

    $target = Select-TargetFolder
    $enabledPlugins = @()
    if ($Mode -in @('install', 'update', 'dry-run')) { Show-PluginMenu; $enabledPlugins = @(Get-EnabledPlugins) }

    switch ($Mode) {
        'install'        { Run-Install -target $target -enabledPlugins $enabledPlugins }
        'update'         { Run-Update -target $target -enabledPlugins $enabledPlugins }
        'uninstall'      { Run-Uninstall -target $target }
        'reinject'       { Run-Reinject -target $target }
        'repair'         { Run-Repair -target $target }
        'repair-plugins' { Run-RepairPlugins -target $target }
        'dry-run'        { Show-DryRun -target $target -enabledPlugins $enabledPlugins }
    }

    if ($script:FailedSteps.Count -gt 0) {
        Write-Box 'COMPLETED WITH WARNINGS' @($script:FailedSteps | ForEach-Object { " - $_" }) 'Yellow'
    }
}

try {
    Invoke-Main
} catch {
    $script:ExitCode = 1
    Write-Err $_.Exception.Message
    Play-Sound 'error'
} finally {
    try { while ((Get-Location).Path -ne (Split-Path -Parent $PSCommandPath) -and $PSCommandPath) { Pop-Location; break } } catch { }
    if ([Environment]::UserInteractive -and -not $Yes) {
        try { Write-Host ''; Write-Host '  Press any key to exit...' -ForegroundColor DarkGray; $null = $Host.UI.RawUI.ReadKey('NoEcho,IncludeKeyDown') } catch { }
    }
}

exit $script:ExitCode
