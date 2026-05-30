#!/bin/bash
# =============================================================================
#
# Module:      backup.sh
#
# Description:
#   The backup-tree layout convention plus the primitive copy used to
#   populate and restore it. Shared between the writer (migrator.sh, which
#   backs up each path before mutating and restores on rollback/resume) and
#   the reader (validate.sh, which locates each row's backup to diff against).
#
# Why its own module:
#   backup_path_for() encodes the rule "the backup tree MIRRORS the original
#   tree shape under $BACKUP_DIR" — e.g. /applications/opc_d2/conf/x.xml is
#   backed up at $BACKUP_DIR/applications/opc_d2/conf/x.xml. That rule is a
#   CONTRACT between migrator (writer) and validate (reader). It used to live
#   inside migrator.sh, forcing validate.sh to `source migrator.sh` (pulling
#   in all of migrator) just to call this one-liner. Hosting the contract
#   here lets both depend on a small shared module instead.
#
# Where it fits:
#   - Requires common.sh (safe_mkdir_p) sourced first.
#   - backup_path_for() reads the caller's $BACKUP_DIR global (migrator and
#     validate each set it in parse_args).
#
# Bash version floor: 4.2.
#
# =============================================================================

[ -n "${_BACKUP_SH:-}" ] && return 0
_BACKUP_SH=1

# backup_path_for <original_path>
# Echoes where <original_path>'s backup lives: $BACKUP_DIR + original_path.
# Because the backup tree mirrors the original tree shape, basename collisions
# are impossible regardless of name overlap, and rollback is structural.
backup_path_for() {
    local original="$1"
    printf '%s%s' "$BACKUP_DIR" "$original"
}

# backup_cp <src> <dst>
# Creates <dst>'s parent directory and copies <src> -> <dst> with `cp -a`
# (preserves lstat, no symlink deref). Returns cp's exit status so the caller
# chooses the failure policy: migrator dies on a failed pre-mutation backup;
# rollback warns and continues.
backup_cp() {
    local src="$1" dst="$2"
    safe_mkdir_p "$(dirname "$dst")"
    cp -a "$src" "$dst"
}
