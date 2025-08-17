#!/usr/bin/env bash
# build-php-unattended.sh
# 无人值守 | 多版本并存 | 单文件 php-fpm.conf（自动按 CPU/内存优化）| Unix Socket 对接 Nginx
# - 默认 socket: /tmp/php-cgi<主>.<次>.sock（SOCK_DIR=/run/php 可切换）
# - systemd: PrivateTmp=false + ExecStartPre 清理旧 socket + Restart=on-failure
# - 依赖自动安装；libcares/libzip 源码兜底
# - OpenSSL 3 + PHP 7.x 自动用 OpenSSL 1.1.1 (/opt/openssl11)
# - 扩展使用 PECL 源码 + phpize（不依赖 pecl 命令），成功才写 ini（禁用 swoole shortname）
# - Composer 全局 + 版本包装器；update-alternatives
# - 启动后自检 socket；检测 nginx PrivateTmp 提示

set -euo pipefail
umask 022
export PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"
export DEBIAN_FRONTEND=noninteractive
export LC_ALL=C
export LANG=C
export COMPOSER_ALLOW_SUPERUSER=1

PHP_VERSION="${1:-}"
if [[ -z "${PHP_VERSION}" ]]; then
  echo "用法: $0 <PHP_VERSION>   例如: $0 8.3.23 或 $0 7.4.33"
  exit 1
fi

MAJOR="${PHP_VERSION%%.*}"
_rest="${PHP_VERSION#*.}"; MINOR="${_rest%%.*}"

# 与 Nginx 约定路径：默认 /tmp；可通过 SOCK_DIR 覆盖为 /run/php
SOCK_DIR="${SOCK_DIR:-/tmp}"
SOCK_PATH="${SOCK_DIR}/php-cgi${MAJOR}.${MINOR}.sock"

PREFIX="/usr/local/php-${PHP_VERSION}"
SYMLINK="/usr/local/php"
SRC_DIR="/usr/local/src"
PHP_TARBALL="php-${PHP_VERSION}.tar.gz"
PHP_URL="https://www.php.net/distributions/${PHP_TARBALL}"

cmd_exists(){ command -v "$1" >/dev/null 2>&1; }

# 包管理器
PM=""
if   cmd_exists apt-get; then PM="apt"
elif cmd_exists dnf;     then PM="dnf"
elif cmd_exists yum;     then PM="yum"
else echo "未检测到 apt/dnf/yum；退出"; exit 1; fi

# www 用户
ensure_www_user(){
  getent group www >/dev/null 2>&1 || groupadd -r www
  id -u www >/dev/null 2>&1 || useradd -r -g www -s /usr/sbin/nologin -d /nonexistent www || useradd -r -g www -s /sbin/nologin -d /nonexistent www || true
}

