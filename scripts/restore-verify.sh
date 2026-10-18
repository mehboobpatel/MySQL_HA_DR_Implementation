#!/usr/bin/env bash
# usage: restore-verify.sh <backup.sql.gz> [source-container]
source "$(dirname "$0")/lib.sh"
F=${1:?backup file}; SRC=${2:-mysql-primary}
docker rm -f mysql-restore >/dev/null 2>&1
docker run --disable-content-trust -d --name mysql-restore -e MYSQL_ROOT_PASSWORD="$MYSQL_ROOT_PASSWORD" \
  -v "$REPO/config/common.cnf:/etc/mysql/conf.d/00-common.cnf:ro" \
  -v "$REPO/config/site2/restore.cnf:/etc/mysql/conf.d/10-server.cnf:ro" mysql:8.4 >/dev/null
waitdb mysql-restore
sql mysql-restore -e "RESET BINARY LOGS AND GTIDS;"
zcat "$F" | sql mysql-restore
N=$(sql mysql-restore -N -e "SELECT MAX(id) FROM appdb.orders")
Q="SELECT COUNT(*), SUM(CRC32(CONCAT_WS('#',id,customer_id,amount,source,created_at))) FROM appdb.orders WHERE id <= $N"
echo "compared rows with id <= $N"
echo "restored: $(sql mysql-restore -N -e "$Q")"
echo "source:   $(sql $SRC -N -e "$Q")"
