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
#   Sections:
#     0  environment + access feasibility (can FAT2 user read FAT1?)
#     0  layout summary (file/dir/symlink counts per tree)
#     1  symlinks (FAT2) classified: STALE_INTO_FAT1 / OK_FAT2 /
#        SHARED_INTENTIONAL (FAT1's same-rel link points to the SAME target) /
#        SHARED_REVIEW / BROKEN
#     1  differential: missing-in-FAT2, extra-in-FAT2, plain-text files still
#        containing the FAT1 token (incomplete rewrite), FAT2 entries not owned
#        by the FAT2 user, FAT1 files the FAT2 user cannot read
#     0  Tomcat: server.xml + setenv.sh locations and the ports they declare
#     -  runtime listening sockets (collision check vs the configured ports)
#     1/2 Oracle: tnsnames/sqlnet/wallet locations + WALLET_LOCATION/TNS_ADMIN
#     2  certificates/keystores: inventory; PEM/CRT decode (subject/issuer/
#        dates/SAN/fingerprint, EXPIRED flag); FAT1-vs-FAT2 binary checksum
#        compare. JKS/P12 alias/validity is DEFERRED (needs the store password).
#     0  scheduled/startup: cron + systemd references
#
# SAFETY (hard guarantees):
#   - Strictly READ-ONLY on both trees. The ONLY writes are to REPORT_DIR
#     (default /tmp/fat2_audit_<ts>, mode 700), asserted NOT under either tree.
#   - Never prints secrets: password/secret/*pass values are REDACTED; private
#     keys, keystores, and wallets are inventoried by metadata only, never dumped.
#   - Never edits, never follows a symlink to write, never runs sed on files.
#   - Tolerates per-file permission errors (captured as DENIED — that's signal).
#
# Usage (run as the FAT2 user, e.g. opc_d2):
#   FAT1_ROOT=/applications/opc_d1 FAT2_ROOT=/applications/opc_d2 \
#       bash audit_env.sh
#   # then send back the report file it prints at the end. No secrets are in it.
#
# Test it safely FIRST on a clone box against a throwaway mock pair, e.g.:
#   FAT1_ROOT=/tmp/f1 FAT2_ROOT=/tmp/f2 bash audit_env.sh
#
# Linux + GNU coreutils; openssl for cert decode (keytool optional, Phase 2b).
#
# =============================================================================

set -uo pipefail   # NOT -e: run every section, capture failures as data.

FAT1_ROOT="${FAT1_ROOT:-/applications/opc_d1}"
FAT2_ROOT="${FAT2_ROOT:-/applications/opc_d2}"
FAT1_USER="${FAT1_USER:-opc_d1}"
FAT2_USER="${FAT2_USER:-opc_d2}"
FAT1_TOKEN="${FAT1_TOKEN:-opc_d1}"     # the FAT1 string that must NOT remain in FAT2
REPORT_DIR="${REPORT_DIR:-/tmp/fat2_audit_$(date +%Y%m%d_%H%M%S)}"

FAT1_ROOT="${FAT1_ROOT%/}"; FAT2_ROOT="${FAT2_ROOT%/}"