# 依赖（含 c-ares/libzip 兜底）
install_deps(){
  mkdir -p "${SRC_DIR}"
  if [[ "$PM" == "apt" ]]; then
    apt-get update -y
    apt-get install -y \
      build-essential autoconf automake bison re2c pkg-config cmake git curl wget tar unzip ca-certificates \
      libxml2-dev libsqlite3-dev libssl-dev zlib1g-dev libcurl4-openssl-dev \
      libjpeg-dev libpng-dev libwebp-dev libfreetype6-dev libzip-dev \
      libonig-dev libreadline-dev libgmp-dev libxslt1-dev \
      libicu-dev uuid-dev libsodium-dev libtidy-dev libffi-dev \
      libargon2-dev libbz2-dev libldap2-dev libsasl2-dev libkrb5-dev \
      libpq-dev libevent-dev libc-ares-dev
  else
    $PM -y install epel-release || true
    $PM -y groupinstall "Development Tools" || true
    $PM -y install \
      autoconf automake bison re2c pkgconfig cmake git curl wget tar unzip ca-certificates \
      libxml2-devel sqlite-devel openssl-devel zlib-devel libcurl-devel \
      libjpeg-turbo-devel libpng-devel libwebp-devel freetype-devel libzip-devel \
      oniguruma-devel readline-devel gmp-devel libxslt-devel \
      libicu-devel libuuid-devel libsodium-devel libtidy-devel libffi-devel \
      libargon2-devel bzip2 bzip2-devel openldap-devel cyrus-sasl-devel krb5-devel \
      libpq-devel libevent-devel c-ares-devel || true
    # libzip 兜底
    if ! pkg-config --exists libzip; then
      cd "${SRC_DIR}"
      ver_zip="1.10.1"
      wget -qO "libzip-${ver_zip}.tar.gz" "https://libzip.org/download/libzip-${ver_zip}.tar.gz"
      tar xf "libzip-${ver_zip}.tar.gz" && cd "libzip-${ver_zip}"
      mkdir -p build && cd build && cmake .. >/dev/null && make -j"$(nproc)" >/dev/null && make install >/dev/null
      echo "/usr/local/lib" >/etc/ld.so.conf.d/libzip-local.conf; ldconfig
    fi
  fi
  # c-ares 兜底（Swoole cares 依赖）
  if ! pkg-config --exists libcares; then
    cd "${SRC_DIR}"
    rm -rf c-ares || true
    git clone --depth=1 https://github.com/c-ares/c-ares.git
    cd c-ares && mkdir -p build && cd build
    cmake -DCARES_STATIC=OFF -DCARES_SHARED=ON -DCMAKE_INSTALL_PREFIX=/usr/local ..
    make -j"$(nproc)" && make install
    echo "/usr/local/lib" >/etc/ld.so.conf.d/cares-local.conf
    ldconfig
  fi
}

# OpenSSL 3 上构建 PHP 7.x → 自动安装/使用 OpenSSL 1.1.1
install_openssl11_if_needed(){
  if (( MAJOR >= 8 )); then
    OPENSSL_OPT="--with-openssl"
    return
  fi
  local osv_major
  osv_major="$(openssl version 2>/dev/null | awk '{print $2}' | cut -d. -f1)"
  if [[ -z "${osv_major:-}" || "${osv_major}" -ge 3 ]]; then
    if [[ ! -x /opt/openssl11/bin/openssl ]]; then
      pushd "${SRC_DIR}" >/dev/null
      curl -fSLO https://www.openssl.org/source/openssl-1.1.1w.tar.gz
      tar xf openssl-1.1.1w.tar.gz
      pushd openssl-1.1.1w >/dev/null
      ./config --prefix=/opt/openssl11 --openssldir=/opt/openssl11 shared zlib
      make -j"$(nproc)" && make install
      popd >/dev/null
      echo "/opt/openssl11/lib" >/etc/ld.so.conf.d/openssl11.conf
      ldconfig
      popd >/dev/null
    fi
    export PKG_CONFIG_PATH="/opt/openssl11/lib/pkgconfig:${PKG_CONFIG_PATH:-}"
    export CPPFLAGS="-I/opt/openssl11/include ${CPPFLAGS:-}"
    export LDFLAGS="-L/opt/openssl11/lib ${LDFLAGS:-}"
    OPENSSL_OPT="--with-openssl=/opt/openssl11"
  else
    OPENSSL_OPT="--with-openssl"
  fi
}

