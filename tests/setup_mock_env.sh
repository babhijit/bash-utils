#!/bin/bash
# =============================================================================
#
# Script:      tests/setup_mock_env.sh
#
# Description:
#   Builds ONE self-contained MOCK SOURCE tree that satisfies BOTH:
#     (a) the real fat2.csv dataset — every listed path materialized with
#         REALISTIC, type-specific content (Tomcat server.xml/context.xml,
#         java .properties, pkibot .ini, openssl .cnf, setenv.sh shells,
#         certnanny .cfg, crontab .snip, binary .jks keystores, ...), each
#         carrying the migration tokens (fat1/FAT1/opc_d1/opcsvcf1/xbapp_d1)
#         in the places they really appear (paths, hostnames, CNs, env names);
#     (b) the adversarial edge cases E1-E7, injected under <root>/_edge/.
#   Then it emits a COMBINED CSV (<root>/mock_env.csv) = fat2 rows + blank and
#   whitespace-only lines (E1) + edge rows, so a SINGLE pipeline run exercises
#   the real-shaped data and every edge together.
#
#   Realistic content is the point: dummy "config for X" lines barely touch
#   the sed rewrite. Real XML/properties/ini/shell/cnf contain `< > & " / = $`
#   [ ] and multi-line structure, which genuinely tests replace_content_in_file
#   (sed escaping), validate (recomputed-rewrite diff), and byte-exact rollback.
#   A binary .jks is included on purpose to exercise content handling on a
#   non-text keystore whose NAME carries a token.
#
#   Everything lives UNDER --root (default /tmp/mock_src) — safe to run
#   anywhere; it never touches the real /applications tree. Companion runner:
#   tests/run_mock_env_test.sh.
#
# Edge cases (mirror tests/edge_cases.sh, now inside the mock source):
#   E1 blank/whitespace CSV lines · E2 spaces in path · E3 dir-rename row +
#   descendant row · E4 fat1_X & fat2_X coexist (redirect) · E5 dangling
#   symlink needing remap · E7 dir whose mtime drifts on child rename.
#   (E6 — rollback round-trip — is exercised by the runner's rollback phase.)
#
# Linux + GNU coreutils only.
#
# Usage:
#   bash tests/setup_mock_env.sh [--root DIR] [--csv fat2.csv] [--out CSV] [--reset]
#
# =============================================================================

set -uo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

ROOT="/tmp/mock_src"
CSV="${REPO}/tests/cases/fat2.csv"
OUT=""
RESET=0
EDGE_TS="2020-06-15 12:00:00 +0000"

