#!/bin/bash
set -euo pipefail

# =========================
# 全站一键部署：Nginx + DB
# 适用 Debian/Ubuntu
# 以 root 运行
# =========================

export PATH=$PATH:/sbin:/usr/sbin

# ---------- 参数 ----------
NGINX_FLAG=0
WITH_MODSECURITY="off"   # off|on

DB_FLAG=0
DB_TYPE=""               # mysql|mariadb
DB_VERSION=""
DB_PREFIX="/usr/local/mysql"
DB_DATADIR="/data/mysql"
DB_ROOT_PASS=""
DB_UPGRADE=0

while [[ $# -gt 0 ]]; do
  case "$1" in
    --nginx) NGINX_FLAG=1; shift ;;
    --with-modsecurity=*) WITH_MODSECURITY="${1#*=}"; shift ;;
    --db) DB_FLAG=1; shift ;;
    --type=*) DB_TYPE="${1#*=}"; shift ;;
    --version=*) DB_VERSION="${1#*=}"; shift ;;
    --prefix=*) DB_PREFIX="${1#*=}"; shift ;;
    --datadir=*) DB_DATADIR="${1#*=}"; shift ;;
    --root-pass=*) DB_ROOT_PASS="${1#*=}"; shift ;;
    --upgrade) DB_UPGRADE=1; shift ;;
    *) echo "未知参数: $1"; exit 1 ;;
  esac
done

if [[ $EUID -ne 0 ]]; then echo "请用 root 运行"; exit 1; fi
if [[ $NGINX_FLAG -eq 0 && $DB_FLAG -eq 0 ]]; then
  echo "至少指定 --nginx 或 --db"; exit 1
fi

# ---------- 通用准备 ----------
apt-get update
apt-get install -y curl ca-certificates git wget rsync

mkdir -p /home/wwwroot/default /home/wwwlogs
if ! id www &>/dev/null; then
  groupadd -r www
  useradd -r -g www -s /usr/sbin/nologin www || useradd -r -g www -s /sbin/nologin www
fi
chown -R www:www /home/wwwroot /home/wwwlogs
chmod -R 0755 /home/wwwroot /home/wwwlogs

