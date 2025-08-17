#!/bin/bash
# 通用 Debian 源码编译安装 MySQL/MariaDB（全新初始化，备份旧数据；my.cnf 用用户样板并自动调优）
# 用法: sudo ./install_db_from_source_debian.sh <mysql|mariadb> <版本号> <安装目录> <root密码> [端口=3306] [bind=127.0.0.1]
# 例子:
#   sudo ./install_db_from_source_debian.sh mysql 8.0.37 /usr/local/mysql 'MyRootPass!' 3306 0.0.0.0
#   sudo ./install_db_from_source_debian.sh mariadb 10.11.8 /usr/local/mariadb 'MyRootPass!'

set -euo pipefail

########################################
# 环境变量（适配最小化 Debian）
########################################
export PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"
export DEBIAN_FRONTEND="noninteractive"
umask 022

########################################
# 参数
########################################
if [[ $EUID -ne 0 ]]; then
  echo "[ERROR] 请使用 root 运行（sudo）。"; exit 1
fi
if [[ $# -lt 4 ]]; then
  echo "用法: $0 <mysql|mariadb> <版本号> <安装目录> <root密码> [端口=3306] [bind=127.0.0.1]"
  exit 1
fi

DB_TYPE="$1"                              # mysql|mariadb
DB_VER="$2"
INSTALL_DIR="$(readlink -f "$3")"
ROOT_PASS="$4"
DB_PORT="${5:-3306}"
DB_BIND="${6:-127.0.0.1}"

VAR_DIR="$INSTALL_DIR/var"                # 按你的样板：datadir 用 var
ETC_DIR="$INSTALL_DIR/etc"
SOCK="/tmp/mysql.sock"                    # 按你的样板：socket 指向 /tmp/mysql.sock
PID_FILE="$INSTALL_DIR/mysql.pid"
SRC_ROOT="/usr/local/src"
SERVICE_NAME="mysql"

trap 'echo "[ERROR] 发生错误，查看上方日志。"' ERR
msg(){ echo -e "\n[INFO] $*"; }

########################################
# 依赖
########################################
msg "安装依赖（Debian 全系通用）..."
apt-get update -y
apt-get install -y \
  build-essential cmake bison pkg-config \
  libncurses-dev libssl-dev zlib1g-dev libaio-dev libtirpc-dev \
  libreadline-dev libcurl4-openssl-dev ca-certificates \
  libjemalloc2 wget curl tar xz-utils bzip2 openssl

mkdir -p "$INSTALL_DIR" "$ETC_DIR" "$SRC_ROOT"

########################################
# 获取硬件参数并推算优化值
########################################
CORES="$(nproc || echo 1)"
MEM_MB="$(awk '/MemTotal/ {print int($2/1024)}' /proc/meminfo 2>/dev/null || echo 1024)"

# innodb_buffer_pool_size（MB）
if   (( MEM_MB <= 2048 )); then BP_MB=256
elif (( MEM_MB <= 8192 )); then BP_MB=$(( MEM_MB*50/100 ))
elif (( MEM_MB <= 16384 )); then BP_MB=$(( MEM_MB*60/100 ))
else                           BP_MB=$(( MEM_MB*70/100 ))
fi
# 按 128MB 对齐
BP_MB=$(( (BP_MB/128)*128 )); (( BP_MB < 256 )) && BP_MB=256

# redo 容量（MB），取 max(512, BP/4)，上限 8192MB
RLOG_MB=$(( BP_MB/4 ))
(( RLOG_MB < 512 )) && RLOG_MB=512
(( RLOG_MB > 8192 )) && RLOG_MB=8192

# tmp_table_size / max_heap_table_size（MB）
if   (( MEM_MB <= 4096 )); then TMP_MB=64
elif (( MEM_MB <= 16384 )); then TMP_MB=128
else                            TMP_MB=256
fi

# 连接与缓存
if   (( MEM_MB <= 2048 )); then MAX_CONN=200;  TOC=512
elif (( MEM_MB <= 16384 )); then MAX_CONN=500; TOC=1024
else                            MAX_CONN=1000; TOC=2048
fi
THREAD_CACHE=$(( CORES*16 )); (( THREAD_CACHE < 64 )) && THREAD_CACHE=64
PERF_TBL=$(( 4000 + CORES*1000 )); (( PERF_TBL > 32768 )) && PERF_TBL=32768

########################################
# 下载源码
########################################
download_mysql(){
  local tball="mysql-$DB_VER.tar.gz"
  if [[ ! -f "$SRC_ROOT/$tball" ]]; then
    msg "下载 MySQL $DB_VER 源码..."
    wget -O "$SRC_ROOT/$tball" "https://downloads.mysql.com/archives/get/p/23/file/mysql-$DB_VER.tar.gz"
  fi
  tar -xf "$SRC_ROOT/$tball" -C "$SRC_ROOT"
  echo "$SRC_ROOT/mysql-$DB_VER"
}
download_mariadb(){
  local tball="mariadb-$DB_VER.tar.gz"
  if [[ ! -f "$SRC_ROOT/$tball" ]]; then
    msg "下载 MariaDB $DB_VER 源码..."
    wget -O "$SRC_ROOT/$tball" "https://archive.mariadb.org/mariadb-$DB_VER/source/mariadb-$DB_VER.tar.gz"
  fi
  tar -xf "$SRC_ROOT/$tball" -C "$SRC_ROOT"
  echo "$SRC_ROOT/mariadb-$DB_VER"
}

msg "选择数据库: $DB_TYPE $DB_VER"
case "$DB_TYPE" in
  mysql)   SRC_DIR="$(download_mysql)";;
  mariadb) SRC_DIR="$(download_mariadb)";;
  *) echo "[ERROR] 数据库类型必须是 mysql 或 mariadb"; exit 1;;