# 按 CPU / 内存自动优化 php-fpm.conf
auto_optimize_fpm_conf(){
  local PHP_FPM_CONF="$1"

  local cpu_cores total_memory_mb
  cpu_cores="$(nproc --all)"
  total_memory_mb="$(free -m | awk '/^Mem:/ {print $2}')"
  (( cpu_cores > 0 )) || cpu_cores=1
  (( total_memory_mb > 0 )) || total_memory_mb=1024

  # 估算每个 FPM 子进程内存 50MB（按你的负载可调整）
  local by_cpu=$((cpu_cores * 5))
  local by_mem=$((total_memory_mb / 50))
  local pm_max_children=$(( by_cpu < by_mem ? by_cpu : by_mem ))

  # 安全边界：最少 5，最多 1024
  (( pm_max_children < 5 ))   && pm_max_children=5
  (( pm_max_children > 1024 ))&& pm_max_children=1024

  local pm_start_servers=$(( cpu_cores * 2 ))
  local pm_min_spare_servers=$(( cpu_cores * 1 ))
  local pm_max_spare_servers=$(( cpu_cores * 4 ))

  # 启动/空闲边界
  (( pm_start_servers < 2 )) && pm_start_servers=2
  (( pm_min_spare_servers < 1 )) && pm_min_spare_servers=1
  (( pm_max_spare_servers < pm_start_servers )) && pm_max_spare_servers=$((pm_start_servers+2))

  cat > "${PHP_FPM_CONF}" <<EOF
[global]
pid = ${PREFIX}/var/run/php-fpm.pid
error_log = ${PREFIX}/var/log/php-fpm.log
log_level = notice

[www]
listen = ${SOCK_PATH}
listen.backlog = -1
listen.allowed_clients = 127.0.0.1
listen.owner = www
listen.group = www
listen.mode = 0666

user = www
group = www

pm = dynamic
pm.max_children = ${pm_max_children}
pm.start_servers = ${pm_start_servers}
pm.min_spare_servers = ${pm_min_spare_servers}
pm.max_spare_servers = ${pm_max_spare_servers}

request_terminate_timeout = 100
request_slowlog_timeout = 0
slowlog = ${PREFIX}/var/log/slow.log
EOF
}

# 编译安装 PHP（写配置==>自动优化==>下发 systemd）
build_php(){
  install_openssl11_if_needed

  mkdir -p "${SRC_DIR}"
  pushd "${SRC_DIR}" >/dev/null
  [[ -f "${PHP_TARBALL}" ]] || wget -qO "${PHP_TARBALL}" "${PHP_URL}"
  rm -rf "php-${PHP_VERSION}" || true
  tar xf "${PHP_TARBALL}"
  cd "php-${PHP_VERSION}"

  CONFIG_OPTS=(
    "--prefix=${PREFIX}"
    "--with-config-file-path=${PREFIX}/lib"
    "--with-config-file-scan-dir=${PREFIX}/lib/conf.d"
    "--enable-fpm" "--with-fpm-user=www" "--with-fpm-group=www"
    "--enable-opcache" "--with-zlib" "--with-curl" "${OPENSSL_OPT}"
    "--enable-mbstring" "--enable-zip" "--with-readline" "--with-gettext"
    "--with-xsl" "--with-bz2" "--with-password-argon2"
    "--enable-exif" "--enable-ftp" "--enable-soap" "--enable-calendar"
    "--with-mysqli=mysqlnd" "--with-pdo-mysql=mysqlnd"
    "--with-pdo-sqlite" "--with-sqlite3"
    "--with-pgsql" "--with-pdo-pgsql"
    "--enable-intl" "--enable-bcmath" "--with-gmp"
    "--enable-pcntl" "--enable-sockets" "--enable-sysvshm" "--enable-sysvsem" "--enable-sysvmsg" "--enable-shmop"
    "--with-ldap" "--with-tidy"
    "--enable-gd" "--with-freetype" "--with-jpeg"
  )
  if (( MAJOR > 7 )) || (( MAJOR == 7 && MINOR >= 2 )); then
    CONFIG_OPTS+=("--with-webp" "--with-sodium")
  fi
  if (( MAJOR > 7 )) || (( MAJOR == 7 && MINOR >= 4 )); then
    CONFIG_OPTS+=("--with-ffi")
  fi

  ./configure "${CONFIG_OPTS[@]}"
  make -j"$(nproc)"
  make install

  # 目录与权限
  mkdir -p "${PREFIX}/lib/conf.d" "${PREFIX}/var/run" "${PREFIX}/var/log" "${SOCK_DIR}"
  touch "${PREFIX}/var/log/php-fpm.log" "${PREFIX}/var/log/slow.log"
  if [[ "${SOCK_DIR}" = "/tmp" ]]; then
    chmod 1777 /tmp
  else
    chown www:www "${SOCK_DIR}" 2>/dev/null || true
    chmod 0775 "${SOCK_DIR}" 2>/dev/null || true
  fi

  # php.ini + 安全项
  cp php.ini-production "${PREFIX}/lib/php.ini" 2>/dev/null || cp php.ini-development "${PREFIX}/lib/php.ini"
  awk '
  BEGIN {done=0}
  { if ($0 ~ /^[[:space:]]*short_open_tag[[:space:]]*=/) {$0="short_open_tag = Off"; done=1} print }
  END { if (!done) print "short_open_tag = Off";
        print "expose_php=Off"; print "opcache.enable=1"; print "opcache.enable_cli=1";
        print "date.timezone=UTC"; print "cgi.fix_pathinfo=0" }
  ' "${PREFIX}/lib/php.ini" > "${PREFIX}/lib/php.ini.tmp" && mv "${PREFIX}/lib/php.ini.tmp" "${PREFIX}/lib/php.ini"

  # 自动优化并生成 php-fpm.conf（单文件）
  auto_optimize_fpm_conf "${PREFIX}/etc/php-fpm.conf"

  # systemd：PrivateTmp=false；启动前清理旧 socket；自动重启
  cat >/etc/systemd/system/php-fpm-${PHP_VERSION}.service <<EOF
[Unit]
Description=PHP-FPM ${PHP_VERSION}
After=network.target

[Service]
Type=forking
PIDFile=${PREFIX}/var/run/php-fpm.pid
ExecStartPre=/bin/rm -f ${SOCK_PATH}
ExecStart=${PREFIX}/sbin/php-fpm --fpm-config ${PREFIX}/etc/php-fpm.conf
ExecReload=/bin/kill -USR2 \$MAINPID
ExecStop=/bin/kill -TERM \$MAINPID
PrivateTmp=false
Restart=on-failure
RestartSec=2s

[Install]
WantedBy=multi-user.target
EOF

  systemctl daemon-reload
  systemctl enable --now "php-fpm-${PHP_VERSION}.service"

  ln -sfn "${PREFIX}" "${SYMLINK}"
  popd >/dev/null
}

