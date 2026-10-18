#!/usr/bin/env bash
# usage: ack-gap.sh [ack.log]
# Largest gap between consecutive acknowledged writes = write downtime the application saw.
F=${1:-ack.log}
read -r gap s e < <(sort -n -k1,1 "$F" | awk 'NR>1 { g=$1-p; if (g>m) { m=g; s=p; e=$1 } } { p=$1 }
  END { printf "%.3f %s %s\n", m, s, e }')
echo "largest gap between acknowledged writes: ${gap} s"
echo "  last ack before: $s ($(date -u -d @"$s" '+%F %T.%3N UTC'))"
echo "  first ack after: $e ($(date -u -d @"$e" '+%F %T.%3N UTC'))"
