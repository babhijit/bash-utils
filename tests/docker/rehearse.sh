#!/usr/bin/env bash
# =============================================================================
# rehearse.sh — bring up / log into / tear down the migration-host rehearsal.
#
# Runs on YOUR dev box (macOS or Linux); needs only Docker. Unlike the suite it
# launches, this wrapper uses no GNU-only commands, so your host bash (3.2 on
# stock macOS, or 5.x via Homebrew) runs it fine.
#
# Usage (from the repo root):
#   bash tests/docker/rehearse.sh build           # build the image (once)
#   bash tests/docker/rehearse.sh up              # start a persistent container
#   bash tests/docker/rehearse.sh login [opc_d2]  # "log in" as a user (su - )
#   bash tests/docker/rehearse.sh ssh-on          # start sshd; prints ssh cmd
#   bash tests/docker/rehearse.sh down            # stop + remove the container
#
# `up` mounts the repo read-only at /repo and copies bin/ (+ fat2.csv) to the
# canonical /tmp/test_f2 paths the RUNBOOK/CHEATSHEET use — so the commands you
# rehearse are byte-for-byte the ones you'll run on the host.
# =============================================================================
set -euo pipefail

IMAGE="bashutils7:rehearsal"
NAME="fat-rehearsal"
SSH_PORT="2222"

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cmd="${1:-help}"; shift || true

case "$cmd" in
  build)
    docker build -t "$IMAGE" -f "$ROOT/tests/docker/Dockerfile.rehearsal" "$ROOT"
    ;;
  up)
    docker run -d --name "$NAME" -p "${SSH_PORT}:22" -v "$ROOT":/repo:ro "$IMAGE"
    # Mirror the host layout: scripts in /tmp/test_f2/bin, CSV at the canonical
    # path, all world-readable so both opc_d1 and opc_d2 can run them.
    docker exec -u 0 "$NAME" bash -c '
        cp -a /repo/bin/. /tmp/test_f2/bin/ &&
        cp -a /repo/tests /tmp/test_f2/tests &&
        cp -a /repo/tests/cases/fat2.csv /tmp/test_f2/fat2.csv &&
        chmod -R a+rX /tmp/test_f2'
    echo "Up. Log in with:  bash tests/docker/rehearse.sh login opc_d2"
    ;;
  login)
    # `su -` runs the full login (env reset, cd to home, login shell) with no
    # sudo available — the closest thing to sshing in as that operator.
    docker exec -it "$NAME" su - "${1:-opc_d2}"
    ;;
  ssh-on)
    docker exec -u 0 "$NAME" /usr/sbin/sshd
    echo "ssh -p ${SSH_PORT} opc_d2@localhost     # password: rehearse"
    echo "ssh -p ${SSH_PORT} opc_d1@localhost     # password: rehearse"
    ;;
  down)
    docker rm -f "$NAME"
    ;;
  *)
    grep '^#' "${BASH_SOURCE[0]}" | sed -n '2,20p' | sed 's/^# \{0,1\}//'
    ;;
esac
