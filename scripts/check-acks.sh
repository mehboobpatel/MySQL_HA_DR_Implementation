#!/usr/bin/env bash
# usage: check-acks.sh <host> <port>  -> acknowledged ids missing on that server = lost writes
source "$(dirname "$0")/lib.sh"
export MYSQL_PWD="$APP_PASSWORD"
awk '{print $2}' "${ACK:-ack.log}" | sort > /tmp/acked.txt
mysql -h"$1" -P"$2" -uapp -N -B -e "SELECT id FROM appdb.orders WHERE source='workload'" | sort > /tmp/present.txt
echo "acknowledged: $(wc -l < /tmp/acked.txt)   lost: $(comm -23 /tmp/acked.txt /tmp/present.txt | wc -l)"
comm -23 /tmp/acked.txt /tmp/present.txt | head