# 从 pecl.php.net 拉源码并用当前 PHP 的 phpize 构建（无需 pecl 命令）
install_from_pecl_tgz(){
  local pkg="$1"      # redis / protobuf / igbinary / msgpack / event / swoole
  local so="$2"       # redis.so / protobuf.so ...
  shift 2
  local extra_conf=( "$@" )

  local EXT_DIR="$("${PREFIX}/bin/php" -n -r 'echo ini_get("extension_dir");')"
  local tmpdir; tmpdir="$(mktemp -d)"
  pushd "$tmpdir" >/dev/null

  if ! curl -fsSL "https://pecl.php.net/get/${pkg}" -o "${pkg}.tgz"; then
    echo "[WARN] 获取 ${pkg} 源包失败"; popd >/dev/null; rm -rf "$tmpdir"; return 1
  fi
  tar xf "${pkg}.tgz"
  cd "${pkg}-"* || { echo "[WARN] ${pkg} 解包失败"; popd >/dev/null; rm -rf "$tmpdir"; return 1; }

  "${PREFIX}/bin/phpize"
  if ./configure "${extra_conf[@]}" && make -j"$(nproc)" && make install; then
    if [[ -f "${EXT_DIR}/${so}" ]]; then
      echo "extension=${so}" > "${PREFIX}/lib/conf.d/20-${pkg}.ini"
      [[ "${pkg}" == "swoole" ]] && echo "swoole.use_shortname=Off" >> "${PREFIX}/lib/conf.d/20-swoole.ini"
      echo "[OK] ${pkg} installed."
      popd >/dev/null; rm -rf "$tmpdir"; return 0
    else
      echo "[WARN] ${pkg} 已编译但未发现 ${so}，跳过写 ini"
    fi
  else
    echo "[WARN] ${pkg} 构建失败，跳过"
  fi
  popd >/dev/null
  rm -rf "$tmpdir"
  return 1
}

