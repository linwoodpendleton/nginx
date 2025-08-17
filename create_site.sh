#!/usr/bin/env bash
set -euo pipefail

############################ 环境变量（最小系统兜底） ############################
export LANG=C
export LC_ALL=C
export PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin:/usr/local/nginx/sbin:/usr/local/mysql/bin:$HOME/.acme.sh:$PATH"
umask 027

############################ 可根据环境调整的默认路径 ############################
NGINX_PREFIX_DEFAULT="/usr/local/nginx"
VHOST_DIR_DEFAULT="$NGINX_PREFIX_DEFAULT/conf/vhost"
SSL_DIR_DEFAULT="$NGINX_PREFIX_DEFAULT/conf/ssl"
REWRITE_DIR_DEFAULT="$NGINX_PREFIX_DEFAULT/conf/rewrite"
PHP_INCLUDE_DEFAULT="$NGINX_PREFIX_DEFAULT/conf/enable-php8.3-pathinfo.conf"
LOG_DIR_BASE="/home/wwwlogs"

############################ 参数解析 ############################
usage() {
  cat <<'EOF'
用法：
  create_site.sh -M <mode> [站点参数] [数据库参数] [CA参数]

模式 (-M)：
  all        默认。建站(含可选SSL) +（可选）建库（需 -b yes）
  site-only  只建站（忽略数据库相关参数）
  db-only    只建库（无需域名/网站目录，忽略站点/证书参数）

站点参数（仅在 -M all 或 -M site-only 时需要）：
  -d  主域名，例如 example.com
  -r  网站根目录，例如 /home/wwwroot/example 或 /home/wwwroot/example/public
  -s  是否申请/安装SSL证书（acme.sh，webroot），默认 no
  -c  CA：letsencrypt | zerossl | buypass（默认 letsencrypt）
  -e  CA 账户邮箱（ZeroSSL 必需；LE 可选）

数据库参数：
  -b  是否创建数据库与账号（仅 -M all 使用；-M db-only 忽略此开关并强制建库）
  -n  数据库名（-M db-only 必填；-M all 且 -b yes 未填则用域名把 . 换 _）
  -p  数据库root密码（建库时必填）
  -u  待创建数据库用户名（建库时必填）
  -w  待创建数据库用户密码（建库时必填）

示例：
  # 只建库
  ./create_site.sh -M db-only -n appdb -p 'RootPass!' -u app -w 'AppPass!'
  # 只建站 + HTTPS
  ./create_site.sh -M site-only -d example.com -r /home/wwwroot/example -s yes
  # 建站 + 建库
  ./create_site.sh -M all -d example.com -r /home/wwwroot/example -s yes -b yes -n appdb -p 'RootPass!' -u app -w 'AppPass!'
EOF
  exit 1
}

MODE="all"
DOMAIN=""; WEBROOT=""; ENABLE_SSL="no"
CA_SERVER="letsencrypt"; ACCOUNT_EMAIL=""
CREATE_DB="no"; DB_NAME=""; DB_ROOT_PASS=""; DB_USER=""; DB_PASS=""

while getopts ":M:d:r:s:c:e:b:n:p:u:w:" opt; do
  case "$opt" in
    M) MODE="$OPTARG" ;;
    d) DOMAIN="$OPTARG" ;;
    r) WEBROOT="$OPTARG" ;;
    s) ENABLE_SSL="$OPTARG" ;;
    c) CA_SERVER="$OPTARG" ;;
    e) ACCOUNT_EMAIL="$OPTARG" ;;
    b) CREATE_DB="$OPTARG" ;;
    n) DB_NAME="$OPTARG" ;;
    p) DB_ROOT_PASS="$OPTARG" ;;
    u) DB_USER="$OPTARG" ;;
    w) DB_PASS="$OPTARG" ;;
    *) usage ;;
  esac
done

case "$MODE" in all|site-only|db-only) ;; *) echo "[-] 无效 -M：$MODE（all|site-only|db-only）"; exit 1;; esac

