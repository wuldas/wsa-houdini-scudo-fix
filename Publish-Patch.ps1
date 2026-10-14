#Requires -Version 5.1
<#
.SYNOPSIS
  Build the installable Magisk module ZIP for wsa_houdini_vfork_scudo
  0.4.0-experimental around the static resident guard daemon.
  Windows PowerShell 5.1 / .NET only; no network, no Python.

.DESCRIPTION
  Pipeline (offline):
    1. Verify -DaemonPath is a Linux x86_64 static ET_EXEC ELF: ELF64LE magic,
       e_type=ET_EXEC, e_machine=EM_X86_64, no PT_INTERP, first PT_LOAD at
       file offset 0.
    2. Verify the module template: module.prop pins id / version / versionCode
       to this exact release; META-INF update-binary must be the verbatim
       Magisk 30.6 module_installer.sh; post-fs-data.sh / service.sh /
       scripts/guard-ensure.sh / customize.sh must carry their placeholder
       tokens; the template must contain no system/ overlay and no *.so.
    3. Stage a marker-guarded COPY of module\ into the stage directory (the
       tracked template is never mutated), place the daemon at
       bin/wsa-vfork-guard and inject the pinned checksums into customize.sh
       and scripts/guard-ensure.sh.
    4. Write manifest.json (exactly the nine contracted lowercase keys:
       module_id, version, daemon_sha256, bridge_sha256, bridge_build_id,
       syscall_offset, original_flags, effective_flags, state_dir) and
       payload.sha256 at the ZIP root; mirror both into out\dist.
    5. Create a deterministic ZIP (forward-slash entry names, LF text, UNIX
       mode bits, fixed timestamp) with the exact contracted payload and license entries,
       then re-open the archive and verify: exact entry set, no directory /
       system\/* / *.so entries, daemon entry hash, verbatim installer entry
       hash, manifest values, payload.sha256 content and exec bits.
    6. out\dist\<module_id>-<version>.zip

  Final outputs are never silently overwritten: re-run with -Force. -Force
  clears only the current release ZIP, manifest.json, payload.sha256 and the
  marker-verified staging directory. Other ZIPs and legacy module directories
  are never removed implicitly. Inputs and module templates are protected.

  This script does NOT install anything and does NOT touch a running WSA;
  installation and lifecycle are owned by Manage-Patch.ps1 / the operator.

.EXAMPLE
  .\Publish-Patch.ps1 -DaemonPath C:\path\to\wsa-vfork-guard
  .\Publish-Patch.ps1 -DaemonPath C:\path\to\wsa-vfork-guard -Force
#>
[CmdletBinding()]
param(
  [Parameter(Mandatory = $true, Position = 0)]
  [string]$DaemonPath,

  [string]$ModuleDir,
  [string]$OutputDir,
  [string]$StageDir,
  [switch]$Force
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$scriptDirectory = [System.IO.Path]::GetDirectoryName($PSCommandPath)
if (-not $ModuleDir) { $ModuleDir = Join-Path $scriptDirectory 'module' }
if (-not $OutputDir) { $OutputDir = Join-Path $scriptDirectory 'out\dist' }
if (-not $StageDir)  { $StageDir  = Join-Path $scriptDirectory 'out\stage' }

# --- Pinned constants (must match Manage-Patch.ps1 and the contract) ---------
$ModuleId         = 'wsa_houdini_vfork_scudo'
$ModuleVersion    = '0.4.0-experimental'
$ModuleVersionCode = '4'
$BridgeSha256     = '5ef64035ec89bca3d5e33b9f3b6556f98f6c11d11957387d403ae4a4d7cc40ec'
$BridgeBuildId    = '19382d6a127b7398830586473f428f5201d86b5f'
$BridgeSize       = 9421784
$SyscallOffset    = '0x30d661'
$OriginalFlags    = '0x4111'
$EffectiveFlags   = '0x4011'
$StateDir         = '/data/adb/wsa_houdini_vfork_scudo'
$DaemonEntry      = 'bin/wsa-vfork-guard'
$InstallerSha256  = 'bcf4b1d9913f3af17755569c853e0b5a75b8005f6a18eb3f86dadcc0e968c29d' # verbatim Magisk 30.6 module_installer.sh

$ZipEntries = @(
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
$ExecutableEntries = @{
  'customize.sh'                              = $true
  'post-fs-data.sh'                           = $true
  'service.sh'                                = $true
  'scripts/guard-ensure.sh'                   = $true
  'META-INF/com/google/android/update-binary' = $true
  'bin/wsa-vfork-guard'                       = $true
}

function Info([string]$m) { Write-Host "[publish] $m" }

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

function Write-Utf8NoBom([string]$p, [string]$text) {
  [System.IO.File]::WriteAllText($p, $text.Replace("`r`n", "`n"), (New-Object System.Text.UTF8Encoding($false)))
}

function New-ManifestText([string]$DaemonSha) {
  $lines = @(
    '{',
    ('  "module_id": "{0}",'       -f $ModuleId),
    ('  "version": "{0}",'         -f $ModuleVersion),
    ('  "daemon_sha256": "{0}",'   -f $DaemonSha),
    ('  "bridge_sha256": "{0}",'   -f $BridgeSha256),
    ('  "bridge_build_id": "{0}",' -f $BridgeBuildId),
    ('  "syscall_offset": "{0}",'  -f $SyscallOffset),
    ('  "original_flags": "{0}",'  -f $OriginalFlags),
    ('  "effective_flags": "{0}",' -f $EffectiveFlags),
    ('  "state_dir": "{0}"'        -f $StateDir),
    '}'
  )
  return (($lines -join "`n") + "`n")
}

function Assert-ManifestText([string]$JsonText, [string]$DaemonSha) {
  $manifest = $JsonText | ConvertFrom-Json
  $expected = [ordered]@{
    module_id       = $ModuleId
    version         = $ModuleVersion
    daemon_sha256   = $DaemonSha
    bridge_sha256   = $BridgeSha256
    bridge_build_id = $BridgeBuildId
    syscall_offset  = $SyscallOffset
    original_flags  = $OriginalFlags
    effective_flags = $EffectiveFlags
    state_dir       = $StateDir
  }
  $props = @($manifest.PSObject.Properties)
  if ($props.Count -ne 9) { throw "manifest must carry exactly 9 lowercase keys, found $($props.Count)" }
  foreach ($key in $expected.Keys) {
    $p = $manifest.PSObject.Properties[$key]
    if (-not $p) { throw "manifest missing required lowercase key '$key'" }
    if ($p.Value -isnot [string]) { throw "manifest value for '$key' must be a string" }
    if ($p.Value -ne $expected[$key]) { throw "manifest value for '$key' is '$($p.Value)', expected '$($expected[$key])'" }
  }
}

function Assert-StaticLinuxExecutable([string]$Path) {
  $bytes = [System.IO.File]::ReadAllBytes($Path)
  if ($bytes.Length -le 64) { throw 'daemon is too small to be an ELF64 executable' }
  if ($bytes[0] -ne 0x7F -or $bytes[1] -ne 0x45 -or $bytes[2] -ne 0x4C -or $bytes[3] -ne 0x46) {
    throw 'daemon is not an ELF file (missing \x7FELF magic)'
  }
  if ($bytes[4] -ne 2) { throw 'daemon ELF is not 64-bit (EI_CLASS != ELFCLASS64)' }
  if ($bytes[5] -ne 1) { throw 'daemon ELF is not little-endian (EI_DATA != ELFDATA2LSB)' }
  $eType    = [BitConverter]::ToUInt16($bytes, 16)
  $eMachine = [BitConverter]::ToUInt16($bytes, 18)
  if ($eType -ne 2) { throw "daemon ELF e_type is $eType, expected ET_EXEC (2)" }
  if ($eMachine -ne 62) { throw ("daemon ELF e_machine is $eMachine, expected EM_X86_64 (62)") }
  $ePhOff = [BitConverter]::ToUInt64($bytes, 0x20)
  $ePhEnt = [BitConverter]::ToUInt16($bytes, 0x36)
  $ePhNum = [BitConverter]::ToUInt16($bytes, 0x38)
  if ($ePhEnt -ne 56) { throw "unexpected ELF program header entry size $ePhEnt" }
  if ($ePhOff -eq [UInt64]0 -or $ePhNum -eq 0) { throw 'daemon ELF has no program headers' }
  if ($ePhOff -gt 268435456) { throw 'daemon ELF program header offset is implausible' }
  $loadSeen = $false
  for ($i = 0; $i -lt $ePhNum; $i++) {
    $base = [int][UInt64]($ePhOff + [UInt64]($i * $ePhEnt))
    if (($base + 56) -gt $bytes.Length) { throw 'daemon ELF program header table is truncated' }
    $pType = [BitConverter]::ToUInt32($bytes, $base)
    if ($pType -eq 3) { throw 'daemon ELF has PT_INTERP; the production payload must be fully static' }
    if ($pType -eq 1) {
      $pOffset = [BitConverter]::ToUInt64($bytes, $base + 8)
      if (-not $loadSeen -and $pOffset -ne [UInt64]0) { throw 'first PT_LOAD segment does not start at file offset 0' }
      $loadSeen = $true
    }
  }
  if (-not $loadSeen) { throw 'daemon ELF has no PT_LOAD segment' }
  return $bytes.Length
}

try {
  # --- 1. Inputs --------------------------------------------------------------
  $DaemonPath = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($DaemonPath)
  $ModuleDir = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($ModuleDir)
  $OutputDir = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($OutputDir)
  $StageDir = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($StageDir)
  if (-not (Test-Path -LiteralPath $DaemonPath -PathType Leaf)) { throw "daemon binary not found: $DaemonPath" }
  $DaemonPath = (Resolve-Path -LiteralPath $DaemonPath).Path
  if (-not (Test-Path -LiteralPath $ModuleDir -PathType Container)) { throw "module template not found: $ModuleDir" }

  Info "validating daemon ELF: $DaemonPath"
  $daemonSize = Assert-StaticLinuxExecutable $DaemonPath
  $daemonSha = Sha256Hex $DaemonPath
  Info "daemon OK: static x86_64 ET_EXEC, $daemonSize bytes, sha256=$daemonSha"

  # --- 2. Template integrity ----------------------------------------------------
  $propPath   = Join-Path $ModuleDir 'module.prop'
  $custPath   = Join-Path $ModuleDir 'customize.sh'
  $pfdPath    = Join-Path $ModuleDir 'post-fs-data.sh'
  $svcPath    = Join-Path $ModuleDir 'service.sh'
  $guardPath  = Join-Path $ModuleDir 'scripts\guard-ensure.sh'
  $ubPath     = Join-Path $ModuleDir 'META-INF\com\google\android\update-binary'
  $usPath     = Join-Path $ModuleDir 'META-INF\com\google\android\updater-script'
  foreach ($f in @($propPath, $custPath, $pfdPath, $svcPath, $guardPath, $ubPath, $usPath)) {
    if (-not (Test-Path -LiteralPath $f -PathType Leaf)) { throw "module template missing: $f" }
  }
  if ((Sha256Hex $ubPath) -ne $InstallerSha256) {
    throw 'META-INF update-binary is not the verbatim Magisk 30.6 module_installer.sh'
  }
  if (([System.IO.File]::ReadAllText($usPath).Trim()) -ne '#MAGISK') {
    throw 'updater-script must contain exactly "#MAGISK"'
  }
  if (Test-Path -LiteralPath (Join-Path $ModuleDir 'system') -PathType Container) {
    throw 'module template must not contain a system/ overlay; this build ships no library payloads'
  }
  if (Get-ChildItem -LiteralPath $ModuleDir -Recurse -File -Filter '*.so') {
    throw 'module template must not contain .so payloads'
  }

  $prop = @{}
  Get-Content -LiteralPath $propPath | ForEach-Object {
    $line = $_.Trim()
    if ($line -and -not $line.StartsWith('#') -and $line.Contains('=')) {
      $kv = $line -split '=', 2
      $prop[$kv[0].Trim()] = $kv[1].Trim()
    }
  }
  if (-not $prop.ContainsKey('id') -or $prop['id'] -cne $ModuleId) { throw "module.prop id must be '$ModuleId'" }
  if (-not $prop.ContainsKey('version') -or $prop['version'] -ne $ModuleVersion) { throw "module.prop version must be '$ModuleVersion'" }
  if (-not $prop.ContainsKey('versionCode') -or $prop['versionCode'] -ne $ModuleVersionCode) { throw "module.prop versionCode must be '$ModuleVersionCode'" }
  $placeholderTargets = @(
    [pscustomobject]@{ Path = $custPath;  Tokens = @('__EXPECTED_BRIDGE_SHA256__', '__EXPECTED_BRIDGE_SIZE__', '__EXPECTED_BRIDGE_BUILD_ID__', '__EXPECTED_DAEMON_SHA256__') },
    [pscustomobject]@{ Path = $guardPath; Tokens = @('__EXPECTED_BRIDGE_SHA256__') }
  )
  foreach ($target in $placeholderTargets) {
    $text = [System.IO.File]::ReadAllText($target.Path)
    foreach ($token in $target.Tokens) {
      if (-not $text.Contains($token)) { throw "$($target.Path) is missing placeholder $token" }
    }
  }
  $custRef = [System.IO.File]::ReadAllText($custPath)
  foreach ($needle in @('post-fs-data.sh', 'service.sh', 'guard-ensure.sh', 'libhoudini')) {
    if (-not $custRef.Contains($needle)) { throw "customize.sh template does not reference '$needle'" }
  }
  Info "template OK: id=$ModuleId version=$ModuleVersion versionCode=$ModuleVersionCode"
  $licenseFiles = @('LICENSE', 'THIRD_PARTY_NOTICES.md', 'licenses/LGPL-2.1.txt', 'licenses/glibc-COPYRIGHT.txt', 'licenses/GCC-COPYRIGHT.txt')
  foreach ($rel in $licenseFiles) {
    if (-not (Test-Path -LiteralPath (Join-Path $scriptDirectory $rel) -PathType Leaf)) {
      throw "required redistribution notice missing: $rel"
    }
  }

  # --- 3. Output paths and no-silent-overwrite guards ---------------------------
  $zipName      = '{0}-{1}.zip' -f $ModuleId, $ModuleVersion
  $zipPath      = Join-Path $OutputDir $zipName
  $manifestPath = Join-Path $OutputDir 'manifest.json'
  $shaFilePath  = Join-Path $OutputDir 'payload.sha256'

  $stageFull   = [System.IO.Path]::GetFullPath($StageDir).TrimEnd('\', '/')
  $stagePrefix = $stageFull + [System.IO.Path]::DirectorySeparatorChar
  $moduleFull  = [System.IO.Path]::GetFullPath($ModuleDir).TrimEnd('\', '/')
  $modulePrefix = $moduleFull + [System.IO.Path]::DirectorySeparatorChar
  $outputFull  = [System.IO.Path]::GetFullPath($OutputDir).TrimEnd('\', '/')
  $outputPrefix = $outputFull + [System.IO.Path]::DirectorySeparatorChar
  $stageRoot = [System.IO.Path]::GetPathRoot($stageFull).TrimEnd('\', '/')
  if ($stageFull -eq $stageRoot -or
      $stageFull -eq $moduleFull -or
      $stageFull -eq $outputFull -or
      $stageFull.StartsWith($modulePrefix, [StringComparison]::OrdinalIgnoreCase) -or
      $stageFull.StartsWith($outputPrefix, [StringComparison]::OrdinalIgnoreCase) -or
      $moduleFull.StartsWith($stagePrefix, [StringComparison]::OrdinalIgnoreCase) -or
      $outputFull.StartsWith($stagePrefix, [StringComparison]::OrdinalIgnoreCase)) {
    throw 'staging path must not contain, overlap or replace the module template, the output directory or a drive root'
  }
  $daemonFull = [System.IO.Path]::GetFullPath($DaemonPath)
  if ($daemonFull.StartsWith($stagePrefix, [StringComparison]::OrdinalIgnoreCase)) {
    throw 'staging cleanup would delete the input daemon'
  }
  if (Test-Path -LiteralPath (Join-Path $OutputDir 'module')) {
    throw 'output contains a legacy module directory; use a separate empty output directory'
  }
  foreach ($path in @($zipPath, $manifestPath, $shaFilePath)) {
    $full = [System.IO.Path]::GetFullPath($path)
    if ($full.StartsWith($stagePrefix, [StringComparison]::OrdinalIgnoreCase)) {
      throw "staging path would delete an output: $path"
    }
    if ($full -eq $daemonFull -or $full.StartsWith($modulePrefix, [StringComparison]::OrdinalIgnoreCase) -or $full -eq $DaemonPath) {
      throw "output path must not overwrite an input or tracked template: $path"
    }
  }
  $stageMarker = Join-Path $StageDir '.wsa_houdini_vfork_scudo-stage'
  if ((Test-Path -LiteralPath $StageDir) -and
      (-not (Test-Path -LiteralPath $stageMarker -PathType Leaf) -or
       [System.IO.File]::ReadAllText($stageMarker).Trim() -ne $ModuleId)) {
    throw 'refusing to delete an existing staging directory not owned by this publisher'
  }

  $existing = @(@($zipPath, $manifestPath, $shaFilePath) |
    Where-Object { Test-Path -LiteralPath $_ })
  if ($existing.Count -gt 0) {
    if (-not $Force) {
      throw ("refusing to overwrite existing output(s); re-run with -Force:`n  " + ($existing -join "`n  "))
    }
    foreach ($p in $existing) { Remove-Item -LiteralPath $p -Force }
    Info 'cleared previous dist outputs (-Force)'
  }
  New-Item -ItemType Directory -Force -Path $OutputDir | Out-Null

  # --- 4. Stage a copy of the template (source stays untouched) ------------------
  if (Test-Path -LiteralPath $StageDir) { Remove-Item -LiteralPath $StageDir -Recurse -Force }
  # Normalize to an absolute staging root: ZIP entry names are derived by
  # slicing absolute Get-ChildItem FullName values, so a relative -StageDir
  # must never yield a relative stage\module path.
  $stageModule = [System.IO.Path]::GetFullPath((Join-Path $StageDir 'module'))
  New-Item -ItemType Directory -Force -Path $stageModule | Out-Null
  [System.IO.File]::WriteAllText($stageMarker, $ModuleId + "`n", [System.Text.Encoding]::ASCII)
  Copy-Item -Path (Join-Path $ModuleDir '*') -Destination $stageModule -Recurse -Force
  foreach ($rel in $licenseFiles) {
    $destination = Join-Path $stageModule $rel
    New-Item -ItemType Directory -Force -Path ([IO.Path]::GetDirectoryName($destination)) | Out-Null
    Copy-Item -LiteralPath (Join-Path $scriptDirectory $rel) -Destination $destination
  }

  $stageBin = Join-Path $stageModule 'bin'
  New-Item -ItemType Directory -Force -Path $stageBin | Out-Null
  Copy-Item -LiteralPath $DaemonPath -Destination (Join-Path $stageBin 'wsa-vfork-guard') -Force

  # Layout assertion on the staged tree: daemon module only.
  $stagedFiles = @(Get-ChildItem -LiteralPath $stageModule -Recurse -File)
  $unexpected = @($stagedFiles | Where-Object {
    $rel = $_.FullName.Substring($stageModule.Length + 1).Replace('\', '/')
    ($rel -match '^system/') -or ($rel -match '\.so$') -or
    ($rel -match '^bin/' -and $rel -ne $DaemonEntry)
  })
  if ($unexpected.Count -gt 0) {
    throw ("staged module contains forbidden file(s): " + (($unexpected | ForEach-Object { $_.FullName.Substring($stageModule.Length + 1).Replace('\', '/') }) -join ', '))
  }

  # --- 5. Inject pinned checksums into the staged scripts ------------------------
  $replacements = @{
    '__EXPECTED_BRIDGE_SHA256__'   = $BridgeSha256
    '__EXPECTED_BRIDGE_SIZE__'     = [string]$BridgeSize
    '__EXPECTED_BRIDGE_BUILD_ID__' = $BridgeBuildId
    '__EXPECTED_DAEMON_SHA256__'   = $daemonSha
  }
  foreach ($target in @((Join-Path $stageModule 'customize.sh'), (Join-Path $stageModule 'scripts\guard-ensure.sh'))) {
    $text = [System.IO.File]::ReadAllText($target)
    foreach ($token in $replacements.Keys) {
      $text = $text.Replace($token, $replacements[$token])
    }
    if ($text -match '__EXPECTED_') { throw "unreplaced placeholder remains in $target" }
    Write-Utf8NoBom $target $text
  }
  Info 'staged module + checksum-injected customize.sh / guard-ensure.sh'

  # --- 6. Manager-required metadata at the ZIP root -------------------------------
  $manifestText = New-ManifestText $daemonSha
  Assert-ManifestText $manifestText $daemonSha
  Write-Utf8NoBom (Join-Path $stageModule 'manifest.json') $manifestText
  Write-Utf8NoBom (Join-Path $stageModule 'payload.sha256') ($daemonSha + "`n")
  # Mirror for the operator in the dist output directory.
  Write-Utf8NoBom $manifestPath $manifestText
  Write-Utf8NoBom $shaFilePath ($daemonSha + "`n")

  # --- 7. Deterministic ZIP with forward slashes / LF / UNIX attrs ----------------
  Add-Type -AssemblyName System.IO.Compression | Out-Null
  Add-Type -AssemblyName System.IO.Compression.FileSystem | Out-Null

  if (Test-Path -LiteralPath $zipPath) { Remove-Item -LiteralPath $zipPath -Force }
  $zipFs = [System.IO.File]::Open($zipPath, [System.IO.FileMode]::CreateNew, [System.IO.FileAccess]::Write)
  $zip = New-Object System.IO.Compression.ZipArchive($zipFs, [System.IO.Compression.ZipArchiveMode]::Create)
  try {
    $rootLen = $stageModule.TrimEnd('\').Length + 1
    $stamp   = [DateTimeOffset]::Parse('2020-01-01T00:00:00+00:00', [System.Globalization.CultureInfo]::InvariantCulture)
    $files = Get-ChildItem -LiteralPath $stageModule -Recurse -File | Sort-Object FullName
    foreach ($f in $files) {
      $rel = $f.FullName.Substring($rootLen).Replace('\', '/')
      $bytes = [System.IO.File]::ReadAllBytes($f.FullName)
      $isText = ($rel -match '\.(sh|prop|json|sha256|md|txt)$') -or ($rel -eq 'LICENSE') -or ($rel -eq 'META-INF/com/google/android/updater-script')
      if ($isText) {
        $text  = [System.Text.Encoding]::UTF8.GetString($bytes).Replace("`r`n", "`n")
        $bytes = [System.Text.Encoding]::UTF8.GetBytes($text)
      }
      $mode = 0x1A4  # 0644
      if ($ExecutableEntries.ContainsKey($rel)) { $mode = 0x1ED }  # 0755
      $entry = $zip.CreateEntry($rel, [System.IO.Compression.CompressionLevel]::Optimal)
      $entry.LastWriteTime = $stamp
      $entry.ExternalAttributes = ((0x8000 -bor $mode) -shl 16)
      $es = $entry.Open()
      $es.Write($bytes, 0, $bytes.Length)
      $es.Dispose()
    }
  } finally {
    $zip.Dispose()
    $zipFs.Dispose()
  }

  # --- 8. Verify the archive contract --------------------------------------------
  $zipRead  = [System.IO.File]::Open($zipPath, [System.IO.FileMode]::Open, [System.IO.FileAccess]::Read)
  $zipCheck = New-Object System.IO.Compression.ZipArchive($zipRead, [System.IO.Compression.ZipArchiveMode]::Read)
  try {
    $seen = [System.Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
    foreach ($entry in $zipCheck.Entries) {
      if ($entry.FullName.EndsWith('/')) { throw "unexpected directory entry: $($entry.FullName)" }
      if (-not $seen.Add($entry.FullName)) { throw "duplicate ZIP entry: $($entry.FullName)" }
      if ($entry.FullName -match '^system/' -or $entry.FullName -match '\.so$') {
        throw "forbidden overlay-style ZIP entry: $($entry.FullName)"
      }
    }
    $actualEntries = [string[]]@($seen)
    [Array]::Sort($actualEntries, [StringComparer]::Ordinal)
    $expectedEntries = [string[]]$ZipEntries
    [Array]::Sort($expectedEntries, [StringComparer]::Ordinal)
    if (($expectedEntries -join "`n") -ne ($actualEntries -join "`n")) {
      throw ("zip entry set violates the manager preflight contract; actual regular entries:`n  " + ($actualEntries -join "`n  "))
    }
    foreach ($rel in $ExecutableEntries.Keys) {
      $entry = $zipCheck.GetEntry($rel)
      $unixMode = [int](($entry.ExternalAttributes -shr 16) -band 0xFFF)
      if ($unixMode -ne 0x1ED) { throw "ZIP entry $rel must carry mode 0755 (got $([Convert]::ToString($unixMode, 8)))" }
    }
    $entryShaObj = [System.Security.Cryptography.SHA256]::Create()
    try {
      $stream = $zipCheck.GetEntry($DaemonEntry).Open()
      try {
        $daemonEntrySha = [BitConverter]::ToString($entryShaObj.ComputeHash($stream)).Replace('-', '').ToLowerInvariant()
      } finally { $stream.Dispose() }
      $stream = $zipCheck.GetEntry('META-INF/com/google/android/update-binary').Open()
      try {
        $installerEntrySha = [BitConverter]::ToString($entryShaObj.ComputeHash($stream)).Replace('-', '').ToLowerInvariant()
      } finally { $stream.Dispose() }
    } finally { $entryShaObj.Dispose() }
    if ($daemonEntrySha -ne $daemonSha) { throw "zip daemon entry checksum mismatch (got $daemonEntrySha, expected $daemonSha)" }
    if ($installerEntrySha -ne $InstallerSha256) { throw 'zip update-binary entry is not the verbatim Magisk 30.6 installer' }
    $reader = [IO.StreamReader]::new($zipCheck.GetEntry('manifest.json').Open())
    try { $zipManifestText = $reader.ReadToEnd() } finally { $reader.Dispose() }
    Assert-ManifestText ($zipManifestText -replace "`r", '') $daemonSha
    $reader = [IO.StreamReader]::new($zipCheck.GetEntry('payload.sha256').Open())
    try { $zipPayloadSha = $reader.ReadToEnd().Trim() } finally { $reader.Dispose() }
    if ($zipPayloadSha -ne $daemonSha) { throw 'zip payload.sha256 entry does not match the daemon hash' }
  } finally {
    $zipCheck.Dispose()
    $zipRead.Dispose()
  }
  Info "zip contract OK: $($ZipEntries.Count) regular entries, no system/ overlay, daemon entry sha256=$daemonSha"

  # --- 9. Summary -----------------------------------------------------------------
  $zipSize = (Get-Item -LiteralPath $zipPath).Length
  Info '------------------------------ publication complete ------------------------------'
  Info "zip         : $zipPath ($zipSize B)"
  Info "zip sha256  : $(Sha256Hex $zipPath)"
  Info "daemon      : $DaemonEntry ($daemonSize B, static x86_64 ET_EXEC)"
  Info "daemon sha  : $daemonSha (also written to payload.sha256)"
  Info "manifest    : $manifestPath"
  Info "bridge pin  : /vendor/lib64/libhoudini.so sha256=$BridgeSha256 (BuildId $BridgeBuildId, $BridgeSize B)"
  Info "guard scope : zygote64 descendants / Houdini clone guard (syscall 56: 0x4111 -> 0x4011 at base+$SyscallOffset)"
  Info 'install via : .\Manage-Patch.ps1 Install  (the guard starts at post-fs-data of the next full manual WSA restart)'
  Info 'NOTE: no runtime claim is made until the operator completes post-install verification.'
  exit 0
} catch {
  Write-Host "[publish] FAILED: $($_.Exception.Message)" -ForegroundColor Red
  exit 1
}
