#!/system/bin/sh
# =============================================================================
# wsa_houdini_vfork_scudo 0.4.0-experimental - fail-closed install checks.
# Sourced by Magisk's module_installer after the zip has been extracted into
# $MODPATH. Every abort() below stops the install and leaves the running
# system, /vendor/lib64/libhoudini.so and all original libraries untouched.
#
# This build ships a resident root ptrace guard daemon (bin/wsa-vfork-guard)
# and NO library overlay: it aborts on any system/ tree, any *.so payload,
# any manifest carrying legacy library-rewrite fields, and any Houdini that
# is not the exact pinned original build.
#
# Packaging checksum tokens are replaced by Publish-Patch.ps1.
# If a placeholder survives a packaging bug, the checks below fail closed
# by construction.
#
# Guard scope (honest wording): zygote64 descendants / Houdini clone guard.
# All zygote64 descendants can retain ptrace state because Houdini is preloaded.
# Only the pinned Houdini clone instruction is intercepted; no 32-bit repair.
# =============================================================================

EXPECTED_BRIDGE_SHA256=__EXPECTED_BRIDGE_SHA256__
EXPECTED_BRIDGE_SIZE=__EXPECTED_BRIDGE_SIZE__
EXPECTED_BRIDGE_BUILD_ID=__EXPECTED_BRIDGE_BUILD_ID__
EXPECTED_DAEMON_SHA256=__EXPECTED_DAEMON_SHA256__

BRIDGE=/vendor/lib64/libhoudini.so
DAEMON="$MODPATH/bin/wsa-vfork-guard"
MANIFEST="$MODPATH/manifest.json"
PAYLOAD_SHA_FILE="$MODPATH/payload.sha256"

ui_print "- wsa_houdini_vfork_scudo 0.4.0-experimental (zygote64 descendants / Houdini clone guard)"

# --- 1. Host gate: x86_64 WSA (Magisk ARCH=x64), Android 13 / API 33 ---------
if [ "$ARCH" != "x64" ]; then
  abort "! ERROR: requires Magisk ARCH=x64 (x86_64 WSA host), zip reports ARCH=$ARCH"
fi
if [ "$(getprop ro.product.cpu.abi)" != "x86_64" ]; then
  abort "! ERROR: requires x86_64 WSA host, device reports ABI=$(getprop ro.product.cpu.abi)"
fi
if [ "$API" != "33" ]; then
  abort "! ERROR: requires Android 13 / API 33, device reports API=$API"
fi
FP="$(getprop ro.build.fingerprint) $(getprop ro.product.manufacturer) $(getprop ro.product.model)"
case "$FP" in
  *[Ww][Ii][Nn][Dd][Oo][Ww][Ss]*|*[Ww][Ss][Aa]*)
    ui_print "- WSA environment OK: $(getprop ro.build.fingerprint)"
    ;;
  *)
    abort "! ERROR: Windows/WSA fingerprint not detected: $FP"
    ;;
esac
if [ -n "$MAGISK_VER_CODE" ] && [ "$MAGISK_VER_CODE" -lt 30000 ] 2>/dev/null; then
  abort "! ERROR: requires Magisk >= 30.0 (VER_CODE $MAGISK_VER_CODE reported; pinned environment is Magisk 30.6)"
fi

# --- 2. Packaging/layout gate: daemon module only, zero library overlay ------
for CHECKSUM in "$EXPECTED_DAEMON_SHA256" "$EXPECTED_BRIDGE_SHA256"; do
  case "$CHECKSUM" in *[!0-9a-f]*|'') abort "! ERROR: invalid or unreplaced checksum" ;; esac
  [ "${#CHECKSUM}" -eq 64 ] || abort "! ERROR: invalid or unreplaced checksum length"
done
if [ ! -f "$DAEMON" ]; then
  abort "! ERROR: module zip is missing $DAEMON"
fi
if [ -d "$MODPATH/system" ]; then
  abort "! ERROR: module zip contains a legacy system/ overlay; this build ships no library payloads"
fi
if find "$MODPATH" -name '*.so' -print 2>/dev/null | grep -q .; then
  abort "! ERROR: module zip contains .so file(s); this build must never ship library payloads"
fi
for REQUIRED in post-fs-data.sh service.sh scripts/guard-ensure.sh; do
  if [ ! -f "$MODPATH/$REQUIRED" ]; then
    abort "! ERROR: module zip is missing $REQUIRED"
  fi
done
if ! grep -q "^EXPECTED_BRIDGE_SHA256=$EXPECTED_BRIDGE_SHA256$" "$MODPATH/scripts/guard-ensure.sh"; then
  abort "! ERROR: bootstrap original-bridge checksum does not match the manifest"
fi

# --- 3. Daemon identity: ELF magic + SHA256 across manifest and payload ------
DAEMON_MAGIC="$(dd if="$DAEMON" bs=1 count=4 2>/dev/null | od -An -tx1 | tr -d ' \n')"
if [ "$DAEMON_MAGIC" != "7f454c46" ]; then
  abort "! ERROR: bin/wsa-vfork-guard is not an ELF file (magic=$DAEMON_MAGIC)"