if [[ "$MODE" != "db-only" ]]; then
  [[ -z "$DOMAIN" || -z "$WEBROOT" ]] && { echo "[-] -M $MODE 需要 -d <域名> 与 -r <网站目录>"; exit 1; }
fi
if [[ "$MODE" == "db-only" ]]; then
  CREATE_DB="yes"
elif [[ "$MODE" == "site-only" ]]; then
  CREATE_DB="no"
fi

############################ 公共函数 ############################
detect_nginx_bin() {
  local b=""
  if command -v nginx >/dev/null 2>&1; then
    b="$(command -v nginx)"
  else
    for cand in /usr/local/nginx/sbin/nginx /usr/sbin/nginx /usr/bin/nginx; do
      [[ -x "$cand" ]] && { b="$cand"; break; }
    done
  fi
  [[ -z "$b" ]] && { echo "[!] 未找到 nginx 可执行文件"; exit 1; }
  echo "$b"
}

# 修复版：分行赋值 + 参数默认值，避免 set -u 触发 unbound
detect_nginx_user() {
  local prefix="${1:-}"
  local conf=""
  local u=""

  if [[ -n "$prefix" && -f "$prefix/conf/nginx.conf" ]]; then
    conf="$prefix/conf/nginx.conf"
  elif [[ -f "/etc/nginx/nginx.conf" ]]; then
    conf="/etc/nginx/nginx.conf"
  elif [[ -f "$NGINX_PREFIX_DEFAULT/conf/nginx.conf" ]]; then
    conf="$NGINX_PREFIX_DEFAULT/conf/nginx.conf"
  fi

  if [[ -n "$conf" && -f "$conf" ]]; then
    u="$(awk '/^\s*user\s+/{gsub(/;/,""); print $2; exit}' "$conf" 2>/dev/null || true)"
  fi

  if [[ -n "$u" ]] && id -u "$u" >/dev/null 2>&1; then
    echo "$u"
  else
    for cand in www www-data nginx nobody; do
      if id -u "$cand" >/dev/null 2>&1; then echo "$cand"; return; fi
    done
    echo "www"
  fi
}

# 更强的权限兜底：父目录755、挑战目录755、属主给nginx用户
ensure_acme_perms() {
  local webroot="$1" user="$2"

  # 父目录可穿透
  chmod 755 "$webroot" 2>/dev/null || true

  # 创建并修正挑战目录
  if command -v install >/dev/null 2>&1; then
    install -d -m 755 "$webroot/.well-known/acme-challenge"
  else
    mkdir -p "$webroot/.well-known/acme-challenge"
    chmod 755 "$webroot/.well-known" "$webroot/.well-known/acme-challenge" || true
  fi

  # 让 nginx 用户能读
  chown -R "$user":"$user" "$webroot/.well-known" 2>/dev/null || chown -R "$user" "$webroot/.well-known" || true
  chmod -R a+rX "$webroot/.well-known" || true

  # SELinux（CentOS等）
  if command -v getenforce >/dev/null 2>&1 && command -v chcon >/dev/null 2>&1; then
    if getenforce | grep -qi enforcing; then
      chcon -Rt httpd_sys_content_t "$webroot/.well-known" || true
    fi
  fi
}

