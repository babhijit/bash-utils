#!/bin/bash
# =============================================================================
#
# Script:      audit_env.sh
#
# Description:
#   READ-ONLY differential audit of FAT1 (known-good source) vs FAT2 (broken,
#   partially-migrated copy) on the same host. Implements the read-only
#   Phases 0-2 of the repair brief and produces a structured report. It
#   RECOMMENDS NOTHING and CHANGES NOTHING — it only gathers evidence so a
#   human can decide repair-in-place vs clean rebuild.
#
#   WHY THIS EXISTS / WHERE IT FITS: FAT2 was produced by copy/rewrite scripts
#   (this repo's migration pipeline) AND by manual copies — both routing files
#   through /tmp (the only shared-writable path). Provenance is mixed, so FAT2 is
#   heterogeneous. This audit runs FIRST, before any FAT2 write is authorized,
#   and its counts drive the repair-vs-rebuild recommendation.
#
# ----------------------------------------------------------------------------
# TWO DIALS: ROLE (which login) x LEVEL (how deep)
# ----------------------------------------------------------------------------
# ROLE — the two-login manifest handoff. Each login can READ MOST of the other's
#   tree but NOT all (some files are 0600/owned-by-the-other; some dirs are not
#   traversable). A single run as opc_d2 sees an INCOMPLETE FAT1: a directory it
#   cannot traverse makes its whole subtree vanish from `find` SILENTLY,
#   corrupting the differential. FIX — each login is authoritative for its OWN
#   tree, handing off via a manifest in the shared /tmp location:
#
#     ROLE=fat1  (run as the FAT1 user, e.g. opc_d1)
#        Inventories ALL of FAT1 (100% readable) -> writes the MANIFEST to
#        MANIFEST_DIR (fat1_manifest.tsv always; fat1_hashes.tsv + fat1_certs.txt
#        only at LEVEL=2). GROUND TRUTH of what FAT2 should mirror.
#     ROLE=fat2  (run as the FAT2 user, e.g. opc_d2)
#        Inventories ALL of FAT2, INGESTS the manifest, computes the differential
#        + symlink-shared + checksum compare WITHOUT reading restricted FAT1
#        files, and measures the READABILITY GAP — the exact FAT1 paths opc_d2
#        cannot reach. A rebuild must stage those through /tmp via the FAT1 user
#        (the selective_copy model); this audit only IDENTIFIES them (read-only).
#     ROLE=both  (default for a single login that reads both — mock/CI/rehearsal)
#        Runs the fat1 manifest pass then the fat2 audit pass in one process.
#
# LEVEL — audit depth, so you snapshot high-level first and drill down only where
#   it matters (the decision may take several phases):
#
#     LEVEL=1  (default) SNAPSHOT — fast, no hashing / no content grep / no cert
#        decode. Per-subsystem file-count + byte scorecard (FAT1 vs FAT2), path
#        differential counts, symlink classification, ownership breakage,
#        readability GAP, and a heuristic divergence VERDICT. Answers "are these
#        the same shape, or wildly different?" in seconds.
#     LEVEL=2  DRILL-DOWN — everything in LEVEL 1 PLUS unrewritten-token content
#        grep, binary checksum compare, cert decode, Tomcat/Oracle config. Use
#        SCOPE="sub1 sub2" to restrict the EXPENSIVE content work to the
#        top-level subsystems LEVEL 1 flagged (the structural diff stays
#        whole-tree). Pass the SAME LEVEL/SCOPE to BOTH the fat1 and fat2 passes.
#
# ----------------------------------------------------------------------------
# EXCLUDE_DIRS (prune backup/irrelevant subtrees)
# ----------------------------------------------------------------------------
#   Backup dirs (e.g. _backup) intentionally hold OLD configs with FAT1 tokens
#   and stale certs. Counted, they poison the very signals the decision rests on.
#   EXCLUDE_DIRS is a space-separated list of directory NAMES pruned at any depth,
#   applied SYMMETRICALLY to both trees (asymmetric pruning would manufacture
#   false diffs). What was pruned is reported, never silently dropped.
#
# SAFETY (hard guarantees):
#   - Strictly READ-ONLY on both trees. The ONLY writes are to REPORT_DIR and
#     MANIFEST_DIR (under /tmp), asserted NOT under either tree.
#   - Never prints secrets: password/secret/*pass values are REDACTED; private
#     keys, keystores, and wallets are inventoried by metadata only, never dumped.
#   - Never edits, never follows a symlink to write, never runs sed on files.
#   - Tolerates per-file permission errors (captured as DENIED — that's signal).
#
# Usage:
#   # --- PHASE A: snapshot (LEVEL 1), two-login ---
#   ROLE=fat1 FAT1_ROOT=/applications/opc_d1 FAT2_ROOT=/applications/opc_d2 \
#       MANIFEST_DIR=/tmp/fat2_audit_handoff EXCLUDE_DIRS="_backup" bash audit_env.sh
#   ROLE=fat2 FAT1_ROOT=/applications/opc_d1 FAT2_ROOT=/applications/opc_d2 \
#       MANIFEST_DIR=/tmp/fat2_audit_handoff REPORT_DIR=/tmp/fat2_audit \
#       EXCLUDE_DIRS="_backup" bash audit_env.sh
#   # --- PHASE B: drill down only the flagged subsystems (LEVEL 2 + SCOPE) ---
#   ROLE=fat1 LEVEL=2 SCOPE="security conf" ... bash audit_env.sh
#   ROLE=fat2 LEVEL=2 SCOPE="security conf" ... REPORT_DIR=/tmp/fat2_audit_L2 ... bash audit_env.sh
#   # --- single login that can read both (mock / CI) ---
#   FAT1_ROOT=/tmp/f1 FAT2_ROOT=/tmp/f2 LEVEL=2 bash audit_env.sh   # ROLE defaults to both
#
# Linux + GNU coreutils; openssl for cert decode (keytool optional, Phase 2b).
#
# LIMITATIONS / MITIGATIONS:
#   - JKS/P12 alias & validity need the store password -> DEFERRED to Phase 2b.
#   - EXCLUDE_DIRS / SCOPE match by NAME / top-level segment, not arbitrary path.
#   - The VERDICT is a HEURISTIC scorecard only; the human makes the real call.
#
# =============================================================================