# =========================================================
# 函数：安装 Nginx（含 LuaJIT、resty 环境、可选 ModSecurity）
# =========================================================
install_nginx() {
  echo "=== 安装 Nginx & 依赖 ==="
  apt-get install -y \
    build-essential make gcc \
    libpcre3 libpcre3-dev zlib1g-dev libssl-dev \
    libxslt1-dev libgd-dev libgeoip-dev libaio-dev \
    libxml2-dev libxslt-dev libmaxminddb-dev \
    libluajit-5.1-dev libatomic-ops-dev

  # 源码准备
  cd ~
  [[ -d nginx ]] || git clone https://github.com/linwoodpendleton/nginx.git --recursive

  # LuaJIT
  [[ -d luajit2 ]] || git clone https://github.com/openresty/luajit2.git
  cd luajit2 && make && make install && cd -
  ln -sf /usr/local/bin/luajit /usr/local/bin/luajit-2.1.0-beta3 || true
  echo "/usr/local/lib" > /etc/ld.so.conf.d/luajit.conf && ldconfig

  # 安装 lua-resty-core / lrucache 到“标准路径”
  # 固定到与 lua-nginx-module 0.10.28 兼容的稳定 tag，避免 runtime 报错
  rm -rf lua-resty-core lua-resty-lrucache
  git clone https://github.com/openresty/lua-resty-core.git
  (cd lua-resty-core && git fetch --tags && git checkout v0.1.26 && make install LUA_LIB_DIR=/usr/local/share/lua/5.1)
  git clone https://github.com/openresty/lua-resty-lrucache.git
  (cd lua-resty-lrucache && git fetch --tags && git checkout v0.13 && make install LUA_LIB_DIR=/usr/local/share/lua/5.1)

  # 编译 Nginx
  rm -rf /tmp/nginx-quic || true
  ln -sf "$(pwd)/nginx" /tmp/nginx-quic
  cd /tmp/nginx-quic
  PWD=$(pwd)

  # 确保 lua-nginx-module/NDK 子模块可用并切到兼容版本
  if [[ -d lua-nginx-module/.git ]]; then
    (cd lua-nginx-module && git fetch --tags && git checkout v0.10.28)
  fi
  if [[ -d ngx_devel_kit/.git ]]; then
    # 切到官方远端以获得 tags（如必要）
    (cd ngx_devel_kit && git remote set-url origin https://github.com/vision5/ngx_devel_kit.git || true
      git fetch --tags || true
      git checkout v0.3.4 || git checkout 0.3.4 || true)
  fi

  CONFIGURE_OPTS="
--user=www --group=www --prefix=/usr/local/nginx
--with-compat --with-file-aio --with-threads
--with-http_addition_module --with-debug --with-http_auth_request_module
--with-http_dav_module --with-http_flv_module --with-http_gunzip_module
--with-http_mp4_module --with-http_random_index_module --with-http_realip_module
--with-http_secure_link_module --with-http_slice_module --with-http_stub_status_module
--with-http_ssl_module --with-http_v2_module --with-http_gzip_static_module
--with-mail --with-mail_ssl_module --with-http_sub_module
--with-stream_realip_module --with-stream --with-stream_ssl_module
--with-stream_ssl_preread_module
--with-http_xslt_module=dynamic --with-http_image_filter_module=dynamic
--with-http_geoip_module=dynamic --with-stream_geoip_module=dynamic
--with-http_v3_module
--with-ld-opt='-L$PWD/build/ssl -L$PWD/build/crypto'
--with-openssl=$PWD/openssl
--with-openssl-opt=enable-weak-ssl-ciphers
--add-module=$PWD/headers-more-nginx-module-0.33
--add-module=$PWD/ngx_http_substitutions_filter_module
--add-module=$PWD/base64-nginx-module
--add-module=$PWD/ngx_brotli
--with-openssl-opt='enable-tls1_3 enable-ec_nistp_64_gcc_128'
--with-cc-opt='-g0 -O2 -fstack-protector-strong -Wformat -Werror=format-security -fPIC -Wdate-time -march=native -pipe -flto -funsafe-math-optimizations -D_FORTIFY_SOURCE=2 -DTCP_FASTOPEN=23 -I$PWD/.openssl/include/'
--add-module=$PWD/ngx_http_geoip2_module
--with-cc-opt='-I$PWD/include'
--add-module=$PWD/ngx_cache_purge
--add-module=$PWD/ngx_devel_kit
--add-module=$PWD/lua-nginx-module
"

  if [[ "$WITH_MODSECURITY" == "on" ]]; then
    echo "启用 ModSecurity 模块编译"
    CONFIGURE_OPTS+=" --add-module=$PWD/ModSecurity-nginx"
  else
    echo "不启用 ModSecurity 模块（--with-modsecurity=on 可启用）"
  fi

  echo "=== ./configure ==="
  eval ./configure $CONFIGURE_OPTS
  make -j"$(nproc)"
  make install

  # 默认 nginx.conf（含 resty 搜索路径/worker 用户/日志/默认站点）
  if [[ ! -f /usr/local/nginx/conf/nginx.conf ]]; then
cat >/usr/local/nginx/conf/nginx.conf <<'EOF'
user  www www;
worker_processes  auto;

# 关键：Lua 搜索路径固定到标准 share 目录（避免撞其它路径）
lua_package_path  '/usr/local/share/lua/5.1/?.lua;/usr/local/share/lua/5.1/?/init.lua;./?.lua;;';
lua_package_cpath '/usr/local/lib/lua/5.1/?.so;./?.so;;';

pid        logs/nginx.pid;
error_log  /home/wwwlogs/nginx_error.log warn;

events {
    worker_connections  1024;
}

http {
    lua_load_resty_core on;

    include       mime.types;
    default_type  application/octet-stream;

    log_format  main  '$remote_addr - $remote_user [$time_local] "$request" '
                      '$status $body_bytes_sent "$http_referer" '
                      '"$http_user_agent" "$http_x_forwarded_for"';
    access_log  /home/wwwlogs/nginx_access.log  main;

    sendfile        on;
    keepalive_timeout  65;

    server {
        listen       80;
        server_name  _;

        root   /home/wwwroot/default;
        index  index.html index.htm;

        location / {
            try_files $uri $uri/ =404;
        }
    }
}
EOF
  fi

  # 默认测试页
  if [[ ! -f /home/wwwroot/default/index.html ]]; then
    echo "<h1>NGINX 安装成功</h1>" > /home/wwwroot/default/index.html
    chown www:www /home/wwwroot/default/index.html
  fi

  # systemd（注意：不要在 unit 里设置 User=www，以 root 绑定 80 端口更稳）
cat >/etc/systemd/system/nginx.service <<'EOF'
[Unit]
Description=The NGINX HTTP and reverse proxy server
After=network.target

[Service]
Type=forking
PIDFile=/usr/local/nginx/logs/nginx.pid
ExecStartPre=/usr/local/nginx/sbin/nginx -t -q -g 'daemon on; master_process on;'
ExecStart=/usr/local/nginx/sbin/nginx -g 'daemon on; master_process on;'
ExecReload=/usr/local/nginx/sbin/nginx -g 'daemon on; master_process on;' -s reload
ExecStop=/usr/local/nginx/sbin/nginx -s quit
PrivateTmp=true
LimitNOFILE=1048576

[Install]
WantedBy=multi-user.target
EOF

  systemctl daemon-reload
  systemctl enable nginx
  /usr/local/nginx/sbin/nginx -t
  systemctl restart nginx
  echo "✅ Nginx 部署完成。根目录 /home/wwwroot/default ，日志 /home/wwwlogs"
}

