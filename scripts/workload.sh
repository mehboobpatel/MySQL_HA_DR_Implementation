#!/usr/bin/env bash
# usage: workload.sh <host> <port>   -> logs every ACKNOWLEDGED insert id to $ACK
source "$(dirname "$0")/lib.sh"
HOST=${1:?host}; PORT=${2:-6033}
ACK=${ACK:-ack.log}; FAIL=${FAIL:-fail.log}
export MYSQL_PWD="$APP_PASSWORD"
while true; do
  t=$(date +%s.%3N)
  if id=$(mysql -h"$HOST" -P"$PORT" -uapp --connect-timeout=2 -N -B -e \
      "INSERT INTO appdb.orders(customer_id,amount,source) VALUES (FLOOR(1+RAND()*1000),ROUND(RAND()*500,2),'workload'); SELECT LAST_INSERT_ID();" 2>/dev/null); then
    echo "$t $id" >> "$ACK"
  else
    echo "$t FAIL" >> "$FAIL"
  fi
  sleep 0.1
done
