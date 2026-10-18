#!/usr/bin/env bash
# usage: status.sh            -> health/role summary of every MySQL container on this VM
# Safe to run any time; read-only queries only.
source "$(dirname "$0")/lib.sh"
echo "=== $(hostname)  $(date -u '+%F %T UTC')"
for c in mysql-primary mysql-replica mysql-dr; do
  docker ps --format '{{.Names}}' | grep -qx "$c" || continue
  echo "--- $c"
  sql "$c" -N -e "SELECT CONCAT('version=',VERSION(),'  server_id=',@@server_id,'  read_only=',@@read_only,'  super_read_only=',@@super_read_only)" 2>/dev/null
  sql "$c" -N -e "SELECT CONCAT('gtid_executed=',REPLACE(@@GLOBAL.gtid_executed,'\n',''))" 2>/dev/null
  sql "$c" -N -e "SELECT CONCAT('rows appdb.orders=',COUNT(*),'  max_id=',MAX(id)) FROM appdb.orders" 2>/dev/null
  sql "$c" -N -e "SHOW GLOBAL STATUS WHERE Variable_name IN
      ('Rpl_semi_sync_source_status','Rpl_semi_sync_source_clients','Rpl_semi_sync_source_yes_tx','Rpl_semi_sync_source_no_tx','Rpl_semi_sync_replica_status','Threads_connected')" 2>/dev/null | sed 's/^/  /'
  rs=$(sql "$c" -e "SHOW REPLICA STATUS\G" 2>/dev/null | grep -E ' (Source_Host|Source_Port|Replica_IO_Running|Replica_SQL_Running|Seconds_Behind_Source|Last_IO_Error|Last_SQL_Error):')
  if [ -n "$rs" ]; then echo "$rs"; else echo "  (not a replica)"; fi
done
if docker ps --format '{{.Names}}' | grep -qx proxysql; then
  echo "--- proxysql runtime_mysql_servers"
  padmin -e "SELECT hostgroup_id,hostname,status FROM runtime_mysql_servers ORDER BY hostgroup_id,hostname;"
fi
echo "--- disk"; df -h /data | tail -1