create_db_and_user() {
  local _DB_NAME="$1" _DB_ROOT_PASS="$2" _DB_USER="$3" _DB_PASS="$4"
  echo "[*] 创建数据库与授权用户..."
  local MYSQL_BIN="mysql"
  if ! command -v "$MYSQL_BIN" >/dev/null 2>&1; then
    for cand in /usr/local/mysql/bin/mysql /usr/bin/mysql /usr/local/bin/mysql /opt/mysql*/bin/mysql; do
      [[ -x "$cand" ]] && { MYSQL_BIN="$cand"; break; }
    done
  else
    MYSQL_BIN="$(command -v mysql)"
  fi
  [[ -z "$MYSQL_BIN" || ! -x "$MYSQL_BIN" ]] && { echo "[!] 找不到 mysql 客户端"; exit 1; }

  local MYSQL_SOCK=""
  for s in /tmp/mysql.sock /var/lib/mysql/mysql.sock /usr/local/mysql/mysql.sock; do
    [[ -S "$s" ]] && { MYSQL_SOCK="$s"; break; }
  done

  export MYSQL_PWD="$_DB_ROOT_PASS"
  local MYSQL_BASE
  if [[ -n "$MYSQL_SOCK" ]]; then
    MYSQL_BASE=("$MYSQL_BIN" -uroot -S "$MYSQL_SOCK")
  else
    MYSQL_BASE=("$MYSQL_BIN" -uroot -h 127.0.0.1)
  fi

  "${MYSQL_BASE[@]}" -e "CREATE DATABASE IF NOT EXISTS ${_DB_NAME} DEFAULT CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;"
  "${MYSQL_BASE[@]}" -e "CREATE USER IF NOT EXISTS '${_DB_USER}'@'localhost' IDENTIFIED BY '${_DB_PASS}';"
  "${MYSQL_BASE[@]}" -e "CREATE USER IF NOT EXISTS '${_DB_USER}'@'%' IDENTIFIED BY '${_DB_PASS}';"
  "${MYSQL_BASE[@]}" -e "GRANT ALL PRIVILEGES ON ${_DB_NAME}.* TO '${_DB_USER}'@'localhost';"
  "${MYSQL_BASE[@]}" -e "GRANT ALL PRIVILEGES ON ${_DB_NAME}.* TO '${_DB_USER}'@'%';"
  "${MYSQL_BASE[@]}" -e "FLUSH PRIVILEGES;"
  unset MYSQL_PWD
  echo "[+] 数据库创建完成：DB=${_DB_NAME} 用户=${_DB_USER}"
}

############################ db-only：只建库并退出 ############################
if [[ "$MODE" == "db-only" ]]; then
  [[ -z "${DB_NAME:-}" ]] && { echo "[-] -M db-only 模式下 -n <数据库名> 必填"; exit 1; }
  [[ -z "${DB_ROOT_PASS:-}" || -z "${DB_USER:-}" || -z "${DB_PASS:-}" ]] && { echo "[-] 建库需要 -p -u -w"; exit 1; }
  [[ "$DB_NAME" =~ ^[A-Za-z0-9_]+$ ]] || { echo "[-] 非法数据库名：$DB_NAME"; exit 1; }
  [[ "$DB_USER" =~ ^[A-Za-z0-9_]+$ ]] || { echo "[-] 非法数据库用户：$DB_USER"; exit 1; }
  create_db_and_user "$DB_NAME" "$DB_ROOT_PASS" "$DB_USER" "$DB_PASS"
  echo; echo "================= 完成（db-only）================="; echo "数据库：$DB_NAME 已授权 $DB_USER@localhost 与 $DB_USER@%"; echo "========================================"; exit 0
fi

############################ 建站准备（all/site-only） ############################
# 自动发现 nginx 路径
NGINX_BIN="$(detect_nginx_bin)"
NGINX_PREFIX="$(dirname "$(dirname "$NGINX_BIN")")"
[[ -d "$NGINX_PREFIX/conf" ]] || NGINX_PREFIX="$NGINX_PREFIX_DEFAULT"
VHOST_DIR="$NGINX_PREFIX/conf/vhost"; [[ -d "$VHOST_DIR" ]] || VHOST_DIR="$VHOST_DIR_DEFAULT"
SSL_DIR="$NGINX_PREFIX/conf/ssl";   [[ -d "$SSL_DIR"  ]] || SSL_DIR="$SSL_DIR_DEFAULT"
REWRITE_DIR="$NGINX_PREFIX/conf/rewrite"; [[ -d "$REWRITE_DIR" ]] || REWRITE_DIR="$REWRITE_DIR_DEFAULT"
PHP_INCLUDE="$PHP_INCLUDE_DEFAULT"; [[ -f "$PHP_INCLUDE" ]] || PHP_INCLUDE="$PHP_INCLUDE_DEFAULT"

