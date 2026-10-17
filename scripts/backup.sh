#!/usr/bin/env bash
# usage: backup.sh [container]   (default mysql-primary)
source "$(dirname "$0")/lib.sh"
SRC=${1:-mysql-primary}
F=/data/backups/appdb-$(date +%F-%H%M%S).sql.gz
docker exec -e MYSQL_PWD="$MYSQL_ROOT_PASSWORD" "$SRC" mysqldump -uroot \
  --single-transaction --source-data=2 --set-gtid-purged=ON \
  --routines --triggers --events --databases appdb | gzip > "$F"
echo "$F"; zcat "$F" | grep -m2 -E "GTID_PURGED|CHANGE REPLICATION SOURCE"