# Swoole：PHP 8.x 用 PECL 最新；PHP 7.x 锁 4.x（>=4.4）
install_swoole(){
  rm -f "${PREFIX}/lib/conf.d/"*swoole*.ini || true
  local cares_opt=()
  pkg-config --exists libcares && cares_opt+=(--enable-cares)

  if (( MAJOR >= 8 )); then
    install_from_pecl_tgz "swoole" "swoole.so" --enable-openssl --enable-http2 --enable-mysqlnd --enable-swoole-curl "${cares_opt[@]}" || true
    return 0
  fi

  local tmpdir; tmpdir="$(mktemp -d)"
  pushd "$tmpdir" >/dev/null
  git clone --depth=1 https://github.com/swoole/swoole-src.git
  cd swoole-src
  git fetch --tags --depth=1
  tag="$(git tag -l 'v4.*' | sort -V | tail -n1 || true)"
  [[ -n "${tag:-}" ]] && git checkout "$tag" || true

  "${PREFIX}/bin/phpize"
  if ./configure --enable-openssl --enable-http2 --enable-mysqlnd --enable-swoole-curl "${cares_opt[@]}" \
      && make -j"$(nproc)" && make install; then
    local EXT_DIR; EXT_DIR="$("${PREFIX}/bin/php" -n -r 'echo ini_get("extension_dir");')"
    if [[ -f "${EXT_DIR}/swoole.so" ]]; then
      cat > "${PREFIX}/lib/conf.d/20-swoole.ini" <<'EOF'
extension=swoole.so
swoole.use_shortname=Off
EOF
      echo "[OK] swoole installed (PHP 7.x, tag ${tag:-unknown})."
    else
      echo "[WARN] swoole 构建完成但未发现 swoole.so，跳过写 ini"
    fi
  else
    echo "[WARN] swoole 构建失败（PHP 7.x）"
  fi
  popd >/dev/null
  rm -rf "$tmpdir"
}

# 安装扩展
install_extensions(){
  export PATH="${PREFIX}/bin:${PATH}"
  # 若装了 /opt/openssl11（7.x 场景），补充扩展的编译搜索路径
  if [[ -d /opt/openssl11/lib/pkgconfig ]]; then
    export PKG_CONFIG_PATH="/opt/openssl11/lib/pkgconfig:${PKG_CONFIG_PATH:-}"
    export CPPFLAGS="-I/opt/openssl11/include ${CPPFLAGS:-}"
    export LDFLAGS="-L/opt/openssl11/lib ${LDFLAGS:-}"
  fi
  export PKG_CONFIG_PATH="/usr/local/lib/pkgconfig:/usr/lib/pkgconfig:/usr/local/lib64/pkgconfig:${PKG_CONFIG_PATH:-}"
  mkdir -p "${PREFIX}/lib/conf.d"

  install_from_pecl_tgz redis    redis.so    || true
  install_from_pecl_tgz protobuf protobuf.so || true
  install_from_pecl_tgz igbinary igbinary.so || true
  install_from_pecl_tgz msgpack  msgpack.so  || true
  install_from_pecl_tgz event    event.so    || true

  install_swoole || true

  systemctl restart "php-fpm-${PHP_VERSION}.service" || true
}

# Composer 安装
install_composer(){
  if ! command -v composer >/dev/null 2>&1; then
    mkdir -p "${SRC_DIR}"; cd "${SRC_DIR}"
    EXPECTED_SIG="$(wget -q -O - https://composer.github.io/installer.sig)"
    "${PREFIX}/bin/php" -r 'copy("https://getcomposer.org/installer","composer-setup.php");'
    "${PREFIX}/bin/php" -r "if (hash_file('sha384','composer-setup.php') !== '${EXPECTED_SIG}') { echo 'ERROR: Invalid installer signature'.PHP_EOL; unlink('composer-setup.php'); exit(1); }"
    "${PREFIX}/bin/php" composer-setup.php --install-dir=/usr/local/bin --filename=composer --quiet
    rm -f composer-setup.php
  fi
  cat >/usr/local/bin/composer${MAJOR}${MINOR} <<EOF
#!/usr/bin/env bash
exec ${PREFIX}/bin/php /usr/local/bin/composer "\$@"
EOF
  chmod +x /usr/local/bin/composer${MAJOR}${MINOR}
}