# =========================================================
# 函数：安装/升级 MySQL 或 MariaDB（源码）
# =========================================================
install_or_upgrade_db() {
  local type_lc version prefix datadir rootpass upgrade
  type_lc=$(echo "$DB_TYPE" | tr '[:upper:]' '[:lower:]')
  version="$DB_VERSION"
  prefix="$DB_PREFIX"
  datadir="$DB_DATADIR"
  rootpass="$DB_ROOT_PASS"
  upgrade="$DB_UPGRADE"

  if [[ -z "$type_lc" || -z "$version" ]]; then
    echo "数据库安装需要 --type= 和 --version="; exit 1
  fi
  if [[ "$upgrade" -eq 0 && -z "$rootpass" ]]; then
    echo "全新安装需要 --root-pass="; exit 1
  fi
  if [[ "$type_lc" != "mysql" && "$type_lc" != "mariadb" ]]; then
    echo "--type 只能为 mysql 或 mariadb"; exit 1
  fi

  echo "=== 安装依赖（DB）==="
  apt-get install -y build-essential cmake bison pkg-config \
    libncurses5-dev libreadline-dev libssl-dev zlib1g-dev libaio-dev \
    libtirpc-dev rpcsvc-proto libudev-dev libevent-dev \
    libzstd-dev liblz4-dev

  # 用户/目录
  if ! id mysql >/dev/null 2>&1; then
    groupadd -r mysql
    useradd -r -g mysql -s /usr/sbin/nologin mysql || useradd -r -g mysql -s /sbin/nologin mysql
  fi
  mkdir -p "$prefix" "$datadir" /usr/local/src
  chown -R mysql:mysql "$datadir"

  cd /usr/local/src
  local tarball url srcdir
  if [[ "$type_lc" == "mysql" ]]; then
    local mm; mm=$(echo "$version" | awk -F. '{print $1"."$2}')
    tarball="mysql-$version.tar.gz"
    url="https://dev.mysql.com/get/Downloads/MySQL-$mm/$tarball"
    rm -rf "mysql-$version"
    echo "下载: $url"
    curl -fL "$url" -o "$tarball"
    tar xzf "$tarball"
    srcdir="mysql-$version"
  else
    tarball="mariadb-$version.tar.gz"
    url="https://archive.mariadb.org/mariadb-$version/source/$tarball"
    rm -rf "mariadb-$version"
    echo "下载: $url"
    curl -fL "$url" -o "$tarball"
    tar xzf "$tarball"
    srcdir="mariadb-$version"
  fi
  cd "$srcdir"

  local service="${type_lc}.service"
  if [[ "$upgrade" -eq 1 ]]; then
    if [[ -x "$prefix/bin/mysqld" ]]; then
      systemctl stop "$service" || true
      local backup="${prefix}.old-$(date +%Y%m%d%H%M)"
      mv "$prefix" "$backup"
      mkdir -p "$prefix"
      echo "备份原安装到 $backup"
    else
      echo "未检测到 $prefix/bin/mysqld，无法升级"; exit 1
    fi
  fi

  # 编译
  rm -rf build && mkdir build && cd build
  if [[ "$type_lc" == "mysql" ]]; then
    cmake .. \
      -DCMAKE_INSTALL_PREFIX="$prefix" \
      -DMYSQL_DATADIR="$datadir" \
      -DSYSCONFDIR=/etc \
      -DDEFAULT_CHARSET=utf8mb4 \
      -DDEFAULT_COLLATION=utf8mb4_0900_ai_ci \
      -DWITH_SSL=system \
      -DWITH_ZLIB=system \
      -DWITH_BOOST="$PWD/boost" \
      -DDOWNLOAD_BOOST=1
  else
    cmake .. \
      -DCMAKE_INSTALL_PREFIX="$prefix" \
      -DMYSQL_DATADIR="$datadir" \
      -DSYSCONFDIR=/etc \
      -DDEFAULT_CHARSET=utf8mb4 \
      -DDEFAULT_COLLATION=utf8mb4_unicode_ci
  fi
  make -j"$(nproc)"
  make install

  # my.cnf（全新安装或首次创建）
  if [[ ! -f /etc/my.cnf || "$upgrade" -eq 0 ]]; then
cat >/etc/my.cnf <<EOF
[client]
port = 3306
socket = $datadir/mysql.sock

[mysqld]
user = mysql
basedir = $prefix
datadir = $datadir
port = 3306
socket = $datadir/mysql.sock
pid-file = $datadir/mysqld.pid
log-error = /home/wwwlogs/${type_lc}.err
bind-address = 0.0.0.0

character-set-server = utf8mb4
collation-server     = utf8mb4_unicode_ci
skip_name_resolve = 1

innodb_buffer_pool_size = 256M
innodb_log_file_size    = 256M
innodb_flush_method     = O_DIRECT
max_connections         = 200

[mysql]
default-character-set = utf8mb4
EOF
  fi
  touch "/home/wwwlogs/${type_lc}.err"
  chown -R mysql:mysql /home/wwwlogs

  # 初始化（全新安装）
  if [[ "$upgrade" -eq 0 ]]; then
    if [[ "$type_lc" == "mysql" ]]; then
      "$prefix/bin/mysqld" --initialize-insecure --basedir="$prefix" --datadir="$datadir" --user=mysql
    else
      if [[ -x "$prefix/scripts/mysql_install_db" ]]; then
        "$prefix/scripts/mysql_install_db" --basedir="$prefix" --datadir="$datadir" --user=mysql
      elif [[ -x "$prefix/bin/mariadb-install-db" ]]; then
        "$prefix/bin/mariadb-install-db" --basedir="$prefix" --datadir="$datadir" --user=mysql
      else
        echo "未找到 MariaDB 初始化脚本"; exit 1
      fi
    fi
  fi
  chown -R mysql:mysql "$datadir"

  # systemd 单元
cat >/etc/systemd/system/${service} <<EOF
[Unit]
Description=${type_lc^^} Database Server
After=network.target

[Service]
Type=simple
User=mysql
Group=mysql
ExecStart=$prefix/bin/mysqld --defaults-file=/etc/my.cnf
LimitNOFILE=1048576
Restart=on-failure
RestartSec=5s

[Install]
WantedBy=multi-user.target
EOF

  systemctl daemon-reload
  systemctl enable "${service}"
  systemctl start "${service}"

  # 等待 ready
  for i in {1..40}; do
    if "$prefix/bin/mysqladmin" --protocol=socket --socket="$datadir/mysql.sock" ping &>/dev/null; then
      break
    fi
    sleep 1
  done

  # 设置密码 / 升级表结构
  if [[ "$upgrade" -eq 0 ]]; then
    "$prefix/bin/mysql" --protocol=socket --socket="$datadir/mysql.sock" -uroot <<SQL
ALTER USER 'root'@'localhost' IDENTIFIED BY '${DB_ROOT_PASS}';
FLUSH PRIVILEGES;
SQL
    echo "✅ 全新安装完成：$type_lc $version"
  else
    if [[ "$type_lc" == "mysql" ]]; then
      "$prefix/bin/mysql_upgrade" -uroot -p"${DB_ROOT_PASS}"
    else
      "$prefix/bin/mariadb-upgrade" -uroot -p"${DB_ROOT_PASS}"
    fi
    echo "✅ 升级完成：$type_lc $version"
  fi

  echo "安装目录: $prefix"
  echo "数据目录: $datadir"
  echo "日志: /home/wwwlogs/${type_lc}.err"
  echo "服务: ${service}  （systemctl status|restart ${service}）"
}

# ---------- 执行 ----------
[[ $NGINX_FLAG -eq 1 ]] && install_nginx
[[ $DB_FLAG -eq 1 ]] && install_or_upgrade_db

echo "🎉 All done."

