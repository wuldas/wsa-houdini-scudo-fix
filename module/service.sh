#!/system/bin/sh
# =============================================================================
# wsa_houdini_vfork_scudo - late boot entry point.
#
# Runs in Magisk's service stage: if the guard started at post-fs-data is
# still alive (verified by /proc/<pid>/exe identity) it is left untouched;
# if it died, the same shared bootstrap relaunches it safely. The daemon's
# guard.lock flock keeps this a singleton. This file is a thin wrapper; all
# launch policy lives in scripts/guard-ensure.sh.
# =============================================================================
MODDIR=${0%/*}
case "$MODDIR" in */*) ;; *) MODDIR=. ;; esac
exec sh "$MODDIR/scripts/guard-ensure.sh" service