usage() {
    cat >&2 <<EOF
Usage: $0 [--root DIR] [--csv FAT2_CSV] [--out COMBINED_CSV] [--reset]

  --root   DIR   Mock source root (default: /tmp/mock_src). Everything builds
                 under here; the emitted CSV's paths all live under it.
  --csv    PATH  Real 3-col CSV to materialize (default: tests/cases/fat2.csv).
  --out    PATH  Combined CSV to emit (default: <root>/mock_env.csv).
  --reset        Remove <root> first (only if /tmp/* or marked .MOCK_ENV).
EOF
    exit 1
}

while [ "$#" -gt 0 ]; do
    case "$1" in
        --root)  ROOT="$2"; shift 2 ;;
        --csv)   CSV="$2"; shift 2 ;;
        --out)   OUT="$2"; shift 2 ;;
        --reset) RESET=1; shift ;;
        -h|--help) usage ;;
        *) echo "Error: unknown argument '$1'" >&2; usage ;;
    esac
done

ROOT="${ROOT%/}"
[ -n "$ROOT" ] || { echo "Error: --root cannot be empty" >&2; exit 1; }
[ -f "$CSV" ] || { echo "Error: CSV not found: $CSV" >&2; exit 1; }
OUT="${OUT:-${ROOT}/mock_env.csv}"
MARKER="${ROOT}/.MOCK_ENV"
EDGE_ABS="${ROOT}/applications/opc_d2/_edge"

# --- Safety: never clobber a real (non-mock) tree ----------------------------
if [ "$RESET" -eq 1 ] && [ -e "$ROOT" ]; then
    case "$ROOT" in
        /tmp/*) rm -rf "$ROOT" ;;
        *) if [ -f "$MARKER" ]; then rm -rf "$ROOT"; else
               echo "Refusing --reset on non-/tmp dir without a .MOCK_ENV marker: $ROOT" >&2; exit 1
           fi ;;
    esac
fi
if [ -e "$ROOT" ] && [ -n "$(ls -A "$ROOT" 2>/dev/null)" ] && [ ! -f "$MARKER" ]; then
    echo "Refusing to use non-empty, non-mock dir as --root: $ROOT (no .MOCK_ENV marker)" >&2
    exit 1
fi
mkdir -p "$ROOT"; : > "$MARKER"

echo "setup_mock_env: building REALISTIC mock source under $ROOT"

# =============================================================================
#                       REALISTIC, TYPE-SPECIFIC CONTENT
# =============================================================================
# Each generator prints a realistic file body to stdout (caller redirects).
# A one-line header naming the file is prepended so otherwise-identical
# backups differ slightly. Quoted heredocs keep `$VAR` literal in the output.

gen_shell() {
    printf '#!/bin/sh\n# %s — Tomcat environment for Server_8_FAT2 (env FAT1, instance opc_d1)\n' "$1"
    cat <<'EOF'
export CATALINA_BASE=/applications/opc_d1/application/Server_8_FAT2
export CATALINA_HOME=/applications/opc_d1/application/Server_8_FAT2
export JAVA_HOME=/applications/opc_d1/jvm/current
export LOG_DIR=/applications/opc_d1/logs
export APP_USER=xbapp_d1
export MQ_SVC_HOST=opcsvcf1.de.db.com
export TC_KEYSTORE=/applications/opc_d1/security/fat1_tomcat_jks
JAVA_OPTS="$JAVA_OPTS -Denv=FAT1 -Dservice=opcsvcf1 -Duser.home=/home/xbapp_d1"
export JAVA_OPTS
EOF
}

gen_xml() {
    printf '<?xml version="1.0" encoding="UTF-8"?>\n<!-- %s : Server_8_FAT2 / opc_d1 -->\n' "$1"
    cat <<'EOF'
<Server port="8005" shutdown="SHUTDOWN">
  <!-- user xbapp_d1 &amp; group xbapp on host opcsvcf1.de.db.com -->
  <Service name="Catalina-FAT1">
    <Connector port="8443" protocol="HTTP/1.1" SSLEnabled="true"
               keystoreFile="/applications/opc_d1/security/wallets/opcsvcf1.de.db.com.jks"
               keystorePass="changeit" sslProtocol="TLS" />
    <Engine name="Catalina" defaultHost="opcsvcf1.de.db.com">
      <Host name="opcsvcf1.de.db.com" appBase="webapps" unpackWARs="true" autoDeploy="false">
        <Context path="" docBase="/applications/opc_d1/application/Server_8_FAT2/webapps/opc" />
        <Valve className="org.apache.catalina.valves.AccessLogValve"
               directory="/applications/opc_d1/logs" prefix="opcsvcf1_access" suffix=".log" />
      </Host>
    </Engine>
  </Service>
</Server>
EOF
}

gen_properties() {
    printf '# %s — logging/config for opc_d1 / FAT1\n' "$1"
    cat <<'EOF'
handlers = 1catalina.org.apache.juli.AsyncFileHandler, java.util.logging.ConsoleHandler
1catalina.org.apache.juli.AsyncFileHandler.directory = /applications/opc_d1/logs
1catalina.org.apache.juli.AsyncFileHandler.prefix = opcsvcf1.
1catalina.org.apache.juli.AsyncFileHandler.maxDays = 90
fat1.app.user = xbapp_d1
fat1.svc.host = opcsvcf1.de.db.com
fat1.keystore = /applications/opc_d1/security/fat1_mq_jks
EOF
}

gen_ini() {
    printf '; %s — pkibot config (opcsvcf1 / FAT1)\n' "$1"
    cat <<'EOF'
[pkibot]
service       = opcsvcf1
environment   = FAT1
keystore      = /applications/opc_d1/security/pkibot_config/fat1_mq_jks
keystore_pass = changeit
cn            = opcsvcf1.de.db.com
host          = mqofat1
owner         = xbapp_d1
[renewal]
ca_url   = https://pki.de.db.com/opcsvcf1/getNextCA
work_dir = /applications/opc_d1/tools/pkibot_working/mq-opcsvcf1
EOF
}

gen_cnf() {
    printf '# %s — certnanny / openssl request (mq service fat1, user xbapp_d1)\n' "$1"
    cat <<'EOF'
[ req ]
distinguished_name = dn
prompt             = no
[ dn ]
CN = opcsvcf1.de.db.com
O  = opc_d1
OU = FAT1
[ ext ]
subjectAltName = DNS:opcsvcf1.de.db.com, DNS:mqofat1.de.db.com
EOF
}

gen_cfg() {
    printf '# %s — certstore config (opcsvcf1 / FAT1)\n' "$1"
    cat <<'EOF'
keystore.path  = /applications/opc_d1/security/wallets/opcsvcf1.de.db.com.jks
keystore.alias = mqofat1
keystore.type  = JKS
service.user   = xbapp_d1
service.host   = opcsvcf1.de.db.com
env            = FAT1
EOF
}

gen_conf() {
    printf '# %s — agent config for opc_d1 / FAT1\n' "$1"
    cat <<'EOF'
agent.home      = /applications/opc_d1/tools/ucd/udeploy/ibm-ucdagent
agent.user      = xbapp_d1
agent.classpath = /applications/opc_d1/lib:/applications/opc_d1/tools/ucd
agent.host      = opcsvcf1.de.db.com
agent.env       = FAT1
EOF
}

gen_cron() {
    printf '# %s — cron snippet (opcsvcf1 / FAT1)\n' "$1"
    cat <<'EOF'
0 2 * * * xbapp_d1 /applications/opc_d1/tools/certnanny/mq-opcsvcf1/renew.sh >> /applications/opc_d1/logs/certnanny.log 2>&1
30 3 * * 0 xbapp_d1 /applications/opc_d1/tools/pkibot_working/mq-opcsvcf1/pkibot.sh
EOF
}

gen_csv_file() {
    printf 'id,service,host,user,keystore\n'
    cat <<'EOF'
1,opcsvcf1,opcsvcf1.de.db.com,xbapp_d1,/applications/opc_d1/security/fat1_mq_jks
2,mqofat1,mqofat1.de.db.com,xbapp_d1,/applications/opc_d1/security/fat1_tomcat_jks
EOF
}

# Binary keystore: JKS magic 0xFEEDFEED + version, alias/CN/path strings that
# carry the tokens (real keystores store these as bytes), and raw high/NUL
# bytes so it is genuinely non-text. Exercises content handling on a binary
# whose NAME also carries a token.
gen_jks() {
    printf '\376\355\376\355\000\000\000\002\000\000\000\001'
    printf 'alias=opcsvcf1.de.db.com_mqofat1\000'
    printf 'CN=opcsvcf1.de.db.com,O=opc_d1,OU=FAT1,L=xbapp_d1\000'
    printf 'path=/applications/opc_d1/security/wallets\000'
    printf '\000\001\002\003\377\376\375\374\200\177\000'
}

gen_generic() {
    printf '# %s — opc_d1 / FAT1 node\n' "$1"
    cat <<'EOF'
host:     opcsvcf1.de.db.com
service:  opcsvcf1
appbase:  /applications/opc_d1
user:     xbapp_d1
env:      FAT1
EOF
}

# gen_content <abs_path>  — dispatch on basename to a realistic generator.
gen_content() {
    local base; base="$(basename "$1")"
    case "$base" in
        *.jks|*.jks.*|*.jks_*|*tmpkeystore*)              gen_jks ;;
        *.xml|*.xml.*|*.xml_*)                            gen_xml "$base" ;;
        *.properties|*.properties.*)                      gen_properties "$base" ;;
        *.pkibot.ini|*Pkibot.ini*|*.ini|*.ini_*|*.inf)    gen_ini "$base" ;;
        *.cnf)                                            gen_cnf "$base" ;;
        *.cfg)                                            gen_cfg "$base" ;;
        *.conf|installed.properties)                      gen_conf "$base" ;;
        *.snip)                                           gen_cron "$base" ;;
        *.csv)                                            gen_csv_file ;;
        *.sh|*.sh.*|*.sh_*|setenv*|bld.*|tail.*|rc_art*)  gen_shell "$base" ;;
        agent|*-agent|configure-agent|*control|*.bak|*.out|worker-args.conf) gen_conf "$base" ;;
        *)                                                gen_generic "$base" ;;
    esac
}

FAT2_ROWS="$(mktemp)"; EDGE_ROWS="$(mktemp)"
trap 'rm -f "$FAT2_ROWS" "$EDGE_ROWS"' EXIT

# =============================================================================
# (a) Materialize the fat2.csv dataset under $ROOT (realistic content).
# =============================================================================
materialize_fat2() {
    local -a abs=() ts=()
    local p t
    while IFS=$'\t' read -r p t; do
        [ -z "$p" ] && continue
        abs+=("$p"); ts+=("$t")
    done < <(awk -F, 'NR>1 && $2!="" {print $2"\t"$3}' "$CSV")

    local i j isdir mock_path
    for ((i = 0; i < ${#abs[@]}; i++)); do
        isdir=0
        for ((j = 0; j < ${#abs[@]}; j++)); do
            case "${abs[$j]}" in "${abs[$i]}"/*) isdir=1; break ;; esac
        done
        mock_path="${ROOT}${abs[$i]}"
        if [ "$isdir" -eq 1 ]; then
            mkdir -p "$mock_path"
        else
            mkdir -p "$(dirname "$mock_path")"
            gen_content "${abs[$i]}" > "$mock_path"
        fi
        printf '"%s","%s","%s"\n' "$(basename "${abs[$i]}")" "$mock_path" "${ts[$i]}" >> "$FAT2_ROWS"
    done

    for ((i = 0; i < ${#abs[@]}; i++)); do
        local cts="${ts[$i]}"
        cts="${cts#"${cts%%[![:space:]]*}"}"; cts="${cts%"${cts##*[![:space:]]}"}"
        touch -h -d "$cts" "${ROOT}${abs[$i]}" 2>/dev/null || echo "  WARN: touch failed: ${ROOT}${abs[$i]}" >&2
    done
    echo "  fat2 rows materialized: ${#abs[@]} (realistic content by file type)"
}

emit_edge_row() { printf '"%s","%s","%s"\n' "$1" "$2" "$EDGE_TS" >> "$EDGE_ROWS"; }

# =============================================================================
# (b) Inject the edge cases under $EDGE_ABS (also realistic content).
# =============================================================================
inject_edges() {
    mkdir -p "$EDGE_ABS"

    # E2 — path containing spaces (realistic certstore cfg).
    mkdir -p "${EDGE_ABS}/dir with space"
    gen_content "fat1 file.cfg" > "${EDGE_ABS}/dir with space/fat1 file.cfg"
    emit_edge_row "fat1 file.cfg" "${EDGE_ABS}/dir with space/fat1 file.cfg"

    # E3 — directory row + descendant row (descendant carries a fat1 name).
    mkdir -p "${EDGE_ABS}/svc/mq-opcsvcf1"
    gen_content "fat1_child.cnf" > "${EDGE_ABS}/svc/mq-opcsvcf1/fat1_child.cnf"
    emit_edge_row "mq-opcsvcf1"    "${EDGE_ABS}/svc/mq-opcsvcf1"
    emit_edge_row "fat1_child.cnf" "${EDGE_ABS}/svc/mq-opcsvcf1/fat1_child.cnf"

    # E4 — fat1_X and fat2_X coexist. gen_ini naturally embeds fat1 tokens, so
    # fat2_mq.ini realistically carries stray fat1 references to be rewritten.
    mkdir -p "${EDGE_ABS}/coexist"
    gen_content "fat1_mq.pkibot.ini" > "${EDGE_ABS}/coexist/fat1_mq.pkibot.ini"
    gen_content "fat2_mq.pkibot.ini" > "${EDGE_ABS}/coexist/fat2_mq.pkibot.ini"
    emit_edge_row "fat1_mq.pkibot.ini" "${EDGE_ABS}/coexist/fat1_mq.pkibot.ini"
    emit_edge_row "fat2_mq.pkibot.ini" "${EDGE_ABS}/coexist/fat2_mq.pkibot.ini"

    # E5 — symlink with fat1 in name + dangling target needing remap.
    mkdir -p "${EDGE_ABS}/links"
    ln -s /applications/opc_d1/security/fat1_mq_jks "${EDGE_ABS}/links/fat1_link"
    emit_edge_row "fat1_link" "${EDGE_ABS}/links/fat1_link"

    # E7 — a directory whose mtime will drift when its fat1-named child renames.
    mkdir -p "${EDGE_ABS}/mtime"
    gen_content "fat1_x.cfg" > "${EDGE_ABS}/mtime/fat1_x.cfg"
    emit_edge_row "fat1_x.cfg" "${EDGE_ABS}/mtime/fat1_x.cfg"

    find "$EDGE_ABS" -depth -print0 2>/dev/null | xargs -0 touch -h -d "$EDGE_TS"
    echo "  edge rows injected (E2-E5, E7) under ${EDGE_ABS#$ROOT}"
}

materialize_fat2
inject_edges

# =============================================================================
# Combined CSV: header + fat2 rows + E1 blank/whitespace + edge rows.
# =============================================================================
{
    echo "Name,Absolute_Path,Last_Modified"
    cat "$FAT2_ROWS"
    echo ""        # E1: blank line
    echo "   "     # E1: whitespace-only line
    cat "$EDGE_ROWS"
} > "$OUT"

echo ""
echo "Combined CSV: $OUT"
echo "  source-root for the pipeline: $ROOT"
echo "  file types materialized: $(find "$ROOT" -type f ! -name '.MOCK_ENV' ! -name 'mock_env.csv' \
      -printf '%f\n' 2>/dev/null | sed 's/.*\.//' | sort | uniq -c | awk '{printf "%s(%s) ",$2,$1}')"
echo ""
echo "Drive it with the runner (recommended), which also checks per-edge outcomes:"
echo "  bash ${REPO}/tests/run_mock_env_test.sh"
echo "Or just the standard pipeline:"
echo "  NONINTERACTIVE=1 bash ${REPO}/bin/setup_migrator_test.sh --mode all \\"
echo "      --csv $OUT --source-root $ROOT --mock-root /tmp/mock_f2 --workdir /tmp/migration_f2_test"
