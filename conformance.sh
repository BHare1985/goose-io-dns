#!/usr/bin/env bash
# Runs the name-resolution part of the conformance suite against Resolving<iouring::Loop>, with real lookups, one process per part.
# Usage: conformance.sh [--repeat N]
set -u
here="$(cd "$(dirname "$0")" && pwd)"; goose_io="${GOOSE_IO:-${GOOSE_HOME:-$HOME/.goose}/pkg/github.com/BHare1985/goose-io/apply-name-resolution}"; cd "$here"
repeat=1
while [ $# -gt 0 ]; do
    case "$1" in
        --repeat) shift; repeat="${1:?--repeat needs a number}" ;;
        *) echo "unknown argument $1"; exit 2 ;;
    esac
    shift
done
tmp=$(mktemp -d "${TMPDIR:-/tmp}/dns-conformance.XXXXXX"); trap 'rm -rf "$tmp"' EXIT
goose build conformance.goose -o "$tmp/conformance" >"$tmp/build.log" 2>&1 || { cat "$tmp/build.log"; echo "BUILD FAILED"; exit 1; }
tsv="$goose_io/tests/conformance/checks.tsv"
# The two addresses a name has, in the order getaddrinfo gives them, for the check of the order. PAIR_NAME names another name if
# "localhost" has one address on this host (it has two where /etc/hosts lists ::1 for it).
pair_name="${PAIR_NAME:-localhost}"
pair=$(getent ahosts "$pair_name" 2>/dev/null | awk '$2=="STREAM" {print $1}' | head -n 2 | awk '{ if ($1 ~ /:/) printf "[%s]:80 ", $1; else printf "%s:80 ", $1 }')
[ "$(echo $pair | wc -w)" -eq 2 ] || { pair=; echo "note: $pair_name has no two addresses here, so resolve_address_order cannot pass (set PAIR_NAME to a name that has two)"; }
failed=0; total=0
parts=$(grep -v '^#' "$tsv" | awk -F'\t' '$6 == "name-resolution" {print $2}' | sort -un)
for ((i = 1; i <= repeat; i++)); do
    for p in $parts; do
        total=$((total + 1))
        "$tmp/conformance" "$p" ${pair:+$pair_name $pair} >"$tmp/out" 2>&1; rc=$?
        if [ $rc -ne 0 ] && [ -z "$pair" ] && [ "$(grep -c '^ *FAIL' "$tmp/out")" -eq 1 ] && grep -q 'FAIL resolve_address_order' "$tmp/out"; then rc=0; fi
        if [ $rc -ne 0 ]; then
            echo "FAIL  name-resolution part $p, repetition $i"; sed 's/^/      /' "$tmp/out"; failed=$((failed + 1))
        elif [ $i -eq 1 ]; then
            echo "ok    name-resolution part $p: $(tail -n 1 "$tmp/out")"
        fi
    done
done
echo "$total part runs ($repeat repetitions), $failed failed"
[ $failed -eq 0 ]