VHOST_FILE="$VHOST_DIR/${DOMAIN}.conf"
SITE_SSL_DIR="$SSL_DIR/$DOMAIN"
SITE_LOG="$LOG_DIR_BASE/${DOMAIN}.log"

# 站点根：以 /public 结尾则取上一级，否则即 WEBROOT
if [[ "$WEBROOT" == */public ]]; then SITE_ROOT="${WEBROOT%/public}"; else SITE_ROOT="$WEBROOT"; fi

# 用 755 创建目录，避免 umask 027 造成父目录不可穿透
if command -v install >/dev/null 2>&1; then
  install -d -m 755 "$VHOST_DIR" "$REWRITE_DIR" "$LOG_DIR_BASE" "$SITE_SSL_DIR"
  install -d -m 755 "$WEBROOT" "$SITE_ROOT/tmp" "$SITE_ROOT/logs" "$SITE_ROOT/uploads" "$WEBROOT/.well-known/acme-challenge"
else
  mkdir -p "$VHOST_DIR" "$REWRITE_DIR" "$LOG_DIR_BASE" "$SITE_SSL_DIR"
  mkdir -p "$WEBROOT" "$SITE_ROOT/tmp" "$SITE_ROOT/logs" "$SITE_ROOT/uploads" "$WEBROOT/.well-known/acme-challenge"
  chmod 755 "$WEBROOT" "$SITE_ROOT/tmp" "$SITE_ROOT/logs" "$SITE_ROOT/uploads" "$WEBROOT/.well-known" "$WEBROOT/.well-known/acme-challenge" || true
fi
echo "[*] 准备目录..."
chmod 1733 "$SITE_ROOT/tmp" || true

# 首页（若无）
if [[ ! -f "$WEBROOT/index.php" && ! -f "$WEBROOT/index.html" ]]; then cat > "$WEBROOT/index.php" <<'PHP'
<?php
phpinfo();
PHP
fi

# .user.ini 防跨目录
echo "[*] 写入 .user.ini（限制 open_basedir，防跨目录）..."
cat > "$SITE_ROOT/.user.ini" <<EOF
open_basedir=$SITE_ROOT/:/tmp/:/proc/
session.save_path=$SITE_ROOT/tmp
EOF
chmod 0640 "$SITE_ROOT/.user.ini" || true

# rewrite 占位
[[ -f "$REWRITE_DIR/$DOMAIN.conf" ]] || echo -e "# rewrite rules for $DOMAIN\n" > "$REWRITE_DIR/$DOMAIN.conf"

# dhparam（可选）
SSL_DHPARAM_FILE="$SSL_DIR/dhparam.pem"; SSL_DHPARAM_DIRECTIVE=""
if [[ ! -f "$SSL_DHPARAM_FILE" ]]; then
  if command -v openssl >/dev/null 2>&1; then echo "[*] 生成 dhparam（可能较慢）..."; openssl dhparam -out "$SSL_DHPARAM_FILE" 2048; else echo "[!] 未检测到 openssl，跳过 dhparam"; fi
fi
[[ -f "$SSL_DHPARAM_FILE" ]] && SSL_DHPARAM_DIRECTIVE="        ssl_dhparam $SSL_DHPARAM_FILE;"