esac

########################################
# 编译安装（out-of-source）
########################################
msg "创建 out-of-source 构建目录并配置..."
cd "$SRC_DIR"
rm -rf CMakeCache.txt CMakeFiles || true
mkdir -p build
cd build

COMMON_CMAKE_ARGS=(
  -DCMAKE_INSTALL_PREFIX="$INSTALL_DIR"
  -DMYSQL_DATADIR="$VAR_DIR"
  -DSYSCONFDIR="$ETC_DIR"
  -DMYSQL_UNIX_ADDR="$SOCK"
  -DDEFAULT_CHARSET=utf8mb4
  -DWITH_SSL=system
  -DWITH_ZLIB=system
)
if [[ "$DB_TYPE" == "mysql" ]]; then
  COMMON_CMAKE_ARGS+=( -DDEFAULT_COLLATION=utf8mb4_0900_ai_ci )
else
  COMMON_CMAKE_ARGS+=( -DDEFAULT_COLLATION=utf8mb4_general_ci )
fi

if [[ "$DB_TYPE" == "mysql" ]]; then
  BOOST_DIR="$SRC_DIR/boost"; mkdir -p "$BOOST_DIR"
  cmake .. "${COMMON_CMAKE_ARGS[@]}" -DDOWNLOAD_BOOST=1 -DWITH_BOOST="$BOOST_DIR"
else
  cmake .. "${COMMON_CMAKE_ARGS[@]}"
fi

msg "编译并安装（可能耗时）..."
make -j"$(nproc)"
make install

########################################
# 生成 my.cnf（按你的样板 + 自动调优 + 8.0 兼容）
########################################
msg "生成 my.cnf（样板 + 自动调优）..."
# 寻找 jemalloc（优先 x86_64 标准路径）
JEMALLOC=""
for CAND in /usr/lib/x86_64-linux-gnu/libjemalloc.so.2 /usr/lib/libjemalloc.so /usr/lib/libjemalloc.so.2; do
  [[ -f "$CAND" ]] && { JEMALLOC="$CAND"; break; }
done

cat > "$ETC_DIR/my.cnf" <<EOF
[client]
#password   = your_password
port        = $DB_PORT
socket      = $SOCK

[mysqld]
port        = $DB_PORT
socket      = $SOCK
datadir     = $VAR_DIR
skip-external-locking

# -------- MyISAM / 通用连接缓存（按样板 + 适度调优）--------
key_buffer_size                 = 128M
max_allowed_packet              = 16M
table_open_cache                = $TOC
sort_buffer_size                = 2M
net_buffer_length               = 8K
read_buffer_size                = 2M
read_rnd_buffer_size            = 512K
myisam_sort_buffer_size         = 32M
thread_cache_size               = $THREAD_CACHE
tmp_table_size                  = ${TMP_MB}M
max_heap_table_size             = ${TMP_MB}M
performance_schema_max_table_instances = $PERF_TBL

explicit_defaults_for_timestamp = true
#skip-networking
max_connections                 = $MAX_CONN
max_connect_errors              = 100
open_files_limit                = 65535
default_authentication_plugin   = mysql_native_password

# -------- 主从与二进制日志（按样板）--------
log-bin                         = mysql-bin
binlog_format                   = mixed
server-id                       = 1
binlog_expire_logs_seconds      = 864000
early-plugin-load               = ""

# -------- InnoDB（按样板 + 8.0 兼容与调优）--------
default_storage_engine          = InnoDB
innodb_file_per_table           = 1
innodb_data_home_dir            = $VAR_DIR
innodb_data_file_path           = ibdata1:10M:autoextend
innodb_log_group_home_dir       = $VAR_DIR
innodb_buffer_pool_size         = ${BP_MB}M
#innodb_log_file_size           = 128M        # (样板保留为注释；MySQL 8 建议改用 innodb_redo_log_capacity)
innodb_redo_log_capacity        = ${RLOG_MB}M
innodb_log_buffer_size          = 8M
innodb_flush_log_at_trx_commit  = 1
innodb_lock_wait_timeout        = 50

[mysqldump]
quick
max_allowed_packet              = 64M

[mysql]
no-auto-rehash

[myisamchk]
key_buffer_size                 = 128M
sort_buffer_size                = 2M
read_buffer_size                = 2M
write_buffer_size               = 2M

[mysqlhotcopy]
interactive-timeout