set -uo pipefail   # NOT -e: run every section, capture failures as data.

# --- Configuration (all overridable via environment) -------------------------
ROLE="${ROLE:-both}"                   # fat1 | fat2 | both
LEVEL="${LEVEL:-1}"                    # 1 = snapshot | 2 = drill-down
SCOPE="${SCOPE:-}"                     # LEVEL 2 only: space-separated top-level subsystems
FAT1_ROOT="${FAT1_ROOT:-/applications/opc_d1}"
FAT2_ROOT="${FAT2_ROOT:-/applications/opc_d2}"
FAT1_USER="${FAT1_USER:-opc_d1}"
FAT2_USER="${FAT2_USER:-opc_d2}"
FAT1_TOKEN="${FAT1_TOKEN:-opc_d1}"     # the FAT1 string that must NOT remain in FAT2
REPORT_DIR="${REPORT_DIR:-/tmp/fat2_audit_$(date +%Y%m%d_%H%M%S)}"
MANIFEST_DIR="${MANIFEST_DIR:-/tmp/fat2_audit_handoff}"   # shared FAT1-manifest handoff
EXCLUDE_DIRS="${EXCLUDE_DIRS:-}"       # space-separated dir names to prune (both trees)

FAT1_ROOT="${FAT1_ROOT%/}"; FAT2_ROOT="${FAT2_ROOT%/}"

# Manifest file paths (shared between the two passes).
MAN="$MANIFEST_DIR/fat1_manifest.tsv"
HASHF="$MANIFEST_DIR/fat1_hashes.tsv"
CERTF="$MANIFEST_DIR/fat1_certs.txt"

