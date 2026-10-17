datadir="/var/lib/proxysql"
admin_variables=
{
    admin_credentials="admin:admin;radmin:${PROXYSQL_RADMIN_PASSWORD}"
    mysql_ifaces="0.0.0.0:6032"
}
mysql_variables=
{
    threads=2
    max_connections=1024
    interfaces="0.0.0.0:6033"
    server_version="8.4.0"
    monitor_username="monitor"
    monitor_password="${MONITOR_PASSWORD}"
    monitor_ping_interval=1000
    monitor_read_only_interval=1000
    monitor_read_only_timeout=500
    connect_timeout_server=2000
}
mysql_servers=
(
    { address="mysql-primary", port=3306, hostgroup=10, max_connections=200 },
    { address="mysql-replica", port=3306, hostgroup=20, max_connections=200 }
)
mysql_replication_hostgroups=
(
    { writer_hostgroup=10, reader_hostgroup=20, check_type="read_only", comment="site1" }
)
mysql_users=
(
    { username="app", password="${APP_PASSWORD}", default_hostgroup=10 }
)