[mysqld_safe]
$( [[ -n "$JEMALLOC" ]] && echo "malloc-lib=$JEMALLOC" || echo "# malloc-lib=/usr/lib/libjemalloc.so  # 未找到可用 jemalloc，已注释" )
EOF

########################################
# 停服务 & 备份并清空 var 目录（全新初始化）
########################################
msg "停止可能存在的服务与进程..."
if systemctl list-unit-files | grep -q "^${SERVICE_NAME}.service"; then
  systemctl stop "$SERVICE_NAME" 2>/dev/null || true
  systemctl reset-failed "$SERVICE_NAME" 2>/dev/null || true
fi
pkill -9 mysqld 2>/dev/null || true
sleep 1

msg "备份并彻底清空数据目录（$VAR_DIR）..."
TS="$(date +%F-%H%M%S)"
if [[ -d "$VAR_DIR" && -n "$(ls -A "$VAR_DIR" 2>/dev/null || true)" ]]; then
  echo "[INFO] 检测到已有数据，备份到 ${VAR_DIR}.bak.$TS"
  mv "$VAR_DIR" "${VAR_DIR}.bak.$TS"
fi
mkdir -p "$VAR_DIR"

# 清理所有可见与隐藏条目、防止 lost+found 干扰
if [[ -d "$VAR_DIR/lost+found" ]]; then rmdir "$VAR_DIR/lost+found" 2>/dev/null || true; fi
shopt -s dotglob nullglob
rm -rf "$VAR_DIR"/* || true
shopt -u dotglob nullglob
find "$VAR_DIR" -mindepth 1 -maxdepth 1 -exec rm -rf {} + 2>/dev/null || true
sync; sleep 1
if [[ -n "$(ls -A "$VAR_DIR" 2>/dev/null || true)" ]]; then
  echo "[ERROR] 数据目录仍非空：$(ls -A "$VAR_DIR")"; exit 1
fi

chown -R mysql:mysql "$INSTALL_DIR"

########################################
# 初始化（空密码）
########################################
msg "全新初始化数据目录（空密码模式）..."
if [[ "$DB_TYPE" == "mysql" ]]; then
  "$INSTALL_DIR/bin/mysqld" --initialize-insecure \
    --basedir="$INSTALL_DIR" --datadir="$VAR_DIR" --user=mysql
else
  if   [[ -x "$INSTALL_DIR/scripts/mysql_install_db" ]]; then
    "$INSTALL_DIR/scripts/mysql_install_db" --basedir="$INSTALL_DIR" --datadir="$VAR_DIR" --user=mysql
  elif [[ -x "$INSTALL_DIR/bin/mariadb-install-db" ]]; then
    "$INSTALL_DIR/bin/mariadb-install-db" --basedir="$INSTALL_DIR" --datadir="$VAR_DIR" --user=mysql
  else
    echo "[ERROR] 未找到 MariaDB 初始化脚本（mysql_install_db 或 mariadb-install-db）。"; exit 1
  fi
fi

########################################
# systemd（mysqld --daemonize）
########################################
msg "写入 systemd 服务（mysqld --daemonize）..."
cat >"/etc/systemd/system/${SERVICE_NAME}.service" <<EOF
[Unit]
Description=$( [[ "$DB_TYPE" == "mysql" ]] && echo "MySQL Server (daemonized)" || echo "MariaDB Server (daemonized)" )
After=network.target

[Service]
Type=forking
User=mysql
Group=mysql
ExecStart=$INSTALL_DIR/bin/mysqld --defaults-file=$ETC_DIR/my.cnf --daemonize --pid-file=$PID_FILE
ExecStop=/bin/kill -TERM \$MAINPID
PIDFile=$PID_FILE
LimitNOFILE=50000
TimeoutStartSec=0
TimeoutStopSec=600
Restart=on-failure
RestartSec=3

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable --now "$SERVICE_NAME"

########################################
# 设置 root 密码
########################################
msg "设置 root 密码..."
sleep 5
if ! "$INSTALL_DIR/bin/mysqladmin" -uroot --socket="$SOCK" password "$ROOT_PASS"; then
  "$INSTALL_DIR/bin/mysql" -uroot --socket="$SOCK" --connect-timeout=5 -e "ALTER USER 'root'@'localhost' IDENTIFIED BY '${ROOT_PASS}'; FLUSH PRIVILEGES;" || true
fi

echo
echo "============================================================"
echo "[SUCCESS] $DB_TYPE $DB_VER 已安装并由 systemd 托管（全新初始化完成，旧数据如有已备份到 var.bak.TIMESTAMP）"
echo "[INFO] basedir: $INSTALL_DIR"
echo "[INFO] datadir: $VAR_DIR"
echo "[INFO] config : $ETC_DIR/my.cnf"
echo "[INFO] socket : $SOCK"
echo "[INFO] pid    : $PID_FILE"
echo "[INFO] port   : $DB_PORT"
echo "[INFO] bind   : $DB_BIND"
echo "[INFO] root   : $ROOT_PASS"
echo "管理命令：systemctl status|start|stop $SERVICE_NAME"
echo "============================================================"