############################ Nginx 配置模板（alias 放行 ACME） ############################
write_http_only_conf() {
  cat > "$VHOST_FILE" <<EOF
server
    {
        listen 80;
        server_name $DOMAIN;
        root  $WEBROOT;
        index index.html index.htm index.php default.html default.htm default.php;

        include $REWRITE_DIR/$DOMAIN.conf;
        include $PHP_INCLUDE;

        # 先放行 http-01（alias 直指真实目录，最稳）
        location ^~ /.well-known/acme-challenge/ {
            alias $WEBROOT/.well-known/acme-challenge/;
            default_type "text/plain";
            allow all;
            try_files \$uri =404;
        }

        # 显式禁止敏感文件
        location = /.user.ini { deny all; }
        location ~ /\. { deny all; }

        # 静态缓存
        location ~ .*\\.(gif|jpg|jpeg|png|bmp|swf)$ { expires 30d; }
        location ~ .*\\.(js|css)?$ { expires 12h; }

        access_log  $SITE_LOG;
    }
EOF
}
write_https_redirect_conf() {
  cat > "$VHOST_FILE" <<EOF
server
    {
        listen 80;
        server_name $DOMAIN;
        root  $WEBROOT;
        index index.html index.htm index.php default.html default.htm default.php;

        # ACME 续期放行
        location ^~ /.well-known/acme-challenge/ {
            alias $WEBROOT/.well-known/acme-challenge/;
            default_type "text/plain";
            allow all;
            try_files \$uri =404;
        }

        location = /.user.ini { deny all; }
        location ~ /\. { deny all; }

        location ~ .*\\.(gif|jpg|jpeg|png|bmp|swf)$ { expires 30d; }
        location ~ .*\\.(js|css)?$ { expires 12h; }

        # 其余跳 https
        location / { return 301 https://\$host\$request_uri; }

        access_log  $SITE_LOG;
    }

server
    {
        listen 443 ssl;
        http2 on;
        server_name $DOMAIN;
        root  $WEBROOT;
        index index.html index.htm index.php default.html default.htm default.php;

        ssl_certificate     $SITE_SSL_DIR/$DOMAIN.crt;
        ssl_certificate_key $SITE_SSL_DIR/$DOMAIN.key;
        ssl_session_timeout 5m;
        ssl_protocols TLSv1.2 TLSv1.3;
        ssl_prefer_server_ciphers on;
        ssl_ciphers "TLS13-AES-256-GCM-SHA384:TLS13-CHACHA20-POLY1305-SHA256:TLS13-AES-128-GCM-SHA256:EECDH+AES128:EECDH+AES256:!MD5";
$SSL_DHPARAM_DIRECTIVE
        ssl_session_cache builtin:1000 shared:SSL:10m;

        include $REWRITE_DIR/$DOMAIN.conf;
        include $PHP_INCLUDE;

        location = /.user.ini { deny all; }
        location ~ /\. { deny all; }

        location ~ .*\\.(gif|jpg|jpeg|png|bmp|swf)$ { expires 30d; }
        location ~ .*\\.(js|css)?$ { expires 12h; }

        access_log  $SITE_LOG;
    }
EOF
}
nginx_test_and_reload() { echo "[*] 测试 Nginx 配置..."; "$NGINX_BIN" -t; echo "[*] 重载 Nginx ..."; "$NGINX_BIN" -s reload || "$NGINX_BIN"; }

############################ SSL（单域名，webroot） ############################
if [[ "$ENABLE_SSL" == "yes" ]]; then
  # 自动安装 acme.sh（curl/wget 二选一）
  if ! command -v acme.sh >/dev/null 2>&1; then
    echo "[*] acme.sh 未安装，自动安装..."
    if command -v curl >/dev/null 2>&1; then curl https://get.acme.sh | sh
    elif command -v wget >/dev/null 2>&1; then wget -O - https://get.acme.sh | sh
    else echo "[!] 需要 curl 或 wget 以安装 acme.sh"; exit 1; fi
  fi
  [[ -f "$HOME/.acme.sh/acme.sh" ]] && export PATH="$HOME/.acme.sh":$PATH || true
  command -v acme.sh >/dev/null 2>&1 || { echo "[!] acme.sh 不可用"; exit 1; }

  # 设置 CA & 按需注册
  case "$CA_SERVER" in letsencrypt|zerossl|buypass) ;; *) echo "[-] 无效 CA：$CA_SERVER"; exit 1;; esac
  acme.sh --set-default-ca --server "$CA_SERVER"
  if [[ "$CA_SERVER" == "zerossl" ]]; then [[ -z "$ACCOUNT_EMAIL" ]] && ACCOUNT_EMAIL="admin@$DOMAIN"; acme.sh --register-account -m "$ACCOUNT_EMAIL" || true
  else [[ -n "$ACCOUNT_EMAIL" ]] && acme.sh --register-account -m "$ACCOUNT_EMAIL" || true; fi

  # 权限兜底（挑战目录必须 web 用户可读）
  NGINX_USER="$(detect_nginx_user "$NGINX_PREFIX")"
  ensure_acme_perms "$WEBROOT" "$NGINX_USER"

  # 写入临时 80 配置并 reload
  echo "[*] 写入临时 80 端口配置以供 ACME 验证..."
  write_http_only_conf
  nginx_test_and_reload

  # 签发并安装
  echo "[*] 申请/安装 SSL 证书（webroot 模式，CA=$CA_SERVER）..."
  acme.sh --issue -d "$DOMAIN" -w "$WEBROOT" --force || { echo "[!] 签发失败，请检查 DNS/80端口/权限"; exit 1; }
  acme.sh --install-cert -d "$DOMAIN" \
    --key-file       "$SITE_SSL_DIR/$DOMAIN.key" \
    --fullchain-file "$SITE_SSL_DIR/$DOMAIN.crt" \
    --reloadcmd      "$NGINX_BIN -s reload" --force

  # 最终 https 配置（80->443）
  echo "[*] 写入最终 HTTPS 配置..."
  write_https_redirect_conf
  nginx_test_and_reload
