REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
set -a; source "$REPO/.env"; set +a
# sql <container> [mysql args...]
sql() { local c=$1; shift; docker exec -i -e MYSQL_PWD="$MYSQL_ROOT_PASSWORD" "$c" mysql -uroot "$@"; }
# wait until the real server (not the entrypoint's temporary init server) is up
waitdb() { until docker logs "$1" 2>&1 | grep -q "ready for connections.*port: 3306"; do sleep 3; done; echo "$1 ready"; }