# 注册 CLI 版本切换
register_cli_switch(){
  if cmd_exists update-alternatives; then
    update-alternatives --install /usr/bin/php php ${PREFIX}/bin/php $((MAJOR*10+MINOR)) \
      --slave /usr/bin/phpize phpize ${PREFIX}/bin/phpize \
      --slave /usr/bin/php-config php-config ${PREFIX}/bin/php-config
    update-alternatives --set php ${PREFIX}/bin/php
  elif cmd_exists alternatives; then
    alternatives --install /usr/bin/php php ${PREFIX}/bin/php $((MAJOR*10+MINOR)) || true
    alternatives --set php ${PREFIX}/bin/php || true
  fi
  ln -sfn "${PREFIX}/bin/php"        "/usr/local/bin/php${MAJOR}${MINOR}"
  ln -sfn "${PREFIX}/bin/php-config" "/usr/local/bin/php-config${MAJOR}${MINOR}"
  ln -sfn "${PREFIX}/bin/phpize"     "/usr/local/bin/phpize${MAJOR}${MINOR}"
  ln -sfn "${PREFIX}" "${SYMLINK}"
}

verify_socket(){
  sleep 1
  if [[ ! -S "${SOCK_PATH}" ]]; then
    echo "[ERROR] 未发现 FPM socket: ${SOCK_PATH}"
    systemctl status php-fpm-${PHP_VERSION} --no-pager || true
    journalctl -u php-fpm-${PHP_VERSION} -b --no-pager | tail -n 120 || true
    exit 1
  fi
}

warn_if_nginx_privtmp(){
  if [[ "${SOCK_DIR}" = "/tmp" ]] && systemctl show -p PrivateTmp nginx 2>/dev/null | grep -q 'PrivateTmp=yes'; then
    cat <<MSG
----------------------------------------------------------------
[注意] 发现 nginx.service 的 PrivateTmp=true，而你使用的是 /tmp socket。
      Nginx 可能看不到 /tmp 中的 php-cgi*.sock，建议二选一：
      1) 关闭 Nginx PrivateTmp：
         sudo systemctl edit nginx
           [Service]
           PrivateTmp=false
         sudo systemctl daemon-reload && sudo systemctl restart nginx
      2) 改用 /run/php：
         SOCK_DIR=/run/php sudo bash build-php-unattended.sh ${PHP_VERSION}
         并把 Nginx 的 fastcgi_pass 改为 unix:/run/php/php-cgi${MAJOR}.${MINOR}.sock
----------------------------------------------------------------
MSG
  fi
}

show_summary(){
  echo "========== 安装完成 (无人值守、多版本并存、自动优化 php-fpm.conf) =========="
  echo "PHP        : ${PREFIX}"
  echo "FPM 服务   : php-fpm-${PHP_VERSION}.service"
  echo "FPM Socket : ${SOCK_PATH}  ← 与 Nginx fastcgi_pass 匹配"
  echo "php.ini    : ${PREFIX}/lib/php.ini (short_open_tag = Off)"
  echo "Composer   : /usr/local/bin/composer；包装器：/usr/local/bin/composer${MAJOR}${MINOR}"
  echo "CLI        : /usr/local/bin/php${MAJOR}${MINOR}  或  update-alternatives --config php"
  "${PREFIX}/bin/php" -v | head -n1
  "${PREFIX}/bin/php" -m | tr '\n' ' ' | sed 's/  */ /g'; echo
}

main(){
  ensure_www_user
  install_deps
  build_php
  install_extensions
  install_composer
  register_cli_switch
  verify_socket
  warn_if_nginx_privtmp
  show_summary
}
main "$@"