else
  echo "[*] 写入 HTTP 配置..."
  write_http_only_conf
  nginx_test_and_reload
fi

############################ all 模式可选建库 ############################
if [[ "$MODE" == "all" && "$CREATE_DB" == "yes" ]]; then
  [[ -z "${DB_NAME:-}" ]] && DB_NAME="${DOMAIN//./_}"
  [[ -z "${DB_ROOT_PASS:-}" || -z "${DB_USER:-}" || -z "${DB_PASS:-}" ]] && { echo "[-] 建库需要 -p -u -w"; exit 1; }
  [[ "$DB_NAME" =~ ^[A-Za-z0-9_]+$ ]] || { echo "[-] 非法数据库名：$DB_NAME"; exit 1; }
  [[ "$DB_USER" =~ ^[A-Za-z0-9_]+$ ]] || { echo "[-] 非法数据库用户：$DB_USER"; exit 1; }
  create_db_and_user "$DB_NAME" "$DB_ROOT_PASS" "$DB_USER" "$DB_PASS"
fi

############################ 完成输出 ############################
echo
echo "================= 完成 (${MODE}) ================="
echo "域名：     ${DOMAIN:-"(db-only 无)"}"
echo "站点根：   ${WEBROOT:-"(db-only 无)"}"
if [[ "$MODE" != "db-only" ]]; then
  echo "VHost：    $VHOST_FILE"
  echo "站点根附加：$SITE_ROOT/tmp、$SITE_ROOT/logs、$SITE_ROOT/uploads、$SITE_ROOT/.user.ini"
  if [[ "$ENABLE_SSL" == "yes" ]]; then
    echo "SSL目录：  $SITE_SSL_DIR"
    echo "证书：     已安装（CA=$CA_SERVER，webroot）"
  fi
  echo "访问日志： $SITE_LOG"
fi
if [[ "$MODE" == "db-only" || ("$MODE" == "all" && "$CREATE_DB" == "yes") ]]; then
  echo "数据库：   ${DB_NAME}（已授权 ${DB_USER}@localhost 与 ${DB_USER}@% ）"
fi
echo "========================================"