# --- Safety asserts -----------------------------------------------------------
case "$ROLE"  in fat1|fat2|both) ;; *) echo "ERROR: ROLE must be fat1|fat2|both (got '$ROLE')" >&2; exit 1 ;; esac
case "$LEVEL" in 1|2) ;;            *) echo "ERROR: LEVEL must be 1 or 2 (got '$LEVEL')" >&2; exit 1 ;; esac
[ -d "$FAT1_ROOT" ] || { echo "ERROR: FAT1_ROOT not a directory: $FAT1_ROOT" >&2; exit 1; }
[ -d "$FAT2_ROOT" ] || { echo "ERROR: FAT2_ROOT not a directory: $FAT2_ROOT" >&2; exit 1; }
for d in "$REPORT_DIR/" "$MANIFEST_DIR/"; do
    case "$d" in
        "$FAT1_ROOT"/*|"$FAT2_ROOT"/*)
            echo "ERROR: '$d' must NOT be under FAT1/FAT2 — refusing." >&2; exit 1 ;;
    esac
done

# --- Build the symmetric prune expression + grep excludes from EXCLUDE_DIRS ---
# PRUNE_EXPR is spliced into EVERY find; it ALWAYS opens with `-type d ( -false`
# so it never trips the bash 4.2 empty-array-under-set-u trap and is a no-op when
# EXCLUDE_DIRS is empty (`-false` matches nothing).
PRUNE_EXPR=( -type d '(' -false )
GREP_EXCLUDES=()
for _d in $EXCLUDE_DIRS; do
    [ -z "$_d" ] && continue
    PRUNE_EXPR+=( -o -name "$_d" )
    GREP_EXCLUDES+=( "--exclude-dir=$_d" )
done
PRUNE_EXPR+=( ')' -prune -o )

# --- SCOPE (LEVEL 2): restrict expensive content ops to named top-level dirs --
declare -A _SCOPE_SET
for _s in $SCOPE; do [ -n "$_s" ] && _SCOPE_SET["$_s"]=1; done
# in_scope <relpath> -> true if SCOPE empty (all) or rel's top segment is named.
in_scope(){ [ -z "$SCOPE" ] && return 0; local seg="${1%%/*}"; [ -n "${_SCOPE_SET[$seg]:-}" ]; }

# --- Output helpers (REPORT is set per role before any say/hr/sub call) -------
REPORT="/dev/null"
DENIED="/dev/null"
say(){ printf '%s\n' "$*" | tee -a "$REPORT"; }
hr(){ say ""; say "================================================================================"; say "  $*"; say "================================================================================"; }
sub(){ say ""; say "---- $* ----"; }
redact(){ sed -E 's/(([Pp]ass(word)?|[Ss]ecret|[Ss]torepass|[Kk]eypass|[Cc]redential)[A-Za-z_]*[[:space:]]*[=:][[:space:]]*)[^[:space:],"]+/\1<REDACTED>/g; s/((keystorePass|truststorePass|password|keyPass)=")[^"]*"/\1<REDACTED>"/Ig'; }
# bytes -> MiB with one decimal (no bc; awk handles the float).
mib(){ awk -v b="${1:-0}" 'BEGIN{printf "%.1f", b/1048576}'; }

# Extension set shared by the FAT1 hash manifest and the FAT2 checksum compare,
# kept in one place so the two sides never drift out of lock-step.
binary_compare_find_args=( '(' -name '*.jks' -o -name '*.p12' -o -name '*.pfx' \
    -o -name '*.keystore' -o -name '*.truststore' -o -name '*.jar' -o -name '*.war' \
    -o -name '*.pem' -o -name '*.crt' -o -name '*.cer' -o -name '*.der' ')' )

# Per-subsystem summary: reads `type<TAB>size<TAB>relpath` on stdin, emits
# `seg<TAB>files<TAB>dirs<TAB>links<TAB>bytes` (one row per top-level subsystem),
# sorted. Top-level loose files/symlinks bucket under "(root files)".
_summarize_segments(){
    awk -F'\t' '
    { t=$1; sz=$2+0; rel=$3; p=index(rel,"/");
      if (p>0) seg=substr(rel,1,p-1); else if (t=="d") seg=rel; else seg="(root files)";
      segs[seg]=1;
      if      (t=="f"){ f[seg]++; b[seg]+=sz }
      else if (t=="d"){ d[seg]++ }
      else if (t=="l"){ l[seg]++ } }
    END{ for (s in segs) printf "%s\t%d\t%d\t%d\t%d\n", s, f[s]+0, d[s]+0, l[s]+0, b[s]+0 }' \
    | LC_ALL=C sort
}

# =============================================================================
# ROLE: fat1 — inventory FAT1 (the user owns it) and emit the handoff manifest.
# =============================================================================
do_fat1_manifest() {
    mkdir -p "$MANIFEST_DIR" || { echo "ERROR: cannot create MANIFEST_DIR: $MANIFEST_DIR" >&2; exit 1; }
    chmod 0777 "$MANIFEST_DIR" 2>/dev/null || true   # cross-user read (selective_copy 0777 model)
    local DEN="$MANIFEST_DIR/fat1_manifest_denied.txt"
    : > "$MAN"; : > "$HASHF"; : > "$CERTF"; : > "$DEN"
    REPORT="$MANIFEST_DIR/fat1_summary.txt"; : > "$REPORT"
    DENIED="$DEN"

    hr "ROLE=fat1 LEVEL=$LEVEL — FAT1 MANIFEST (authoritative inventory of $FAT1_ROOT)"
    say "Date         : $(date)"
    say "Host         : $(hostname 2>/dev/null)"
    say "Running as   : $(id -un)   (expected: $FAT1_USER)"
    say "FAT1_ROOT    : $FAT1_ROOT"
    say "MANIFEST_DIR : $MANIFEST_DIR"
    say "LEVEL        : $LEVEL   ($([ "$LEVEL" = 1 ] && echo 'snapshot: paths/types/sizes only' || echo 'drill-down: + hashes + cert decode'))"
    say "SCOPE        : ${SCOPE:-<all>}"
    say "EXCLUDE_DIRS : ${EXCLUDE_DIRS:-<none>}"

    # 1) Full inventory (always). Symlink target (%l) LAST so non-symlink rows
    #    have no INTERNAL empty field -> `IFS=$'\t' read` won't collapse tabs and
    #    shift columns. -mindepth 1 drops the '.' root (no LEADING empty field).
    ( cd "$FAT1_ROOT" 2>/dev/null && \
        find . -mindepth 1 "${PRUNE_EXPR[@]}" -printf '%P\t%y\t%s\t%m\t%u:%g\t%l\n' 2>>"$DEN" ) > "$MAN"

    if [ "$LEVEL" = 2 ]; then
        # 2) Hashes for the binary/cert compare set (SCOPE-limited).
        while IFS= read -r rel; do
            [ -z "$rel" ] && continue
            in_scope "$rel" || continue
            local f="$FAT1_ROOT/$rel"
            [ -f "$f" ] || continue
            local h; h="$(sha256sum "$f" 2>>"$DEN" | awk '{print $1}')"
            [ -n "$h" ] && printf '%s\t%s\n' "$h" "$rel" >> "$HASHF"
        done < <( cd "$FAT1_ROOT" 2>/dev/null && \
            find . -mindepth 1 "${PRUNE_EXPR[@]}" -type f "${binary_compare_find_args[@]}" -printf '%P\n' 2>>"$DEN" )

        # 3) Decode FAT1 certs HERE (opc_d2 may not read them later), SCOPE-limited.
        if command -v openssl >/dev/null 2>&1; then
            while IFS= read -r rel; do
                [ -z "$rel" ] && continue
                in_scope "$rel" || continue
                local c="$FAT1_ROOT/$rel"
                if openssl x509 -in "$c" -noout >/dev/null 2>&1; then
                    {
                        echo "  $rel"
                        openssl x509 -in "$c" -noout -subject -issuer -startdate -enddate -serial 2>/dev/null | sed 's/^/    /'
                        openssl x509 -in "$c" -noout -fingerprint -sha256 2>/dev/null | sed 's/^/    /'
                        openssl x509 -in "$c" -noout -text 2>/dev/null | grep -A1 -i 'Subject Alternative Name' | grep -iE 'DNS:|IP Address:|IP:' | sed 's/^/    SAN:/'
                        openssl x509 -in "$c" -noout -checkend 0 >/dev/null 2>&1 || echo "    *** EXPIRED ***"
                    } >> "$CERTF"
                fi
            done < <( cd "$FAT1_ROOT" 2>/dev/null && \
                find . -mindepth 1 "${PRUNE_EXPR[@]}" -type f \( -name '*.pem' -o -name '*.crt' -o -name '*.cer' \) -printf '%P\n' 2>>"$DEN" )
        else
            say "(openssl not available — FAT1 cert decode skipped)"
        fi
    fi

    chmod 0644 "$MAN" "$HASHF" "$CERTF" "$DEN" "$REPORT" 2>/dev/null || true

    sub "FAT1 manifest written"
    say "  entries (manifest)  : $(wc -l < "$MAN")"
    say "  hashed files        : $(wc -l < "$HASHF")   $([ "$LEVEL" = 1 ] && echo '(LEVEL 1: skipped)')"
    say "  certs decoded       : $(grep -c '^  ' "$CERTF" 2>/dev/null)"
    say "  manifest denials    : $(wc -l < "$DEN")"
    say ""
    say "Handoff ready in $MANIFEST_DIR/. Now run ROLE=fat2 LEVEL=$LEVEL${SCOPE:+ SCOPE=\"$SCOPE\"} as $FAT2_USER."
}

# =============================================================================
# ROLE: fat2 — inventory FAT2 and reconcile against the FAT1 manifest.
# =============================================================================
do_fat2_audit() {
    [ -f "$MAN" ] || {
        echo "ERROR: FAT1 manifest not found: $MAN" >&2
        echo "       Run 'ROLE=fat1 LEVEL=$LEVEL ... bash audit_env.sh' as $FAT1_USER first," >&2
        echo "       then re-run this as $FAT2_USER." >&2
        exit 1
    }
    mkdir -p "$REPORT_DIR" || { echo "ERROR: cannot create REPORT_DIR: $REPORT_DIR" >&2; exit 1; }
    chmod 700 "$REPORT_DIR" 2>/dev/null || true
    REPORT="$REPORT_DIR/audit.txt"
    DENIED="$REPORT_DIR/permission_denied.txt"; : > "$REPORT"; : > "$DENIED"

    # ----- Ingest the FAT1 manifest into lookup maps -------------------------
    declare -A F1LINK F1HASH
    while IFS=$'\t' read -r rel typ size mode owner tgt; do
        [ -z "$rel" ] && continue
        [ "$typ" = "l" ] && F1LINK["$rel"]="$tgt"
    done < "$MAN"
    while IFS=$'\t' read -r h rel; do
        [ -z "$rel" ] && continue
        F1HASH["$rel"]="$h"
    done < "$HASHF"

    # ----- FAT2 search roots for SCOPE-limited LEVEL 2 content ops -----------
    SCOPE_ROOTS=()
    if [ -z "$SCOPE" ]; then SCOPE_ROOTS=("$FAT2_ROOT")
    else for _s in $SCOPE; do [ -e "$FAT2_ROOT/$_s" ] && SCOPE_ROOTS+=("$FAT2_ROOT/$_s"); done; fi

    # =============================================================================
    hr "0. ENVIRONMENT & ACCESS  (ROLE=fat2 LEVEL=$LEVEL)"
    say "Date         : $(date)"
    say "Host         : $(hostname 2>/dev/null)"
    say "Running as   : $(id -un)   [$(id 2>/dev/null)]"
    say "Expected user: $FAT2_USER"
    if [ "$(id -un)" != "$FAT2_USER" ]; then
        say "WARN: not running as $FAT2_USER — ownership/readability findings reflect $(id -un), not $FAT2_USER."
    fi
    say "umask        : $(umask)"
    say "FAT1_ROOT    : $FAT1_ROOT   (READ-ONLY; differential vs FAT1 manifest)"
    say "FAT2_ROOT    : $FAT2_ROOT   (target under repair)"
    say "FAT1_TOKEN   : $FAT1_TOKEN"
    say "LEVEL        : $LEVEL   ($([ "$LEVEL" = 1 ] && echo 'SNAPSHOT — no content/checksum/cert' || echo 'DRILL-DOWN — content + checksum + cert'))"
    say "SCOPE        : ${SCOPE:-<all>}   (LEVEL 2 content ops only)"
    say "MANIFEST_DIR : $MANIFEST_DIR   (FAT1 manifest: $(wc -l < "$MAN") entries, $(wc -l < "$HASHF") hashes)"
    say "EXCLUDE_DIRS : ${EXCLUDE_DIRS:-<none>}"

    # =============================================================================
    hr "0. LAYOUT SUMMARY"
    sub "FAT1 ($FAT1_ROOT) — from manifest (authoritative; opc_d1-inventoried)"
    say "  directories : $(awk -F'\t' '$2=="d"' "$MAN" | wc -l)"
    say "  files       : $(awk -F'\t' '$2=="f"' "$MAN" | wc -l)"
    say "  symlinks    : $(awk -F'\t' '$2=="l"' "$MAN" | wc -l)"
    sub "FAT2 ($FAT2_ROOT) — live"
    say "  directories : $(find "$FAT2_ROOT" "${PRUNE_EXPR[@]}" -type d -print 2>>"$DENIED" | wc -l)"
    say "  files       : $(find "$FAT2_ROOT" "${PRUNE_EXPR[@]}" -type f -print 2>>"$DENIED" | wc -l)"
    say "  symlinks    : $(find "$FAT2_ROOT" "${PRUNE_EXPR[@]}" -type l -print 2>>"$DENIED" | wc -l)"
    say "  top-level   :"
    find "$FAT2_ROOT" -mindepth 1 -maxdepth 1 -printf '    %y %f\n' 2>>"$DENIED" | sort -k2 | tee -a "$REPORT"

    # =============================================================================
    hr "0. SUBSYSTEM SCORECARD (per top-level dir: files / MiB, FAT1 vs FAT2)"
    F1SEG="$REPORT_DIR/_seg_fat1.tsv"; F2SEG="$REPORT_DIR/_seg_fat2.tsv"
    awk -F'\t' '{print $2"\t"$3"\t"$1}' "$MAN" | _summarize_segments > "$F1SEG"
    ( cd "$FAT2_ROOT" 2>/dev/null && find . -mindepth 1 "${PRUNE_EXPR[@]}" -printf '%y\t%s\t%P\n' 2>>"$DENIED" ) | _summarize_segments > "$F2SEG"
    declare -A S1F S1B S2F S2B SEGS
    while IFS=$'\t' read -r seg f d l b; do [ -z "$seg" ] && continue; S1F["$seg"]="$f"; S1B["$seg"]="$b"; SEGS["$seg"]=1; done < "$F1SEG"
    while IFS=$'\t' read -r seg f d l b; do [ -z "$seg" ] && continue; S2F["$seg"]="$f"; S2B["$seg"]="$b"; SEGS["$seg"]=1; done < "$F2SEG"
    say "$(printf '  %-22s %-18s %-18s %s' 'subsystem' 'FAT1' 'FAT2' 'Δfiles')"
    DRIFT_SEGS=""
    while IFS= read -r seg; do
        [ -z "$seg" ] && continue
        local f1="${S1F[$seg]:-0}" b1="${S1B[$seg]:-0}" f2="${S2F[$seg]:-0}" b2="${S2B[$seg]:-0}"
        local delta=$(( f2 - f1 )) flag=""
        if [ "$f1" -gt 0 ] && [ "$f2" -eq 0 ]; then flag="!! absent in FAT2"; DRIFT_SEGS="$DRIFT_SEGS $seg"
        elif [ "$delta" -ne 0 ]; then flag="drift"; DRIFT_SEGS="$DRIFT_SEGS $seg"; fi
        say "$(printf '  %-22s %5sf %8sMiB    %5sf %8sMiB    %+d %s' "$seg" "$f1" "$(mib "$b1")" "$f2" "$(mib "$b2")" "$delta" "$flag")"
    done < <(for s in "${!SEGS[@]}"; do echo "$s"; done | LC_ALL=C sort)

    # =============================================================================
    hr "1. SYMLINKS (FAT2) — three-way classification"
    STALE="$REPORT_DIR/symlinks_stale_into_fat1.txt"; BROKEN="$REPORT_DIR/symlinks_broken.txt"
    SHARED_OK="$REPORT_DIR/symlinks_shared_intentional.txt"; SHARED_REV="$REPORT_DIR/symlinks_shared_review.txt"
    OKF2="$REPORT_DIR/symlinks_ok_fat2.txt"
    : > "$STALE"; : > "$BROKEN"; : > "$SHARED_OK"; : > "$SHARED_REV"; : > "$OKF2"
    while IFS=$'\t' read -r rel raw; do
        [ -z "$rel" ] && continue
        abs="$FAT2_ROOT/$rel"
        if [ ! -e "$abs" ]; then printf '%s -> %s\n' "$rel" "$raw" >> "$BROKEN"; continue; fi
        resolved="$(readlink -f "$abs" 2>/dev/null || true)"
        if [ -n "$resolved" ] && { [ "$resolved" = "$FAT1_ROOT" ] || case "$resolved/" in "$FAT1_ROOT"/*) true;; *) false;; esac; }; then
            printf '%s -> %s   (resolves: %s)\n' "$rel" "$raw" "$resolved" >> "$STALE"
        elif [ -n "$resolved" ] && { [ "$resolved" = "$FAT2_ROOT" ] || case "$resolved/" in "$FAT2_ROOT"/*) true;; *) false;; esac; }; then
            printf '%s -> %s\n' "$rel" "$raw" >> "$OKF2"
        else
            f1raw="${F1LINK[$rel]:-}"
            if [ -n "$f1raw" ] && [ "$f1raw" = "$raw" ]; then
                printf '%s -> %s   (FAT1 same-rel link identical: intentional shared)\n' "$rel" "$raw" >> "$SHARED_OK"
            else
                printf '%s -> %s   (FAT1 same-rel: %s)\n' "$rel" "$raw" "${f1raw:-<none>}" >> "$SHARED_REV"
            fi
        fi
    done < <(cd "$FAT2_ROOT" 2>/dev/null && find . -mindepth 1 "${PRUNE_EXPR[@]}" -type l -printf '%P\t%l\n' 2>>"$DENIED")
    say "STALE into FAT1 (need repoint): $(wc -l < "$STALE")"; head -40 "$STALE" | sed 's/^/  /' | tee -a "$REPORT"
    say ""; say "BROKEN (target missing): $(wc -l < "$BROKEN")"; head -40 "$BROKEN" | sed 's/^/  /' | tee -a "$REPORT"
    say ""; say "SHARED — intentional (FAT1 link identical, KEEP): $(wc -l < "$SHARED_OK")"; head -40 "$SHARED_OK" | sed 's/^/  /' | tee -a "$REPORT"
    say ""; say "SHARED — REVIEW (FAT1 link differs/absent): $(wc -l < "$SHARED_REV")"; head -40 "$SHARED_REV" | sed 's/^/  /' | tee -a "$REPORT"
    say ""; say "OK within FAT2: $(wc -l < "$OKF2")"

    # =============================================================================
    hr "1. DIFFERENTIAL (FAT1 manifest vs FAT2, by relative path)"
    F1L="$REPORT_DIR/fat1.paths"; F2L="$REPORT_DIR/fat2.paths"
    cut -f1 "$MAN" | grep -v '^$' | LC_ALL=C sort > "$F1L"
    ( cd "$FAT2_ROOT" 2>/dev/null && find . -mindepth 1 "${PRUNE_EXPR[@]}" -printf '%P\n' 2>>"$DENIED" | LC_ALL=C sort ) > "$F2L"
    MISS="$REPORT_DIR/missing_in_fat2.txt"; EXTRA="$REPORT_DIR/extra_in_fat2.txt"
    comm -23 "$F1L" "$F2L" > "$MISS"; comm -13 "$F1L" "$F2L" > "$EXTRA"
    sub "Present in FAT1, MISSING in FAT2"
    say "  count: $(wc -l < "$MISS")"; head -40 "$MISS" | sed 's/^/  /' | tee -a "$REPORT"
    sub "Present in FAT2, NOT in FAT1 (extra / FAT2-unique — do not delete blindly)"
    say "  count: $(wc -l < "$EXTRA")"; head -40 "$EXTRA" | sed 's/^/  /' | tee -a "$REPORT"

    OWN="$REPORT_DIR/not_owned_by_fat2.txt"
    sub "FAT2 entries NOT owned by $FAT2_USER (manual-copy / ownership breakage)"
    find "$FAT2_ROOT" "${PRUNE_EXPR[@]}" ! -user "$FAT2_USER" -printf '%u:%g %y %p\n' 2>>"$DENIED" > "$OWN"
    say "  count: $(wc -l < "$OWN")"; head -40 "$OWN" | sed 's/^/  /' | tee -a "$REPORT"

    # =============================================================================
    hr "1. FAT1 READABILITY GAP (what $FAT2_USER CANNOT reach in FAT1)"
    say "Manifest proves these exist but $(id -un) cannot read/traverse them."
    say "A REBUILD must stage them through /tmp via $FAT1_USER (selective_copy model)."
    F1VIS="$REPORT_DIR/fat1_visible_to_fat2.paths"
    GAP_UNREACH="$REPORT_DIR/gap_unreachable_subtrees.txt"; GAP_UNREAD="$REPORT_DIR/gap_unreadable_files.txt"
    ( cd "$FAT1_ROOT" 2>/dev/null && find . -mindepth 1 "${PRUNE_EXPR[@]}" -printf '%P\n' 2>>"$DENIED" | LC_ALL=C sort ) > "$F1VIS"
    comm -23 "$F1L" "$F1VIS" > "$GAP_UNREACH"
    ( cd "$FAT1_ROOT" 2>/dev/null && find . -mindepth 1 "${PRUNE_EXPR[@]}" -type f ! -readable -printf '%P\n' 2>>"$DENIED" | LC_ALL=C sort ) > "$GAP_UNREAD"
    sub "Unreachable subtrees (in manifest, NOT visible to $(id -un) — untraversable dirs)"
    say "  count: $(wc -l < "$GAP_UNREACH")"; head -40 "$GAP_UNREACH" | sed 's/^/  /' | tee -a "$REPORT"
    sub "Visible but UNREADABLE files (e.g. 0600 owned by $FAT1_USER)"
    say "  count: $(wc -l < "$GAP_UNREAD")"; head -40 "$GAP_UNREAD" | sed 's/^/  /' | tee -a "$REPORT"

    # ============================ LEVEL 2 ONLY ===================================
    UNREW="$REPORT_DIR/unrewritten.txt"; : > "$UNREW"
    NDIFF=0; NIDENT=0; NABSENT=0
    if [ "$LEVEL" = 2 ]; then
        hr "1. UNREWRITTEN — FAT2 plain-text still containing '$FAT1_TOKEN' (SCOPE: ${SCOPE:-all})"
        if [ "${#SCOPE_ROOTS[@]}" -gt 0 ]; then
            grep -rIl "${GREP_EXCLUDES[@]+"${GREP_EXCLUDES[@]}"}" -- "$FAT1_TOKEN" "${SCOPE_ROOTS[@]}" 2>>"$DENIED" > "$UNREW" || true
        fi
        say "  count: $(wc -l < "$UNREW")"; sed "s|^$FAT2_ROOT/|  |" "$UNREW" | head -60 | tee -a "$REPORT"

        hr "0. TOMCAT INSTANCES & DECLARED PORTS (FAT2, SCOPE: ${SCOPE:-all})"
        if [ "${#SCOPE_ROOTS[@]}" -gt 0 ]; then
            while IFS= read -r sx; do
                [ -z "$sx" ] && continue
                sub "${sx#$FAT2_ROOT/}"
                grep -oE '<Server[^>]*port="[0-9]+"[^>]*shutdown="[^"]*"' "$sx" 2>>"$DENIED" | sed 's/^/  shutdown: /' | tee -a "$REPORT"
                grep -oE 'port="[0-9]+"|redirectPort="[0-9]+"|protocol="[^"]*"' "$sx" 2>>"$DENIED" | sed 's/^/  port-attr: /' | sort -u | tee -a "$REPORT"
            done < <(find "${SCOPE_ROOTS[@]}" "${PRUNE_EXPR[@]}" -name server.xml -print 2>>"$DENIED")
            sub "setenv.sh — JMX / JPDA / heap / CATALINA_PID (secrets redacted)"
            find "${SCOPE_ROOTS[@]}" "${PRUNE_EXPR[@]}" -name 'setenv.sh' -print 2>>"$DENIED" | while IFS= read -r f; do
                grep -HiE 'jmxremote\.port|rmi\.port|JPDA_ADDRESS|address=|-Xm[sx]|CATALINA_PID' "$f" 2>>"$DENIED"
            done | sed "s|^$FAT2_ROOT/||" | redact | tee -a "$REPORT"
        fi

        hr "RUNTIME: LISTENING SOCKETS (cross-check vs configured ports above)"
        if command -v ss >/dev/null 2>&1; then ss -tlnp 2>/dev/null | tee -a "$REPORT"
        elif command -v netstat >/dev/null 2>&1; then netstat -tlnp 2>/dev/null | tee -a "$REPORT"
        else say "  (neither ss nor netstat available)"; fi

        hr "1/2. ORACLE CONFIG (FAT2 locations + metadata; secrets redacted; SCOPE: ${SCOPE:-all})"
        if [ "${#SCOPE_ROOTS[@]}" -gt 0 ]; then
            find "${SCOPE_ROOTS[@]}" "${PRUNE_EXPR[@]}" \( -name tnsnames.ora -o -name sqlnet.ora -o -name ojdbc.properties \) -printf '%p\t%u\t%m\n' 2>>"$DENIED" | tee -a "$REPORT"
            find "${SCOPE_ROOTS[@]}" "${PRUNE_EXPR[@]}" -name sqlnet.ora -print 2>>"$DENIED" | while IFS= read -r f; do
                say "  ${f#$FAT2_ROOT/}:"
                grep -iE 'WALLET_LOCATION|SSL_SERVER_DN_MATCH|DIRECTORY|METHOD|SSL_' "$f" 2>>"$DENIED" | redact | sed 's/^/    /' | tee -a "$REPORT"
            done
        fi

        hr "2. CERTIFICATES / KEYSTORES (FAT2 decode + FAT1 from manifest; SCOPE: ${SCOPE:-all})"
        sub "FAT2 inventory — path / owner:group / mode / bytes"
        [ "${#SCOPE_ROOTS[@]}" -gt 0 ] && find "${SCOPE_ROOTS[@]}" "${PRUNE_EXPR[@]}" "${binary_compare_find_args[@]}" -printf '%p\t%u:%g\t%m\t%s\n' 2>>"$DENIED" | tee -a "$REPORT"
        sub "FAT2 PEM/CRT/CER decode — subject/issuer/dates/SAN/fingerprint; EXPIRED flagged"
        if command -v openssl >/dev/null 2>&1 && [ "${#SCOPE_ROOTS[@]}" -gt 0 ]; then
            while IFS= read -r c; do
                [ -z "$c" ] && continue
                if openssl x509 -in "$c" -noout >/dev/null 2>&1; then
                    say "  ${c#$FAT2_ROOT/}"
                    openssl x509 -in "$c" -noout -subject -issuer -startdate -enddate -serial 2>/dev/null | sed 's/^/    /' | tee -a "$REPORT"
                    openssl x509 -in "$c" -noout -fingerprint -sha256 2>/dev/null | sed 's/^/    /' | tee -a "$REPORT"
                    openssl x509 -in "$c" -noout -text 2>/dev/null | grep -A1 -i 'Subject Alternative Name' | grep -iE 'DNS:|IP Address:|IP:' | sed 's/^/    SAN:/' | tee -a "$REPORT"
                    openssl x509 -in "$c" -noout -checkend 0 >/dev/null 2>&1 || say "    *** EXPIRED ***"
                fi
            done < <(find "${SCOPE_ROOTS[@]}" "${PRUNE_EXPR[@]}" \( -name '*.pem' -o -name '*.crt' -o -name '*.cer' \) -print 2>>"$DENIED")
        else
            say "  (openssl absent or scope empty — FAT2 cert decode skipped)"
        fi
        sub "FAT1 PEM/CRT/CER decode — from manifest (opc_d1-decoded)"
        if [ -s "$CERTF" ]; then cat "$CERTF" | tee -a "$REPORT"; else say "  (none / fat1 cert file empty — was ROLE=fat1 run at LEVEL=2?)"; fi
        sub "JKS/P12/keystores — alias & validity DEFERRED (needs store password, Phase 2b)"

        sub "Binary checksum compare FAT2 vs FAT1 manifest (SCOPE: ${SCOPE:-all})"
        if [ "$(wc -l < "$HASHF")" -eq 0 ]; then
            say "  WARN: FAT1 hash manifest is EMPTY — re-run ROLE=fat1 at LEVEL=2${SCOPE:+ SCOPE=\"$SCOPE\"}."
        fi
        while IFS= read -r rel; do
            [ -z "$rel" ] && continue
            in_scope "$rel" || continue
            local f2="$FAT2_ROOT/$rel"; [ -f "$f2" ] || continue
            local h2; h2="$(sha256sum "$f2" 2>>"$DENIED" | awk '{print $1}')"
            local h1="${F1HASH[$rel]:-}"
            if   [ -z "$h1" ]; then say "  FAT1-ABSENT $rel"; NABSENT=$((NABSENT + 1))
            elif [ "$h1" = "$h2" ]; then say "  IDENTICAL   $rel"; NIDENT=$((NIDENT + 1))
            else say "  DIFFERS     $rel   (FAT1 $h1 / FAT2 $h2)"; NDIFF=$((NDIFF + 1)); fi
        done < <( cd "$FAT2_ROOT" 2>/dev/null && find . -mindepth 1 "${PRUNE_EXPR[@]}" -type f \( -name '*.jks' -o -name '*.p12' -o -name '*.keystore' -o -name '*.truststore' -o -name '*.jar' \) -printf '%P\n' 2>>"$DENIED" )

        hr "0. SCHEDULED / STARTUP"
        sub "crontab for $(id -un) (redacted)"
        crontab -l 2>/dev/null | redact | tee -a "$REPORT" || say "  (none or not permitted)"
        sub "systemd units mentioning opc_d / tomcat"
        systemctl list-units --all --no-pager 2>/dev/null | grep -iE 'opc_d|tomcat|fat[12]' | tee -a "$REPORT" || say "  (none / no systemd / not permitted)"
    fi

    # =============================================================================
    # VERDICT — heuristic only; the human makes the real repair-vs-rebuild call.
    # =============================================================================
    local f1n missn extran stalen brokn gapn pct verdict
    f1n="$(wc -l < "$F1L")"; missn="$(wc -l < "$MISS")"; extran="$(wc -l < "$EXTRA")"
    stalen="$(wc -l < "$STALE")"; brokn="$(wc -l < "$BROKEN")"
    gapn=$(( $(wc -l < "$GAP_UNREACH") + $(wc -l < "$GAP_UNREAD") ))
    if [ "$f1n" -le 0 ]; then pct=0; else pct=$(( missn * 100 / f1n )); fi
    DRIFT_SEGS="$(echo "$DRIFT_SEGS" | tr ' ' '\n' | grep -v '^$' | sort -u | tr '\n' ' ')"
    if   [ "$pct" -ge 25 ]; then verdict="REBUILD CANDIDATE — ${pct}% of FAT1 missing in FAT2 (systemic)."
    elif [ "$pct" -le 2 ] && [ "$stalen" -eq 0 ]; then verdict="LIKELY REPAIRABLE — only ${pct}% missing, no stale-into-FAT1 symlinks."
    else verdict="PARTIAL — ${pct}% missing, ${stalen} stale symlinks; drill down before deciding."; fi
    hr "VERDICT (HEURISTIC — confirm with LEVEL 2 + human judgement)"
    say "  Missing ${missn}/${f1n} (${pct}%) | extra ${extran} | stale ${stalen} | broken ${brokn} | GAP ${gapn}"
    say "  >> $verdict"
    [ -n "$DRIFT_SEGS" ] && say "  Drill-down targets (drifting subsystems): LEVEL=2 SCOPE=\"$(echo "$DRIFT_SEGS" | sed 's/ *$//')\""

    # =============================================================================
    hr "SUMMARY (counts — high signal)"
    say "  LEVEL                               : $LEVEL ($([ "$LEVEL" = 1 ] && echo snapshot || echo drill-down)${SCOPE:+, SCOPE=$SCOPE})"
    say "  FAT1 entries (manifest)             : $(wc -l < "$MAN")"
    say "  Missing in FAT2                     : $missn"
    say "  Extra in FAT2 (FAT2-unique)         : $extran"
    say "  Symlinks STALE into FAT1            : $stalen"
    say "  Symlinks BROKEN                     : $brokn"
    say "  Symlinks SHARED intentional (keep)  : $(wc -l < "$SHARED_OK")"
    say "  Symlinks SHARED review              : $(wc -l < "$SHARED_REV")"
    say "  FAT2 entries not owned by $FAT2_USER : $(wc -l < "$OWN")"
    say "  GAP: FAT1 unreachable subtrees      : $(wc -l < "$GAP_UNREACH")"
    say "  GAP: FAT1 unreadable files          : $(wc -l < "$GAP_UNREAD")"
    if [ "$LEVEL" = 2 ]; then
        say "  Unrewritten (still has $FAT1_TOKEN)   : $(wc -l < "$UNREW")"
        say "  Checksum DIFFERS / IDENTICAL / ABSENT: $NDIFF / $NIDENT / $NABSENT"
    else
        say "  Unrewritten / checksum / certs      : n/a (LEVEL 1 snapshot — run LEVEL 2 to drill down)"
    fi
    say "  Permission-denied lines             : $(wc -l < "$DENIED")"
    say ""
    say "Report written: $REPORT"
    say "Also: per-category lists in $REPORT_DIR/  (no secrets included)."
}

# =============================================================================
main() {
    case "$ROLE" in
        fat1) do_fat1_manifest ;;
        fat2) do_fat2_audit ;;
        both) do_fat1_manifest; do_fat2_audit ;;
    esac
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    main "$@"
fi