# --- Safety asserts -----------------------------------------------------------
[ -d "$FAT1_ROOT" ] || { echo "ERROR: FAT1_ROOT not a directory: $FAT1_ROOT" >&2; exit 1; }
[ -d "$FAT2_ROOT" ] || { echo "ERROR: FAT2_ROOT not a directory: $FAT2_ROOT" >&2; exit 1; }
case "$REPORT_DIR/" in
    "$FAT1_ROOT"/*|"$FAT2_ROOT"/*)
        echo "ERROR: REPORT_DIR ($REPORT_DIR) must NOT be under FAT1/FAT2 — refusing." >&2; exit 1 ;;
esac
mkdir -p "$REPORT_DIR" || { echo "ERROR: cannot create REPORT_DIR: $REPORT_DIR" >&2; exit 1; }
chmod 700 "$REPORT_DIR" 2>/dev/null || true
REPORT="$REPORT_DIR/audit.txt"
DENIED="$REPORT_DIR/permission_denied.txt"; : > "$REPORT"; : > "$DENIED"

# --- Output helpers -----------------------------------------------------------
say(){ printf '%s\n' "$*" | tee -a "$REPORT"; }
hr(){ say ""; say "================================================================================"; say "  $*"; say "================================================================================"; }
sub(){ say ""; say "---- $* ----"; }
# Redact secret-ish values from a stream (key=val, key: val, and XML attrs).
redact(){ sed -E 's/(([Pp]ass(word)?|[Ss]ecret|[Ss]torepass|[Kk]eypass|[Cc]redential)[A-Za-z_]*[[:space:]]*[=:][[:space:]]*)[^[:space:],"]+/\1<REDACTED>/g; s/((keystorePass|truststorePass|password|keyPass)=")[^"]*"/\1<REDACTED>"/Ig'; }

# =============================================================================
hr "0. ENVIRONMENT & ACCESS"
say "Date         : $(date)"
say "Host         : $(hostname 2>/dev/null)"
say "Running as   : $(id -un)   [$(id 2>/dev/null)]"
say "Expected user: $FAT2_USER"
if [ "$(id -un)" != "$FAT2_USER" ]; then
    say "WARN: not running as $FAT2_USER — ownership/readability findings reflect $(id -un), not opc_d2."
fi
say "umask        : $(umask)"
say "FAT1_ROOT    : $FAT1_ROOT   (READ-ONLY source)"
say "FAT2_ROOT    : $FAT2_ROOT   (target under repair)"
say "FAT1_TOKEN   : $FAT1_TOKEN"

# =============================================================================
hr "0. LAYOUT SUMMARY"
for pair in "FAT1:$FAT1_ROOT" "FAT2:$FAT2_ROOT"; do
    lbl="${pair%%:*}"; root="${pair#*:}"
    sub "$lbl ($root)"
    say "  directories : $(find "$root" -type d 2>>"$DENIED" | wc -l)"
    say "  files       : $(find "$root" -type f 2>>"$DENIED" | wc -l)"
    say "  symlinks    : $(find "$root" -type l 2>>"$DENIED" | wc -l)"
    say "  top-level   :"
    find "$root" -mindepth 1 -maxdepth 1 -printf '    %y %f\n' 2>>"$DENIED" | sort -k2 | tee -a "$REPORT"
done

# =============================================================================
hr "1. SYMLINKS (FAT2) — three-way classification"
STALE="$REPORT_DIR/symlinks_stale_into_fat1.txt"
BROKEN="$REPORT_DIR/symlinks_broken.txt"
SHARED_OK="$REPORT_DIR/symlinks_shared_intentional.txt"
SHARED_REV="$REPORT_DIR/symlinks_shared_review.txt"
OKF2="$REPORT_DIR/symlinks_ok_fat2.txt"
: > "$STALE"; : > "$BROKEN"; : > "$SHARED_OK"; : > "$SHARED_REV"; : > "$OKF2"

while IFS=$'\t' read -r rel raw; do
    [ -z "$rel" ] && continue
    abs="$FAT2_ROOT/$rel"
    # broken?
    if [ ! -e "$abs" ]; then
        printf '%s -> %s\n' "$rel" "$raw" >> "$BROKEN"; continue
    fi
    resolved="$(readlink -f "$abs" 2>/dev/null || true)"
    if [ -n "$resolved" ] && { [ "$resolved" = "$FAT1_ROOT" ] || case "$resolved/" in "$FAT1_ROOT"/*) true;; *) false;; esac; }; then
        printf '%s -> %s   (resolves: %s)\n' "$rel" "$raw" "$resolved" >> "$STALE"
    elif [ -n "$resolved" ] && { [ "$resolved" = "$FAT2_ROOT" ] || case "$resolved/" in "$FAT2_ROOT"/*) true;; *) false;; esac; }; then
        printf '%s -> %s\n' "$rel" "$raw" >> "$OKF2"
    else
        # Target outside both trees -> SHARED. Does FAT1's same-rel link match?
        f1raw="$(readlink "$FAT1_ROOT/$rel" 2>/dev/null || true)"
        if [ -n "$f1raw" ] && [ "$f1raw" = "$raw" ]; then
            printf '%s -> %s   (FAT1 same-rel link identical: intentional shared)\n' "$rel" "$raw" >> "$SHARED_OK"
        else
            printf '%s -> %s   (FAT1 same-rel: %s)\n' "$rel" "$raw" "${f1raw:-<none>}" >> "$SHARED_REV"
        fi
    fi
done < <(cd "$FAT2_ROOT" 2>/dev/null && find . -type l -printf '%P\t%l\n' 2>>"$DENIED")

say "STALE into FAT1 (need repoint): $(wc -l < "$STALE")"; head -40 "$STALE" | sed 's/^/  /' | tee -a "$REPORT"
say ""; say "BROKEN (target missing): $(wc -l < "$BROKEN")"; head -40 "$BROKEN" | sed 's/^/  /' | tee -a "$REPORT"
say ""; say "SHARED — intentional (FAT1 link identical, KEEP): $(wc -l < "$SHARED_OK")"; head -40 "$SHARED_OK" | sed 's/^/  /' | tee -a "$REPORT"
say ""; say "SHARED — REVIEW (FAT1 link differs/absent): $(wc -l < "$SHARED_REV")"; head -40 "$SHARED_REV" | sed 's/^/  /' | tee -a "$REPORT"
say ""; say "OK within FAT2: $(wc -l < "$OKF2")"

# =============================================================================
hr "1. DIFFERENTIAL (FAT1 vs FAT2, by relative path)"
F1L="$REPORT_DIR/fat1.paths"; F2L="$REPORT_DIR/fat2.paths"
( cd "$FAT1_ROOT" 2>/dev/null && find . -printf '%P\n' 2>>"$DENIED" | sort ) > "$F1L"
( cd "$FAT2_ROOT" 2>/dev/null && find . -printf '%P\n' 2>>"$DENIED" | sort ) > "$F2L"
MISS="$REPORT_DIR/missing_in_fat2.txt"; EXTRA="$REPORT_DIR/extra_in_fat2.txt"
comm -23 "$F1L" "$F2L" > "$MISS"
comm -13 "$F1L" "$F2L" > "$EXTRA"
sub "Present in FAT1, MISSING in FAT2"
say "  count: $(wc -l < "$MISS")"; head -40 "$MISS" | sed 's/^/  /' | tee -a "$REPORT"
sub "Present in FAT2, NOT in FAT1 (extra / FAT2-unique — do not delete blindly)"
say "  count: $(wc -l < "$EXTRA")"; head -40 "$EXTRA" | sed 's/^/  /' | tee -a "$REPORT"

UNREW="$REPORT_DIR/unrewritten.txt"
sub "FAT2 PLAIN-TEXT files still containing '$FAT1_TOKEN' (incomplete rewrite)"
grep -rIl -- "$FAT1_TOKEN" "$FAT2_ROOT" 2>>"$DENIED" > "$UNREW" || true
say "  count: $(wc -l < "$UNREW")"; sed "s|^$FAT2_ROOT/|  |" "$UNREW" | head -60 | tee -a "$REPORT"

OWN="$REPORT_DIR/not_owned_by_fat2.txt"
sub "FAT2 entries NOT owned by $FAT2_USER (ownership breakage)"
find "$FAT2_ROOT" ! -user "$FAT2_USER" -printf '%u:%g %y %p\n' 2>>"$DENIED" > "$OWN"
say "  count: $(wc -l < "$OWN")"; head -40 "$OWN" | sed 's/^/  /' | tee -a "$REPORT"

UNREAD="$REPORT_DIR/fat1_unreadable.txt"
sub "FAT1 paths the current user ($(id -un)) CANNOT read (shared-read feasibility)"
find "$FAT1_ROOT" ! -readable -printf '%y %p\n' 2>>"$DENIED" > "$UNREAD"
say "  count: $(wc -l < "$UNREAD")"; head -40 "$UNREAD" | sed 's/^/  /' | tee -a "$REPORT"

# =============================================================================
hr "0. TOMCAT INSTANCES & DECLARED PORTS (FAT2)"
while IFS= read -r sx; do
    [ -z "$sx" ] && continue
    sub "${sx#$FAT2_ROOT/}"
    grep -oE '<Server[^>]*port="[0-9]+"[^>]*shutdown="[^"]*"' "$sx" 2>>"$DENIED" | sed 's/^/  shutdown: /' | tee -a "$REPORT"
    grep -oE '<Connector[^>]*port="[0-9]+"' "$sx" 2>>"$DENIED" | grep -oE 'port="[0-9]+".*|protocol="[^"]*"' | sed 's/^/  connector: /' | tee -a "$REPORT"
    grep -oE 'port="[0-9]+"|redirectPort="[0-9]+"|protocol="[^"]*"' "$sx" 2>>"$DENIED" | sed 's/^/  port-attr: /' | sort -u | tee -a "$REPORT"
done < <(find "$FAT2_ROOT" -name server.xml 2>>"$DENIED")

sub "setenv.sh — JMX / JPDA / heap / CATALINA_PID (secrets redacted)"
find "$FAT2_ROOT" -name 'setenv.sh' 2>>"$DENIED" -exec grep -HiE 'jmxremote\.port|rmi\.port|JPDA_ADDRESS|address=|-Xm[sx]|CATALINA_PID' {} \; 2>>"$DENIED" | sed "s|^$FAT2_ROOT/||" | redact | tee -a "$REPORT"

# =============================================================================
hr "RUNTIME: LISTENING SOCKETS (cross-check vs configured ports above)"
if command -v ss >/dev/null 2>&1; then
    ss -tlnp 2>/dev/null | tee -a "$REPORT"
elif command -v netstat >/dev/null 2>&1; then
    netstat -tlnp 2>/dev/null | tee -a "$REPORT"
else
    say "  (neither ss nor netstat available)"
fi

# =============================================================================
hr "1/2. ORACLE CONFIG (locations + metadata; secrets redacted)"
sub "tnsnames.ora / sqlnet.ora / ojdbc.properties (both trees)"
find "$FAT1_ROOT" "$FAT2_ROOT" \( -name tnsnames.ora -o -name sqlnet.ora -o -name ojdbc.properties \) -printf '%p\t%u\t%m\n' 2>>"$DENIED" | tee -a "$REPORT"
sub "sqlnet.ora key directives (FAT2)"
while IFS= read -r f; do
    [ -z "$f" ] && continue
    say "  ${f#$FAT2_ROOT/}:"
    grep -iE 'WALLET_LOCATION|SSL_SERVER_DN_MATCH|DIRECTORY|METHOD|SSL_' "$f" 2>>"$DENIED" | redact | sed 's/^/    /' | tee -a "$REPORT"
done < <(find "$FAT2_ROOT" -name sqlnet.ora 2>>"$DENIED")
sub "TNS_ADMIN references in FAT2 (redacted)"
grep -rIsE 'TNS_ADMIN' "$FAT2_ROOT" 2>>"$DENIED" | sed "s|^$FAT2_ROOT/||" | redact | head -20 | tee -a "$REPORT"
sub "Oracle wallets (inventory only — never dumped)"
find "$FAT1_ROOT" "$FAT2_ROOT" \( -name cwallet.sso -o -name 'ewallet.p12' -o -name 'ewallet.pem' \) -printf '%p\t%u:%g\t%m\t%s bytes\n' 2>>"$DENIED" | tee -a "$REPORT"

# =============================================================================
hr "2. CERTIFICATES / KEYSTORES / TRUSTSTORES"
sub "Inventory (both trees) — path / owner:group / mode / bytes"
find "$FAT1_ROOT" "$FAT2_ROOT" \( -name '*.pem' -o -name '*.crt' -o -name '*.cer' -o -name '*.der' \
     -o -name '*.jks' -o -name '*.p12' -o -name '*.pfx' -o -name '*.keystore' -o -name '*.truststore' \) \
     -printf '%p\t%u:%g\t%m\t%s\n' 2>>"$DENIED" | tee -a "$REPORT"

sub "PEM/CRT/CER decode — subject/issuer/dates/SAN/fingerprint; EXPIRED flagged"
if command -v openssl >/dev/null 2>&1; then
    while IFS= read -r c; do
        [ -z "$c" ] && continue
        if openssl x509 -in "$c" -noout >/dev/null 2>&1; then
            say "  $c"
            openssl x509 -in "$c" -noout -subject -issuer -startdate -enddate -serial 2>/dev/null | sed 's/^/    /' | tee -a "$REPORT"
            openssl x509 -in "$c" -noout -fingerprint -sha256 2>/dev/null | sed 's/^/    /' | tee -a "$REPORT"
            openssl x509 -in "$c" -noout -text 2>/dev/null | grep -A1 -i 'Subject Alternative Name' | grep -iE 'DNS:|IP Address:|IP:' | sed 's/^/    SAN:/' | tee -a "$REPORT"
            if ! openssl x509 -in "$c" -noout -checkend 0 >/dev/null 2>&1; then say "    *** EXPIRED ***"; fi
        fi
    done < <(find "$FAT1_ROOT" "$FAT2_ROOT" \( -name '*.pem' -o -name '*.crt' -o -name '*.cer' \) 2>>"$DENIED")
else
    say "  (openssl not available — cert decode skipped)"
fi

sub "JKS/P12/keystores — alias & validity DEFERRED (needs store password)"
say "  Listing aliases/validity requires -storepass and is NOT attempted here"
say "  (no secrets). Phase 2b: supply each store password securely (file/prompt,"
say "  never a CLI arg) and we'll script: keytool -list -v -keystore <ks>."

sub "Binary checksum compare FAT1 vs FAT2 (same relpath) — detect corruption/identical"
while IFS= read -r rel; do
    [ -z "$rel" ] && continue
    f1="$FAT1_ROOT/$rel"; f2="$FAT2_ROOT/$rel"
    [ -f "$f1" ] && [ -f "$f2" ] || continue
    h1="$(sha256sum "$f1" 2>>"$DENIED" | awk '{print $1}')"
    h2="$(sha256sum "$f2" 2>>"$DENIED" | awk '{print $1}')"
    if [ -n "$h1" ] && [ "$h1" = "$h2" ]; then
        say "  IDENTICAL  $rel"
    else
        say "  DIFFERS    $rel   (FAT1 $h1 / FAT2 $h2 — suspect if this is a keystore/jar)"
    fi
done < <( ( cd "$FAT2_ROOT" 2>/dev/null && find . \( -name '*.jks' -o -name '*.p12' -o -name '*.keystore' -o -name '*.truststore' -o -name '*.jar' \) -printf '%P\n' 2>>"$DENIED" ) )

# =============================================================================
hr "0. SCHEDULED / STARTUP"
sub "crontab for $(id -un) (redacted)"
crontab -l 2>/dev/null | redact | tee -a "$REPORT" || say "  (none or not permitted)"
sub "cron lines referencing '$FAT1_TOKEN'"
crontab -l 2>/dev/null | grep -- "$FAT1_TOKEN" | redact | tee -a "$REPORT" || say "  (none)"
sub "systemd units mentioning opc_d / tomcat (read-only listing)"
systemctl list-units --all --no-pager 2>/dev/null | grep -iE 'opc_d|tomcat|fat[12]' | tee -a "$REPORT" || say "  (none / no systemd / not permitted)"

# =============================================================================
hr "SUMMARY (counts — high signal)"
say "  FAT1 unreadable by $(id -un)        : $(wc -l < "$UNREAD")"
say "  Missing in FAT2                     : $(wc -l < "$MISS")"
say "  Extra in FAT2 (FAT2-unique)         : $(wc -l < "$EXTRA")"
say "  Unrewritten (still has $FAT1_TOKEN)   : $(wc -l < "$UNREW")"
say "  Symlinks STALE into FAT1            : $(wc -l < "$STALE")"
say "  Symlinks BROKEN                     : $(wc -l < "$BROKEN")"
say "  Symlinks SHARED intentional (keep)  : $(wc -l < "$SHARED_OK")"
say "  Symlinks SHARED review              : $(wc -l < "$SHARED_REV")"
say "  FAT2 entries not owned by $FAT2_USER : $(wc -l < "$OWN")"
say "  Permission-denied lines             : $(wc -l < "$DENIED")"
say ""
say "Report written: $REPORT"
say "Also: per-category lists in $REPORT_DIR/  (no secrets included)."
say "Send back $REPORT (and $DENIED if non-empty) for the Phase 1/2 analysis."
