#!/system/bin/sh
# =============================================================================
# wsa_houdini_vfork_scudo - early boot entry point.
#
# Runs in Magisk's post-fs-data stage, before zygote64 starts, so the guard
# can PTRACE_SEIZE zygote64 and follow every descendant from birth. This file
# is a thin wrapper; all launch policy lives in scripts/guard-ensure.sh
# (module flag gate, pinned-bridge gate, identity-verified singleton, one
# foreground daemon in background with append logfile).
# =============================================================================
MODDIR=${0%/*}
case "$MODDIR" in */*) ;; *) MODDIR=. ;; esac
exec sh "$MODDIR/scripts/guard-ensure.sh" early
