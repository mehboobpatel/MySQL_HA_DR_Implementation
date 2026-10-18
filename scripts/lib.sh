REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
set -a; source "$REPO/.env"; set +a
# sql <container> [mysql args...]   e.g.  sql mysql-dr -e "SELECT 1"
sql() { local c=$1; shift; docker exec -i -e MYSQL_PWD="$MYSQL_ROOT_PASSWORD" "$c" mysql -uroot "$@"; }
# Wait until the real server is up. Only reads logs since the container's current start,
# so a "ready" line from a previous run (or the entrypoint's temporary init server, port 0) is ignored.
waitdb() {
  local since; since=$(docker inspect -f '{{.State.StartedAt}}' "$1")
  until docker logs --since "$since" "$1" 2>&1 | grep -q "ready for connections.*port: 3306"; do sleep 3; done
  echo "$1 ready"
}
# ProxySQL admin (VM1 only; admin port is bound to 127.0.0.1)
padmin() { mysql -h127.0.0.1 -P6032 -uradmin -p"$PROXYSQL_RADMIN_PASSWORD" "$@" 2>/dev/null; }
