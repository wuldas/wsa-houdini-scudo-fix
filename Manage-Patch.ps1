#Requires -Version 5.1
<#
.SYNOPSIS
  Manage the wsa_houdini_vfork_scudo 0.4.0-experimental resident guard module
  on a running WSA instance through adb + root. Windows PowerShell 5.1 only.

.DESCRIPTION
  The module ships a static root ptrace guard daemon (bin/wsa-vfork-guard;
  scope: zygote64 descendants / Houdini clone guard) and no library overlay.

  Actions:
    Install    preflight the published ZIP (exact entry set, module.prop
               identity, manifest contract, daemon hash, verbatim installer,
               no system/*.so entries) BEFORE root; verify the pinned original
               Houdini on the device; push to a fixed private /data/local/tmp
               path (hash-verified); install via "su -c magisk --install-module";
               validate the staged pending module (identity, daemon ELF+SHA,
               manifest, no legacy overlay); enable the pending directory.
               Any post-root failure quarantines active/pending directories
               with the disable flag.
    Disable    create <module dir>/disable on active+pending directories AND
               gracefully SIGTERM the running guard after verifying its
               /proc/<pid>/exe identity; waits until the process is gone.
               Never SIGKILL, never force-stops apps.
    Enable     validate every installed module directory (daemon+manifest+layout)
               and the pinned original bridge, then remove the disable flag.
               The guard starts only after the next full manual WSA boot; this
               action never launches it.
    Uninstall  create <module dir>/remove, stop the guard exactly like Disable,
               and remove the pushed ZIP. Never uses --remove-modules.
    Status     module presence/flags/version, original bridge identity, guard
               runtime (pid, verified executable, ready token, guard.status,
               guard.log tail). Module enable flags and the live guard process
               are reported separately - an absent disable flag alone never
               implies an active guard.

  Guarantees:
    - SIGTERM is sent ONLY to a pid whose /proc/<pid>/exe resolves to this
      module's daemon (literal " (deleted)" suffix accepted). Never SIGKILL.
    - NEVER force-stops apps, NEVER reboots/restarts WSA, NEVER changes
      Zygisk/global properties/root policies.
    - Fails with a nonzero exit code and never reports success on failure.

.PARAMETER Action
  Install | Disable | Enable | Uninstall | Status

.PARAMETER AdbPath
  Path to adb.exe; default resolves adb via Get-Command.

.PARAMETER Serial
  adb serial of the WSA instance; default 127.0.0.1:58526.

.PARAMETER ZipPath
  (Install) module zip to install; defaults to the published 0.4.0 package in out\dist.

.EXAMPLE
  .\Manage-Patch.ps1 Status
  .\Manage-Patch.ps1 Install -ZipPath .\out\dist\wsa_houdini_vfork_scudo-0.4.0-experimental.zip
  .\Manage-Patch.ps1 Disable
#>
[CmdletBinding()]
param(
  [Parameter(Mandatory = $true, Position = 0)]
  [ValidateSet('Install', 'Disable', 'Enable', 'Uninstall', 'Status')]
  [string]$Action,

  [string]$AdbPath,
  [string]$Serial = '127.0.0.1:58526',
  [string]$ZipPath,
  [string]$ModuleId = 'wsa_houdini_vfork_scudo'
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# --- Pinned constants (must match Publish-Patch.ps1 / customize.sh) ------------
$ModuleVersion     = '0.4.0-experimental'
$ModuleVersionCode = '4'
$BridgePath        = '/vendor/lib64/libhoudini.so'
$BridgeSha256      = '5ef64035ec89bca3d5e33b9f3b6556f98f6c11d11957387d403ae4a4d7cc40ec'
$BridgeBuildId     = '19382d6a127b7398830586473f428f5201d86b5f'
$BridgeSize        = 9421784
$SyscallOffset     = '0x30d661'
$OriginalFlags     = '0x4111'
$EffectiveFlags    = '0x4011'
$StateDir          = '/data/adb/wsa_houdini_vfork_scudo'
$DaemonRel         = 'bin/wsa-vfork-guard'
$ExpectedReadyVer  = '0.4.0'
$InstallerSha256   = 'bcf4b1d9913f3af17755569c853e0b5a75b8005f6a18eb3f86dadcc0e968c29d' # verbatim Magisk 30.6 module_installer.sh
$ManifestKeys      = @('module_id','version','daemon_sha256','bridge_sha256','bridge_build_id','syscall_offset','original_flags','effective_flags','state_dir')

$RemoteZip           = "/data/local/tmp/$ModuleId.zip"
$RemoteModule        = "/data/adb/modules/$ModuleId"
$RemotePendingModule = "/data/adb/modules_update/$ModuleId"
$RemoteDaemon        = "$RemoteModule/$DaemonRel"
$RemotePendingDaemon = "$RemotePendingModule/$DaemonRel"
$LocalDist           = Join-Path $PSScriptRoot 'out\dist'

$AllowedZipEntries = @(
  'LICENSE',
  'THIRD_PARTY_NOTICES.md',
  'licenses/LGPL-2.1.txt',
  'licenses/glibc-COPYRIGHT.txt',
  'licenses/GCC-COPYRIGHT.txt',
  'META-INF/com/google/android/update-binary',
  'META-INF/com/google/android/updater-script',
  'bin/wsa-vfork-guard',
  'customize.sh',
  'manifest.json',
  'module.prop',
  'payload.sha256',
  'post-fs-data.sh',
  'scripts/guard-ensure.sh',
  'service.sh'
)
$script:InstallationMayBeStaged = $false

function Die([string]$m) {
  Write-Host "[manage] ERROR: $m" -ForegroundColor Red
  if ($script:InstallationMayBeStaged) {
    $command = 'for p in {0} {1}; do if [ -d $p ]; then touch $p/disable && test -f $p/disable || exit 1; fi; done' -f $RemoteModule, $RemotePendingModule
    try { $quarantine = Invoke-AdbSu -RemoteCommand $command }
    catch { $quarantine = [pscustomobject]@{ ExitCode = 1 } }
    if ($quarantine.ExitCode -eq 0) {
      Write-Host '[manage] failed installation quarantined: active/pending module disabled; do not enable it' -ForegroundColor Yellow
    } else {
      Write-Host '[manage] CRITICAL: could not quarantine the staged module; do not restart WSA until it is disabled' -ForegroundColor Red
    }
  }
  exit 1
}
function Info([string]$m) { Write-Host "[manage] $m" }
function Warn([string]$m) { Write-Host "[manage] WARN: $m" -ForegroundColor Yellow }

function RebootNotice {
  Write-Host ''
  Write-Host '[manage] ACTION REQUIRED: fully restart Windows Subsystem for Android for module state changes to take effect.' -ForegroundColor Yellow
  Write-Host '[manage] The guard daemon starts only from the boot scripts of a full manual restart; this tool never restarts WSA or force-stops apps.' -ForegroundColor Yellow
}

function Sha256Hex([string]$p) {
  $stream = [System.IO.File]::OpenRead($p)
  $sha = [System.Security.Cryptography.SHA256]::Create()
  try {
    return [BitConverter]::ToString($sha.ComputeHash($stream)).Replace('-', '').ToLowerInvariant()
  } finally {
    $sha.Dispose()
    $stream.Dispose()
  }
}

function Read-ManifestContract([string]$JsonText, [string]$ExpectedDaemonSha) {
  $manifest = $JsonText | ConvertFrom-Json
  $props = @($manifest.PSObject.Properties)
  if ($props.Count -ne $ManifestKeys.Count) {
    throw "manifest must carry exactly $($ManifestKeys.Count) lowercase keys, found $($props.Count)"
  }
  $expected = @{
    module_id       = $ModuleId
    version         = $ModuleVersion
    bridge_sha256   = $BridgeSha256
    bridge_build_id = $BridgeBuildId
    syscall_offset  = $SyscallOffset
    original_flags  = $OriginalFlags
    effective_flags = $EffectiveFlags
    state_dir       = $StateDir
  }
  foreach ($key in $ManifestKeys) {
    $p = $manifest.PSObject.Properties[$key]
    if (-not $p) { throw "manifest missing key '$key'" }
    if ($p.Value -isnot [string] -or -not $p.Value) { throw "manifest value for '$key' must be a non-empty string" }
    if ($expected.ContainsKey($key) -and $p.Value -cne $expected[$key]) {
      throw "manifest value for '$key' is '$($p.Value)', expected '$($expected[$key])'"
    }
  }
  if ($manifest.daemon_sha256 -cnotmatch '^[0-9a-f]{64}$') { throw 'manifest daemon_sha256 is not a lowercase sha256' }
  if ($ExpectedDaemonSha -and $manifest.daemon_sha256 -ne $ExpectedDaemonSha) {
    throw "manifest daemon_sha256 does not match the actual daemon bytes ($($manifest.daemon_sha256) vs $ExpectedDaemonSha)"
  }
  return $manifest
}

# --- ZIP preflight (pre-root gate) ---------------------------------------------
function Read-ZipText($archive, [string]$Name) {
  $entry = $archive.GetEntry($Name)
  if (-not $entry) { throw "module ZIP entry missing: $Name" }
  $reader = [IO.StreamReader]::new($entry.Open())
  try { return $reader.ReadToEnd().Replace("`r", '') } finally { $reader.Dispose() }
}

function Get-ZipEntrySha($archive, [string]$Name) {
  $entry = $archive.GetEntry($Name)
  if (-not $entry) { return $null }
  $stream = $entry.Open()
  $sha = [Security.Cryptography.SHA256]::Create()
  try { return [BitConverter]::ToString($sha.ComputeHash($stream)).Replace('-', '').ToLowerInvariant() }
  finally { $sha.Dispose(); $stream.Dispose() }
}

function Assert-InstallZip([string]$Path) {
  Add-Type -AssemblyName System.IO.Compression.FileSystem
  $archive = $null
  try {
    $archive = [System.IO.Compression.ZipFile]::OpenRead($Path)
    $seen = [System.Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
    foreach ($entry in $archive.Entries) {
      if ($entry.FullName.EndsWith('/')) { throw "unexpected directory entry: $($entry.FullName)" }
      if ($entry.FullName -match '^system/' -or $entry.FullName -match '\.so$') {
        throw "forbidden overlay-style ZIP entry: $($entry.FullName)"
      }
      if (-not $seen.Add($entry.FullName)) { throw "duplicate module ZIP entry: $($entry.FullName)" }
      if ($AllowedZipEntries -cnotcontains $entry.FullName) { throw "unsupported module ZIP entry: $($entry.FullName)" }
    }
    foreach ($name in $AllowedZipEntries) {
      if (-not $seen.Contains($name)) { throw "module ZIP entry missing: $name" }
    }

    $propText = Read-ZipText $archive 'module.prop'
    $ids      = [regex]::Matches($propText, '(?m)^id=(.*)$')
    $versions = [regex]::Matches($propText, '(?m)^version=(.*)$')
    $codes    = [regex]::Matches($propText, '(?m)^versionCode=(.*)$')
    if ($ids.Count -ne 1 -or $ids[0].Groups[1].Value -cne $ModuleId) { throw "ZIP module.prop id mismatch" }
    if ($versions.Count -ne 1 -or $versions[0].Groups[1].Value.Trim() -ne $ModuleVersion) { throw "ZIP module.prop version mismatch (expected $ModuleVersion)" }
    if ($codes.Count -ne 1 -or $codes[0].Groups[1].Value.Trim() -ne $ModuleVersionCode) { throw "ZIP module.prop versionCode mismatch (expected $ModuleVersionCode)" }

    $daemonSha = Get-ZipEntrySha $archive $DaemonRel
    if (-not $daemonSha) { throw 'cannot hash the daemon ZIP entry' }
    $manifestText = Read-ZipText $archive 'manifest.json'
    $null = Read-ManifestContract $manifestText $daemonSha

    $payloadShaText = (Read-ZipText $archive 'payload.sha256').Trim()
    if ($payloadShaText -ne $daemonSha) { throw 'payload.sha256 does not match the daemon entry hash' }

    $installerSha = Get-ZipEntrySha $archive 'META-INF/com/google/android/update-binary'
    if ($installerSha -ne $InstallerSha256) { throw 'ZIP update-binary is not the verbatim Magisk 30.6 installer' }

    if ((Read-ZipText $archive 'customize.sh') -match '__EXPECTED_') { throw 'customize.sh carries unreplaced checksum placeholders' }
    if ((Read-ZipText $archive 'scripts/guard-ensure.sh') -match '__EXPECTED_') { throw 'guard-ensure.sh carries unreplaced checksum placeholders' }

    Info "ZIP identity ($ModuleId $ModuleVersion), layout ($($AllowedZipEntries.Count) entries, no system/*.so) and daemon hash ($daemonSha) verified before root installation"
  } catch {
    Die ("module ZIP preflight failed: " + $_.Exception.Message)
  } finally {
    if ($archive) { $archive.Dispose() }
  }
}

# --- adb plumbing ----------------------------------------------------------------
function Invoke-Adb {
  param([Parameter(Mandatory = $true)][string[]]$Arguments)
  $oldEap = $ErrorActionPreference
  $ErrorActionPreference = 'Continue'   # adb stderr must not abort the script
  try {
    $raw = & $Adb @Arguments 2>&1
    $rc  = $LASTEXITCODE
  } finally {
    $ErrorActionPreference = $oldEap
  }
  $lines = @()
  foreach ($item in @($raw)) { $lines += ([string]$item).TrimEnd("`r") }
  return [pscustomobject]@{ ExitCode = $rc; Lines = $lines; Text = ($lines -join "`n") }
}

# Encode the root script so Windows PowerShell 5.1 native argv cannot strip its quotes.
function Invoke-AdbSu {
  param([Parameter(Mandatory = $true)][string]$RemoteCommand)
  $encoded = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($RemoteCommand))
  return Invoke-Adb -Arguments @('-s', $Serial, 'shell', "su -c 'echo $encoded | base64 -d | sh'")
}

function Ensure-Device {
  $st = Invoke-Adb -Arguments @('-s', $Serial, 'get-state')
  if ($st.ExitCode -ne 0 -or $st.Text.Trim() -ne 'device') {
    Info "device '$Serial' not in 'device' state; trying one 'adb connect' ..."
    $null = Invoke-Adb -Arguments @('connect', $Serial)
    $st = Invoke-Adb -Arguments @('-s', $Serial, 'get-state')
    if ($st.ExitCode -ne 0 -or $st.Text.Trim() -ne 'device') {
      Die "WSA adb device '$Serial' unavailable. Enable WSA developer mode, run 'adb connect $Serial' manually, then retry."
    }
  }
  Info "device $Serial ready"
}

function Ensure-Root {
  $id = Invoke-AdbSu -RemoteCommand 'id'
  if ($id.ExitCode -ne 0 -or $id.Text -notmatch '(?m)^uid=0\(') {
    Die "root (su) not available on $Serial; Magisk root is required for this action"
  }
}

# --- remote file helpers -----------------------------------------------------------
function Get-RemoteText([string]$Path) {
  $r = Invoke-AdbSu -RemoteCommand "cat $Path 2>/dev/null"
  if ($r.ExitCode -ne 0) { return '' }
  return ($r.Text.Replace("`r", ''))
}

function Get-RemoteSha([string]$Path) {
  $r = Invoke-AdbSu -RemoteCommand "sha256sum $Path 2>/dev/null"
  if ($r.ExitCode -ne 0) { return $null }
  $line = @($r.Lines | Where-Object { $_ -match '^[0-9a-f]{64}\s' })[0]
  if (-not $line) { return $null }
  return (($line -split '\s+')[0]).ToLowerInvariant()
}

function Test-RemoteFile([string]$Path) {
  return (Invoke-AdbSu -RemoteCommand "test -f $Path").ExitCode -eq 0
}

function Test-RemoteDir([string]$Path) {
  return (Invoke-AdbSu -RemoteCommand "test -d $Path").ExitCode -eq 0
}

# --- module queries -----------------------------------------------------------------
function Get-ModuleDirectories {
  $command = 'for p in {0} {1}; do if [ -f $p/module.prop ]; then echo $p; fi; done' -f $RemoteModule, $RemotePendingModule
  $r = Invoke-AdbSu -RemoteCommand $command
  if ($r.ExitCode -ne 0) { Die 'cannot query active/pending module directories' }
  return @($r.Lines | Where-Object { $_ -eq $RemoteModule -or $_ -eq $RemotePendingModule })
}

function Test-ModuleInstalled {
  return @(Get-ModuleDirectories).Count -gt 0
}

function Get-ModuleFlags {
  $command = 'for p in {0} {1}; do if [ -d $p ]; then ls -1 $p; fi; done' -f $RemoteModule, $RemotePendingModule
  $r = Invoke-AdbSu -RemoteCommand $command
  if ($r.ExitCode -ne 0) { Die 'cannot query module flags' }
  $names = @($r.Lines | Where-Object { $_ })
  return @{
    Disable = ($names -contains 'disable')
    Remove  = ($names -contains 'remove')
    Update  = ($names -contains 'update')
  }
}

function Get-ModuleVersion {
  foreach ($directory in @(Get-ModuleDirectories)) {
    if ($directory -eq $RemotePendingModule) {
      $meta = Get-RemoteText "$directory/module.prop"
      $m = [regex]::Match($meta, '(?m)^version=(.*)$')
      if ($m.Success) { return $m.Groups[1].Value.Trim() }
    }
  }
  $meta = Get-RemoteText "$RemoteModule/module.prop"
  $m = [regex]::Match($meta, '(?m)^version=(.*)$')
  if ($m.Success) { return $m.Groups[1].Value.Trim() }
  return '<unreadable>'
}

# Validate one installed module directory: identity, layout (daemon module only,
# no legacy overlay), daemon ELF magic + SHA, manifest contract, permissions.
function Assert-InstalledModuleState([string]$Directory) {
  $meta = Get-RemoteText "$Directory/module.prop"
  if (-not $meta -or
      $meta -cnotmatch ('(?m)^id=' + [regex]::Escape($ModuleId) + '$') -or
      $meta -notmatch ('(?m)^version=' + [regex]::Escape($ModuleVersion) + '\s*$') -or
      $meta -notmatch ('(?m)^versionCode=' + $ModuleVersionCode + '\s*$')) {
    throw "$Directory is not module $ModuleId $ModuleVersion (versionCode $ModuleVersionCode)"
  }
  foreach ($rel in @($DaemonRel, 'manifest.json', 'payload.sha256', 'post-fs-data.sh', 'service.sh', 'scripts/guard-ensure.sh')) {
    if (-not (Test-RemoteFile "$Directory/$rel")) { throw "$Directory is missing $rel" }
  }
  if (Test-RemoteDir "$Directory/system") { throw "$Directory still contains a legacy system/ overlay" }
  $soCheck = Invoke-AdbSu -RemoteCommand "find $Directory -name '*.so' -print"
  if ($soCheck.ExitCode -ne 0) { throw 'cannot verify the installed payload layout' }
  if (@($soCheck.Lines | Where-Object { $_ }).Count -gt 0) {
    throw "$Directory contains .so payload file(s): $(@($soCheck.Lines | Where-Object { $_ })[0])"
  }
  $magic = Invoke-AdbSu -RemoteCommand ("dd if={0}/{1} bs=1 count=4 2>/dev/null | od -An -tx1" -f $Directory, $DaemonRel)
  if (($magic.Text -replace '\s', '') -notmatch '7f454c46') { throw "$Directory/$DaemonRel is not an ELF file" }
  $execBit = Invoke-AdbSu -RemoteCommand ("test -x {0}/{1}" -f $Directory, $DaemonRel)
  if ($execBit.ExitCode -ne 0) { throw "$Directory/$DaemonRel is not executable" }
  $daemonSha = Get-RemoteSha "$Directory/$DaemonRel"
  if (-not $daemonSha) { throw "cannot hash $Directory/$DaemonRel" }
  $manifest = Read-ManifestContract (Get-RemoteText "$Directory/manifest.json") $daemonSha
  $payloadSha = (Get-RemoteText "$Directory/payload.sha256").Trim()
  if ($payloadSha -ne $daemonSha) { throw "$Directory/payload.sha256 does not match the installed daemon bytes" }
  return $manifest
}

# --- bridge identity ------------------------------------------------------------------
function Get-BridgeIdentity {
  $sha = Get-RemoteSha $BridgePath
  $size = $null
  $sr = Invoke-AdbSu -RemoteCommand ("stat -c %s {0} 2>/dev/null" -f $BridgePath)
  if ($sr.ExitCode -eq 0) {
    $sizeLines = @($sr.Lines | Where-Object { $_ -match '^\d+$' })
    if ($sizeLines.Count -eq 1) { $size = [long]$sizeLines[0] }
  }
  return [pscustomobject]@{ Sha = $sha; Size = $size }
}

# --- guard runtime ----------------------------------------------------------------------
function Get-GuardRuntime {
  $command = ('pid=""; if [ -f {0}/guard.pid ]; then pid=$(cat {0}/guard.pid) || exit 1; case "$pid" in *[!0-9]*|""|0|1) exit 1;; esac; fi; ' +
              'alive=0; exe=""; if [ -n "$pid" ] && [ -d /proc/$pid ]; then alive=1; exe=$(readlink /proc/$pid/exe 2>/dev/null) || exit 1; fi; ' +
              'ready=""; if [ -f {0}/guard.ready ]; then ready=$(cat {0}/guard.ready) || exit 1; fi; ' +
              'echo "pid=$pid"; echo "alive=$alive"; echo "exe=$exe"; echo "ready=$ready"') -f $StateDir
  $r = Invoke-AdbSu -RemoteCommand $command
  if ($r.ExitCode -ne 0) { throw 'cannot query guard runtime (not equivalent to no running guard)' }
  $map = @{}
  foreach ($l in $r.Lines) {
    if ($l -cmatch '^([a-z]+)=(.*)$') {
      if ($map.ContainsKey($matches[1])) { throw 'duplicate runtime result field' }
      $map[$matches[1]] = $matches[2]
    }
  }
  foreach ($key in @('pid','alive','exe','ready')) {
    if (-not $map.ContainsKey($key)) { throw "runtime result missing $key" }
  }
  if ($map['alive'] -notin @('0','1')) { throw 'invalid runtime liveness field' }
  return [pscustomobject]@{ Pid = $map['pid']; Alive = ($map['alive'] -eq '1'); Exe = $map['exe']; Ready = $map['ready'] }
}


function Stop-VerifiedGuard {
  $g = Get-GuardRuntime
  $helperDirectory = $null
  foreach ($directory in @($RemoteModule, $RemotePendingModule)) {
    if (Test-RemoteFile "$directory/$DaemonRel") {
      $null = Assert-InstalledModuleState $directory
      $helperDirectory = $directory
      break
    }
  }
  if (-not $helperDirectory) {
    if ($g.Pid -or $g.Ready) { throw 'guard state exists but no verified native stop helper is available' }
    Info 'guard: no resident-module payload or runtime state'
    return
  }
  $stop = Invoke-AdbSu -RemoteCommand "$helperDirectory/$DaemonRel --stop --state-dir $StateDir"
  if ($stop.ExitCode -ne 0) { throw "verified pidfd stop failed: $($stop.Text)" }
  if ($stop.Text -notmatch '^guard: (stopped;|no running instance)') { throw 'native helper did not confirm guard shutdown' }
  foreach ($line in $stop.Lines) { Info $line }
}

# --- actions ------------------------------------------------------------------------------
function Invoke-Install {
  Ensure-Device
  if (-not $ZipPath) {
    $zipFull = Join-Path $LocalDist ('{0}-{1}.zip' -f $ModuleId, $ModuleVersion)
    if (-not (Test-Path -LiteralPath $zipFull -PathType Leaf)) {
      Die "published package missing: $zipFull; run Publish-Patch.ps1 -DaemonPath <static-elf> first"
    }
    Info "using published package: $zipFull"
  } else {
    if (-not (Test-Path -LiteralPath $ZipPath -PathType Leaf)) { Die "zip not found: $ZipPath" }
    $zipFull = (Resolve-Path -LiteralPath $ZipPath).Path
  }
  Assert-InstallZip $zipFull

  Ensure-Root
  $bridge = Get-BridgeIdentity
  if ($bridge.Sha -ne $BridgeSha256) {
    Die ("$BridgePath is not the pinned original (sha256='$($bridge.Sha)', expected $BridgeSha256); refusing to install")
  }
  if ($bridge.Size -ne $BridgeSize) {
    Die ("$BridgePath size is $($bridge.Size), expected $BridgeSize; refusing to install")
  }
  Info "pinned original bridge verified: sha256=$($bridge.Sha) ($($bridge.Size) B, BuildId $BridgeBuildId)"

  $localZipSha = Sha256Hex $zipFull
  Info "pushing module zip to $RemoteZip ..."
  $push = Invoke-Adb -Arguments @('-s', $Serial, 'push', $zipFull, $RemoteZip)
  if ($push.ExitCode -ne 0) { Die "adb push failed (exit=$($push.ExitCode)):`n$($push.Text)" }
  $remoteZipSha = Get-RemoteSha $RemoteZip
  if ($remoteZipSha -ne $localZipSha) { Die 'uploaded ZIP hash differs from the local file; push was corrupted' }
  Info 'upload hash verified'

  Info 'installing via magisk --install-module ...'
  $script:InstallationMayBeStaged = $true
  $inst = Invoke-AdbSu -RemoteCommand "magisk --install-module $RemoteZip"
  foreach ($l in $inst.Lines) { if ($l) { Info "  | $l" } }
  $aborted = $false
  foreach ($l in $inst.Lines) { if ($l -match '^\s*!') { $aborted = $true } }
  if ($inst.ExitCode -ne 0 -or $aborted) {
    Die "module installation failed (exit=$($inst.ExitCode), abort-line=$aborted)"
  }

  if (-not (Test-RemoteFile "$RemotePendingModule/module.prop")) {
    Die "pending module directory $RemotePendingModule not found after install"
  }
  try { $null = Assert-InstalledModuleState $RemotePendingModule }
  catch { Die ("post-install validation of the pending module failed: " + $_.Exception.Message) }
  Info 'pending module validated: identity, daemon ELF+SHA, manifest contract, no legacy overlay'

  $enable = Invoke-AdbSu -RemoteCommand "rm -f $RemotePendingModule/disable && test ! -e $RemotePendingModule/disable && test ! -e $RemotePendingModule/remove"
  if ($enable.ExitCode -ne 0) { Die 'could not confirm pending module enable/flags' }

  foreach ($d in @(Get-ModuleDirectories | Where-Object { $_ -eq $RemoteModule })) {
    $oldMeta = Get-RemoteText "$d/module.prop"
    $oldVersion = [regex]::Match($oldMeta, '(?m)^version=(.*)$').Groups[1].Value.Trim()
    if ($oldVersion -and $oldVersion -ne $ModuleVersion) {
      Info "existing module directory $d (version $oldVersion) is replaced by the staged update at the next full WSA boot; no legacy overlay survives it"
    }
  }
  Info "module $ModuleId $ModuleVersion staged OK (pending: $RemotePendingModule)"
  $script:InstallationMayBeStaged = $false
  RebootNotice
}

function Invoke-Disable {
  Ensure-Device
  Ensure-Root
  if (-not (Test-ModuleInstalled)) { Die "module $ModuleId is not installed" }
  foreach ($directory in @(Get-ModuleDirectories)) {
    $r = Invoke-AdbSu -RemoteCommand "touch $directory/disable"
    if ($r.ExitCode -ne 0) { Die 'failed to disable an active/pending module directory' }
  }
  if (-not (Get-ModuleFlags).Disable) { Die 'disable flag not present after touch' }
  Info 'module disabled (flag set on active/pending directories)'
  Stop-VerifiedGuard
  Info 'the guard will not start again until the module is re-enabled and WSA is fully restarted'
  RebootNotice
}

function Invoke-Enable {
  Ensure-Device
  Ensure-Root
  if (-not (Test-ModuleInstalled)) { Die "module $ModuleId is not installed" }
  $flags = Get-ModuleFlags
  if ($flags.Remove) { Die 'module is marked for removal (remove flag); reinstall the zip instead of enabling' }
  foreach ($directory in @(Get-ModuleDirectories)) {
    try { $null = Assert-InstalledModuleState $directory }
    catch { Die ("enable refused ($directory): " + $_.Exception.Message) }
  }
  $bridge = Get-BridgeIdentity
  if ($bridge.Sha -ne $BridgeSha256 -or $bridge.Size -ne $BridgeSize) {
    Die ("refusing to enable: $BridgePath is not the pinned original (sha256='$($bridge.Sha)', size=$($bridge.Size); expected $BridgeSha256 / $BridgeSize)")
  }
  Info "pinned original bridge verified: sha256=$($bridge.Sha) ($($bridge.Size) B)"
  foreach ($directory in @(Get-ModuleDirectories)) {
    $r = Invoke-AdbSu -RemoteCommand "rm -f $directory/disable"
    if ($r.ExitCode -ne 0) { Die 'failed to enable an active/pending module directory' }
  }
  if ((Get-ModuleFlags).Disable) { Die 'disable flag still present after removal' }
  Info 'module enabled; the guard daemon starts only after the NEXT FULL manual WSA restart (this action never launches it)'
  RebootNotice
}

function Invoke-Uninstall {
  Ensure-Device
  Ensure-Root
  if (-not (Test-ModuleInstalled)) { Die "module $ModuleId is not installed" }
  foreach ($directory in @(Get-ModuleDirectories)) {
    $r = Invoke-AdbSu -RemoteCommand "touch $directory/remove"
    if ($r.ExitCode -ne 0) { Die 'failed to mark an active/pending module directory for removal' }
  }
  if (-not (Get-ModuleFlags).Remove) { Die 'remove flag not present after touch' }
  Info 'module marked for removal; Magisk deletes it on the next boot (never --remove-modules; other modules untouched)'
  Stop-VerifiedGuard
  $cleanup = Invoke-AdbSu -RemoteCommand "rm -f $RemoteZip && test ! -e $RemoteZip"
  if ($cleanup.ExitCode -ne 0) { Die 'module removal is scheduled, but the uploaded ZIP could not be removed' }
  Info "pushed zip removed from $RemoteZip"
  RebootNotice
}

function Invoke-Status {
  Ensure-Device
  Info "serial: $Serial   module: $ModuleId"
  $mv = Invoke-AdbSu -RemoteCommand 'magisk -V 2>/dev/null'
  if ($mv.ExitCode -ne 0) {
    Die 'root/su unavailable; module status cannot be verified'
  }
  Info ("magisk: " + ((@($mv.Lines | Where-Object { $_ })) -join ' | '))

  if (Test-ModuleInstalled) {
    $flags = Get-ModuleFlags
    Info "module : INSTALLED (version $(Get-ModuleVersion))"
    Info ("flags : disable=" + [int]$flags.Disable + " remove=" + [int]$flags.Remove + " update=" + [int]$flags.Update)
    if     ($flags.Remove)  { Info 'state  : pending removal (deleted on next WSA boot)' }
    elseif ($flags.Disable) { Info 'state  : disabled (guard will not launch after the next full WSA restart)' }
    else                    { Info 'state  : enabled (boot scripts will run at the next full WSA restart)' }
  } else {
    Info 'module : NOT INSTALLED'
  }

  # Original bridge identity (the daemon pins, never rewrites, this file).
  $bridge = Get-BridgeIdentity
  if (-not $bridge.Sha) {
    Warn "cannot hash $BridgePath"
  } else {
    $class = 'NOT ORIGINAL (unexpected content - the guard refuses to launch against this)'
    if ($bridge.Sha -eq $BridgeSha256 -and $bridge.Size -eq $BridgeSize) { $class = 'pinned original' }
    Info ("bridge : $BridgePath sha256=$($bridge.Sha) size=$($bridge.Size) -> $class (pinned BuildId $BridgeBuildId)")
  }

  # Guard runtime - deliberately separate from the module enable flag:
  # an absent disable flag alone NEVER implies an active guard process.
  $g = Get-GuardRuntime
  $exeClean = ''
  if ($g.Exe) { $exeClean = $g.Exe -replace ' \(deleted\)$', '' }
  $verified = $false
  if ($g.Pid -and $g.Alive -and ($exeClean -eq $RemoteDaemon -or $exeClean -eq $RemotePendingDaemon)) { $verified = $true }
  if ($verified) {
    $readyNote = 'ready=<not yet>'
    if ($g.Ready) { $readyNote = "ready=$($g.Ready)"; if ($g.Ready -ne $ExpectedReadyVer) { $readyNote += " (expected $ExpectedReadyVer)" } }
    Info "guard  : RUNNING VERIFIED pid=$($g.Pid) exe=$exeClean $readyNote (scope: zygote64 descendants / Houdini clone guard)"
  } elseif ($g.Pid -and $g.Alive) {
    Info "guard  : pid=$($g.Pid) alive but executable '$($g.Exe)' is NOT this module's guard - it will never be signalled by this tool"
  } elseif ($g.Pid) {
    Info "guard  : STALE pid file (pid=$($g.Pid) not running)"
  } else {
    Info 'guard  : NOT RUNNING (no pid file)'
  }

  $st = Invoke-AdbSu -RemoteCommand ("cat {0}/guard.status 2>/dev/null" -f $StateDir)
  if ($st.ExitCode -eq 0 -and @($st.Lines | Where-Object { $_ }).Count -gt 0) {
    Info 'guard.status (plaintext counters/status from the daemon):'
    foreach ($l in @($st.Lines | Where-Object { $_ })) { Info "  | $l" }
  } else {
    Info 'guard.status: <absent>'
  }
  $lg = Invoke-AdbSu -RemoteCommand ("tail -n 5 {0}/guard.log 2>/dev/null" -f $StateDir)
  if ($lg.ExitCode -eq 0 -and @($lg.Lines | Where-Object { $_ }).Count -gt 0) {
    Info 'guard.log (last 5 lines):'
    foreach ($l in @($lg.Lines | Where-Object { $_ })) { Info "  | $l" }
  }

  Info 'note  : module enable flag alone does NOT prove the guard process is active; compare the "state" and "guard" lines above.'
  Info 'note  : all zygote64 descendants with the inherited bridge, including x86-only apps, can retain ptrace state while the guard is active.'
  Info 'note  : this tool never force-stops apps; WSA restarts are always manual.'
}

# --- entry ---------------------------------------------------------------------------------------
if ($ModuleId -cne 'wsa_houdini_vfork_scudo') { Die 'this tool manages only wsa_houdini_vfork_scudo (exact lowercase ID)' }
if ($AdbPath) {
  if (-not (Test-Path -LiteralPath $AdbPath -PathType Leaf)) { Die "AdbPath not found: $AdbPath" }
  $Adb = (Resolve-Path -LiteralPath $AdbPath).Path
} else {
  $cmd = Get-Command adb -ErrorAction SilentlyContinue
  if (-not $cmd) { Die 'adb not found on PATH; install platform-tools or pass -AdbPath' }
  $Adb = $cmd.Path
}

try {
  switch ($Action) {
    'Install'   { Invoke-Install }
    'Disable'   { Invoke-Disable }
    'Enable'    { Invoke-Enable }
    'Uninstall' { Invoke-Uninstall }
    'Status'    { Invoke-Status }
  }
  Info 'done.'
} catch {
  Die $_.Exception.Message
}
exit 0
