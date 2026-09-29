#!/usr/bin/env bash
# Удаляет всё, что начинается с "$PREFIX-", не полагаясь на состав стенда.
set -uo pipefail
PREFIX="${PREFIX:-poeluev-05}"
while [ $# -gt 0 ]; do
  case "$1" in
    --prefix) PREFIX="$2"; shift 2 ;;
    *) echo "неизвестный аргумент: $1" >&2; exit 2 ;;
  esac
done

del_all() { # $1 — группа команд yc, например "compute instance"
  yc $1 list --format json \
    | jq -r --arg p "$PREFIX-" '.[] | select(.name | startswith($p)) | .name' \
    | while read -r name; do
        echo "удаляю [$1]: $name"
        yc $1 delete "$name" >/dev/null
      done
}

del_all "load-balancer network-load-balancer"
del_all "load-balancer target-group"
del_all "compute instance"
del_all "vpc subnet"
del_all "vpc route-table"
del_all "vpc gateway"
del_all "vpc security-group"
del_all "vpc network"