fi
DAEMON_SHA="$(sha256sum "$DAEMON" | awk '{print $1}')"
if [ "$DAEMON_SHA" != "$EXPECTED_DAEMON_SHA256" ]; then
  abort "! ERROR: daemon checksum mismatch (got $DAEMON_SHA, expected $EXPECTED_DAEMON_SHA256)"
fi
if [ ! -f "$PAYLOAD_SHA_FILE" ] || [ "$(cat "$PAYLOAD_SHA_FILE" | tr -d ' \r\n')" != "$DAEMON_SHA" ]; then
  abort "! ERROR: payload.sha256 does not match the packaged daemon bytes"
fi

# --- 4. Manifest contract: exactly the nine lowercase keys --------------------
if [ ! -f "$MANIFEST" ]; then
  abort "! ERROR: module zip is missing manifest.json"
fi
if grep -qE '"(input_sha256|output_sha256|source_build_id|target_path|patch_offset|original_hex|patched_hex|hook_offset|resume_offset|stub_offset|stub_hex)"' "$MANIFEST"; then
  abort "! ERROR: manifest carries legacy library-rewrite keys; this build must not ship rewritten libraries"
fi
KEY_COUNT="$(grep -o '"[a-z_0-9]*"[[:space:]]*:' "$MANIFEST" | sort -u | wc -l)"
if [ "$KEY_COUNT" -ne 9 ]; then
  abort "! ERROR: manifest must carry exactly 9 keys, found $KEY_COUNT"
fi
manifest_value() {
  sed -n 's/.*"'"$1"'"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' "$MANIFEST" | head -n 1
}
for KEY in module_id version daemon_sha256 bridge_sha256 bridge_build_id syscall_offset original_flags effective_flags state_dir; do
  if [ -z "$(manifest_value "$KEY")" ]; then
    abort "! ERROR: manifest.json missing or empty key '$KEY'"
  fi
done
[ "$(manifest_value module_id)"       = "wsa_houdini_vfork_scudo" ] || abort "! ERROR: manifest module_id mismatch"
[ "$(manifest_value version)"         = "0.4.0-experimental" ]      || abort "! ERROR: manifest version mismatch"
[ "$(manifest_value daemon_sha256)"   = "$EXPECTED_DAEMON_SHA256" ] || abort "! ERROR: manifest daemon_sha256 does not match the packaged daemon"
[ "$(manifest_value bridge_sha256)"   = "$EXPECTED_BRIDGE_SHA256" ] || abort "! ERROR: manifest bridge_sha256 mismatch"
[ "$(manifest_value bridge_build_id)" = "$EXPECTED_BRIDGE_BUILD_ID" ] || abort "! ERROR: manifest bridge_build_id mismatch"
[ "$(manifest_value syscall_offset)"  = "0x30d661" ]                || abort "! ERROR: manifest syscall_offset mismatch"
[ "$(manifest_value original_flags)"  = "0x4111" ]                  || abort "! ERROR: manifest original_flags mismatch"
[ "$(manifest_value effective_flags)" = "0x4011" ]                  || abort "! ERROR: manifest effective_flags mismatch"
[ "$(manifest_value state_dir)"       = "/data/adb/wsa_houdini_vfork_scudo" ] || abort "! ERROR: manifest state_dir mismatch"

# --- 5. Current Houdini must be the exact pinned original build ---------------
if [ ! -f "$BRIDGE" ]; then
  abort "! ERROR: $BRIDGE not found; refusing to install"
fi
BRIDGE_SIZE="$(stat -c %s "$BRIDGE" 2>/dev/null)"
if [ "$BRIDGE_SIZE" != "$EXPECTED_BRIDGE_SIZE" ]; then
  abort "! ERROR: $BRIDGE size mismatch (got ${BRIDGE_SIZE:-unreadable}, expected $EXPECTED_BRIDGE_SIZE)"
fi
BRIDGE_SHA="$(sha256sum "$BRIDGE" | awk '{print $1}')"
if [ "$BRIDGE_SHA" != "$EXPECTED_BRIDGE_SHA256" ]; then
  abort "! ERROR: current $BRIDGE is not the supported pinned original (sha256=$BRIDGE_SHA); refusing to install"
fi
ui_print "- pinned original Houdini verified: sha256=$BRIDGE_SHA ($BRIDGE_SIZE bytes)"

# --- 6. Permissions: root-owned, daemon + boot scripts executable -------------
set_perm_recursive "$MODPATH" 0 0 0755 0644
set_perm "$DAEMON" 0 0 0755
set_perm "$MODPATH/post-fs-data.sh" 0 0 0755
set_perm "$MODPATH/service.sh" 0 0 0755
set_perm "$MODPATH/scripts/guard-ensure.sh" 0 0 0755
if [ ! -x "$DAEMON" ]; then
  abort "! ERROR: daemon is not executable after set_perm"
fi

ui_print "- All checks passed. The guard starts at post-fs-data on the NEXT FULL WSA restart."
ui_print "- Scope: zygote64 descendants / Houdini clone guard (syscall 56 flags 0x4111 -> 0x4011 at bridge base+0x30d661)."
ui_print "- All zygote64 descendants, including x86-only apps, may show ptrace state while the guard is active."
ui_print "- No library bytes, properties, or app data are modified; no apps are stopped."
ui_print "- State/logs: /data/adb/wsa_houdini_vfork_scudo (root-only)."
ui_print "----------------------------------------"
