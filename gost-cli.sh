#!/usr/bin/env bash
set -Eeuo pipefail

APP="gost-tui"
PREFIX="gost-tui"
REPO_API="https://api.github.com/repos/ginuerzh/gost/releases/latest"
GCI_CMD="/usr/local/bin/gci"
COLOR_OK=$'\033[0;32m'
COLOR_WARN=$'\033[1;33m'
COLOR_ERR=$'\033[0;31m'
COLOR_OFF=$'\033[0m'

GOST_TUI_HOME="/root/.gost-tui"
GOST_BIN="$GOST_TUI_HOME/bin/gost"

die() { echo "${COLOR_ERR}错误:${COLOR_OFF} $*" >&2; exit 1; }
warn() { echo "${COLOR_WARN}提示:${COLOR_OFF} $*" >&2; }
ok() { echo "${COLOR_OK}完成:${COLOR_OFF} $*"; }

has_tty() {
  [[ -r /dev/tty && -w /dev/tty ]]
}

init_line_editing() {
  bind '"\C-h": backward-delete-char' 2>/dev/null || true
  bind '"\e[3~": delete-char' 2>/dev/null || true
}

ui_print() {
  if has_tty; then
    printf '%s\n' "$*" >/dev/tty
  else
    printf '%s\n' "$*" >&2
  fi
}

ui_printf() {
  if has_tty; then
    printf "$@" >/dev/tty
  else
    printf "$@" >&2
  fi
}

pause() {
  if has_tty; then
    read -r -e -p "按回车继续..." _ </dev/tty
  else
    read -r -p "按回车继续..." _
  fi
}

msg() {
  local title="$1" text="$2"
  text=${text//\\n/$'\n'}
  ui_print ""
  ui_print "[$title]"
  ui_print "$text"
  pause
}

ask_yes() {
  local title="$1" text="$2"
  local ans
  ui_print ""
  ui_print "[$title]"
  if has_tty; then
    read -r -e -p "$text [y/N]: " ans </dev/tty
  else
    read -r -p "$text [y/N]: " ans
  fi
  [[ "$ans" =~ ^[Yy]([Ee][Ss])?$ ]]
}

input_box() {
  local title="$1" text="$2" default="${3:-}" out
  ui_print ""
  ui_print "[$title]"
  if has_tty; then
    read -r -e -i "$default" -p "$text: " out </dev/tty
  else
    read -r -p "$text [$default]: " out
  fi
  out="${out:-$default}"
  printf '%s\n' "$out"
}

input_command_line() {
  local title="$1" current="$2" out
  ui_print ""
  ui_print "[$title]"
  ui_print "当前参数:"
  ui_print "$current"
  ui_print ""
  if has_tty; then
    read -r -e -i "$current" -p "新参数: " out </dev/tty
  else
    read -r -p "新参数，回车保留当前: " out
  fi
  printf '%s\n' "${out:-$current}"
}

menu_box() {
  local title="$1" text="$2"; shift 2
  local out i tag desc
  ui_print ""
  ui_print "[$title] $text"
  i=1
  while [[ $# -gt 0 ]]; do
    tag="$1"; desc="$2"; shift 2
    ui_print "  $tag) $desc"
  done
  if has_tty; then
    read -r -e -p "请选择: " out </dev/tty
  else
    read -r -p "请选择: " out
  fi
  printf '%s\n' "$out"
}

check_root() {
  if [[ ${EUID:-$(id -u)} -ne 0 ]]; then
    if command -v sudo >/dev/null 2>&1; then
      exec sudo -E bash "$0" "$@"
    fi
    die "需要 root 权限运行，请使用 sudo。"
  fi
}

check_debian() {
  [[ -f /etc/debian_version ]] || die "仅支持 Debian 系统。"
  command -v systemctl >/dev/null 2>&1 || die "未找到 systemctl。"
}

init_dirs() {
  mkdir -p "$GOST_TUI_HOME/bin" "$GOST_TUI_HOME/services" "$GOST_TUI_HOME/units" "$GOST_TUI_HOME/tmp"
}

script_path() {
  local src="${BASH_SOURCE[0]}"
  if command -v readlink >/dev/null 2>&1; then
    readlink -f "$src" && return 0
  fi
  case "$src" in
    /*) printf '%s\n' "$src" ;;
    *) printf '%s/%s\n' "$(pwd -P)" "$src" ;;
  esac
}

register_gci_command() {
  local src current
  src=$(script_path)
  chmod 0755 "$src"
  mkdir -p "$(dirname "$GCI_CMD")"
  if [[ -e "$GCI_CMD" || -L "$GCI_CMD" ]]; then
    current=$(readlink -f "$GCI_CMD" 2>/dev/null || true)
    if [[ "$current" == "$src" ]]; then
      return 0
    fi
    if ! ask_yes "注册 gci" "$GCI_CMD 已存在且不是当前脚本，是否覆盖为当前脚本入口？"; then
      warn "跳过 gci 命令注册。"
      return 0
    fi
  fi
  ln -sfn "$src" "$GCI_CMD"
}

need_cmd() {
  command -v "$1" >/dev/null 2>&1
}

download_stdout() {
  local url="$1"
  if need_cmd curl; then
    curl -fsSL "$url"
  elif need_cmd wget; then
    wget -qO- "$url"
  else
    return 127
  fi
}

download_file() {
  local url="$1" out="$2"
  if need_cmd curl; then
    curl -fL --progress-bar "$url" -o "$out"
  elif need_cmd wget; then
    wget -O "$out" "$url"
  else
    return 127
  fi
}

install_download_tools() {
  if need_cmd curl || need_cmd wget; then
    return 0
  fi
  if ask_yes "缺少下载工具" "未找到 curl/wget，是否使用 apt 安装 curl ca-certificates？"; then
    apt-get update
    apt-get install -y curl ca-certificates
  else
    die "没有 curl 或 wget，无法下载 gost。"
  fi
}

arch_name() {
  case "$(uname -m)" in
    x86_64|amd64) echo "amd64" ;;
    i386|i686) echo "386" ;;
    aarch64|arm64) echo "arm64" ;;
    armv5*) echo "armv5" ;;
    armv6*) echo "armv6" ;;
    armv7*) echo "armv7" ;;
    mips64le) echo "mips64le" ;;
    mips64) echo "mips64" ;;
    mipsle) echo "mipsle" ;;
    mips) echo "mips" ;;
    s390x) echo "s390x" ;;
    *) die "不支持的架构: $(uname -m)" ;;
  esac
}

find_existing_gost() {
  local found
  found=$(find /usr/local/bin /usr/bin /usr/sbin /opt /root /home "$PWD" \
    -type f -name gost -perm -u+x 2>/dev/null | head -n 1 || true)
  if [[ -z "$found" ]]; then
    found=$(find / -type f -name gost -perm -u+x 2>/dev/null | head -n 1 || true)
  fi
  [[ -n "$found" ]] && printf '%s\n' "$found"
}

store_gost() {
  local src="$1"
  mkdir -p "$GOST_TUI_HOME/bin"
  cp "$src" "$GOST_BIN"
  chmod 0755 "$GOST_BIN"
}

download_gost() {
  local arch json url tmp tmpdir bin
  install_download_tools
  need_cmd tar || die "未找到 tar，请先安装 tar。"
  arch=$(arch_name)
  json=$(download_stdout "$REPO_API") || die "读取 GitHub Release 失败。"
  url=$(printf '%s\n' "$json" | grep -Eo 'https://[^"]+gost_[^"]+linux_'"$arch"'\.tar\.gz' | head -n 1 || true)
  if [[ -z "$url" ]]; then
    url=$(printf '%s\n' "$json" | grep -Eo 'https://[^"]+gost-linux-'"$arch"'-[^"]+\.gz' | head -n 1 || true)
  fi
  [[ -n "$url" ]] || die "没有找到 linux_${arch} 的 gost 发布包。"
  tmpdir=$(mktemp -d "$GOST_TUI_HOME/tmp/download.XXXXXX")
  tmp="$tmpdir/gost.pkg"
  echo "下载: $url"
  download_file "$url" "$tmp" || die "下载 gost 失败。"
  if [[ "$url" == *.tar.gz ]]; then
    tar -xzf "$tmp" -C "$tmpdir"
    bin=$(find "$tmpdir" -type f -name gost -perm -u+x | head -n 1 || true)
    [[ -n "$bin" ]] || bin=$(find "$tmpdir" -type f -name gost | head -n 1 || true)
    [[ -n "$bin" ]] || die "发布包里没有找到 gost。"
    store_gost "$bin"
  else
    gzip -dc "$tmp" >"$GOST_BIN"
    chmod 0755 "$GOST_BIN"
  fi
  rm -rf "$tmpdir"
}

ensure_gost() {
  if [[ -x "${GOST_BIN:-}" ]]; then
    return 0
  fi
  local found
  echo "正在查找系统已有 gost..."
  found=$(find_existing_gost || true)
  if [[ -n "$found" ]]; then
    store_gost "$found"
    ok "已复制 gost: $found -> $GOST_BIN"
  else
    warn "未找到本机 gost，准备从 GitHub Release 下载。"
    download_gost
    ok "已安装 gost: $GOST_BIN"
  fi
}

valid_name() {
  [[ "$1" =~ ^[A-Za-z0-9_-]+$ ]]
}

unit_name() {
  printf '%s-%s.service\n' "$PREFIX" "$1"
}

meta_file() {
  printf '%s/services/%s.meta\n' "$GOST_TUI_HOME" "$1"
}

run_file() {
  printf '%s/services/%s.run.sh\n' "$GOST_TUI_HOME" "$1"
}

unit_file() {
  printf '/etc/systemd/system/%s\n' "$(unit_name "$1")"
}

quote_unit() {
  local s="$1"
  s=${s//\\/\\\\}
  s=${s//\"/\\\"}
  printf '"%s"' "$s"
}

write_service_files() {
  local name="$1" args="$2" run unit meta now
  run=$(run_file "$name")
  unit=$(unit_file "$name")
  meta=$(meta_file "$name")
  now=$(date '+%F %T')
  {
    echo '#!/usr/bin/env bash'
    echo 'set -Eeuo pipefail'
    printf 'GOST_BIN=%q\n' "$GOST_BIN"
    printf 'GOST_ARGS_RAW=%q\n' "$args"
    echo 'eval "set -- $GOST_ARGS_RAW"'
    echo 'exec "$GOST_BIN" "$@"'
  } >"$run"
  chmod 0755 "$run"
  {
    echo '[Unit]'
    echo "Description=GOST forwarding service: $name"
    echo 'After=network-online.target'
    echo 'Wants=network-online.target'
    echo
    echo '[Service]'
    echo 'Type=simple'
    echo 'User=root'
    printf 'WorkingDirectory=%s\n' "$GOST_TUI_HOME"
    printf 'ExecStart=%s\n' "$run"
    echo 'Restart=always'
    echo 'RestartSec=3'
    echo 'LimitNOFILE=1048576'
    echo
    echo '[Install]'
    echo 'WantedBy=multi-user.target'
  } >"$unit"
  cp "$unit" "$GOST_TUI_HOME/units/$(unit_name "$name")"
  {
    printf 'NAME=%q\n' "$name"
    printf 'ARGS=%q\n' "$args"
    printf 'CREATED_AT=%q\n' "$now"
    printf 'RUN_FILE=%q\n' "$run"
    printf 'UNIT_FILE=%q\n' "$unit"
  } >"$meta"
}

refresh_existing_units() {
  local name meta changed=0
  while IFS= read -r name; do
    meta=$(meta_file "$name")
    ARGS=""
    # shellcheck disable=SC1090
    source "$meta"
    [[ -n "${ARGS:-}" ]] || continue
    write_service_files "$name" "$ARGS"
    changed=1
  done < <(service_names)
  if [[ "$changed" -eq 1 ]]; then
    systemctl daemon-reload
  fi
}

service_names() {
  local f
  shopt -s nullglob
  for f in "$GOST_TUI_HOME/services/"*.meta; do
    basename "$f" .meta
  done
  shopt -u nullglob
}

choose_service() {
  local names=() name choice idx unit active enabled meta
  while IFS= read -r name; do
    names+=("$name")
  done < <(service_names)
  [[ ${#names[@]} -gt 0 ]] || { msg "服务" "还没有创建任何 gost 服务。"; return 1; }

  while true; do
    ui_print ""
    ui_print "[服务列表] 输入编号或服务名，0 刷新列表，m 返回主页。"
    idx=1
    for name in "${names[@]}"; do
      unit=$(unit_name "$name")
      active=$(systemctl is-active "$unit" 2>/dev/null || true)
      enabled=$(systemctl is-enabled "$unit" 2>/dev/null || true)
      meta=$(meta_file "$name")
      ARGS=""
      # shellcheck disable=SC1090
      source "$meta"
      ui_printf '%s) %s  状态:%s  自启:%s\n' "$idx" "$name" "$active" "$enabled"
      ui_printf '   参数: %s\n' "$ARGS"
      idx=$((idx + 1))
    done
    if has_tty; then
      read -r -e -p "请选择服务: " choice </dev/tty
    else
      read -r -p "请选择服务: " choice
    fi
    case "$choice" in
      0) continue ;;
      m|M|q|Q|b|B|back|BACK|返回) return 1 ;;
    esac
    if [[ "$choice" =~ ^[0-9]+$ ]] && [[ "$choice" -ge 1 ]] && [[ "$choice" -le ${#names[@]} ]]; then
      printf '%s\n' "${names[$((choice - 1))]}"
      return 0
    fi
    for name in "${names[@]}"; do
      if [[ "$choice" == "$name" ]]; then
        printf '%s\n' "$name"
        return 0
      fi
    done
    msg "错误" "没有这个服务: $choice"
  done
}

valid_port() {
  [[ "$1" =~ ^[0-9]+$ ]] && [[ "$1" -ge 1 ]] && [[ "$1" -le 65535 ]]
}

input_port() {
  local title="$1" text="$2" default="$3" port
  while true; do
    port=$(input_box "$title" "$text" "$default") || return 1
    if valid_port "$port"; then
      printf '%s\n' "$port"
      return 0
    fi
    msg "错误" "端口必须是 1-65535。"
  done
}

input_required() {
  local title="$1" text="$2" default="$3" val
  while true; do
    val=$(input_box "$title" "$text" "$default") || return 1
    if [[ -n "$val" ]]; then
      printf '%s\n' "$val"
      return 0
    fi
    msg "错误" "不能为空。"
  done
}

append_chain_args() {
  local args="$1" chains chain
  chains=$(input_box "转发链" "可选 -F，多个用空格分隔。" "") || return 1
  if [[ -n "$chains" ]]; then
    for chain in $chains; do
      args="$args -F=$chain"
    done
  fi
  printf '%s\n' "$args"
}

make_args_from_template() {
  local mode listen args local_port target_host target_port auth user pass
  mode=$(menu_box "创建服务" "选择类型。" \
    "1" "TCP 转发" \
    "2" "UDP 转发" \
    "3" "HTTP 代理" \
    "4" "SOCKS5 代理" \
    "5" "手写完整参数") || return 1
  case "$mode" in
    1)
      local_port=$(input_port "本机端口" "本机监听端口。" "8080") || return 1
      target_host=$(input_required "目标 IP" "目标 IP 或域名。" "127.0.0.1") || return 1
      target_port=$(input_port "目标端口" "目标端口。" "80") || return 1
      args="-L=tcp://:${local_port}/${target_host}:${target_port}"
      append_chain_args "$args"
      return
      ;;
    2)
      local_port=$(input_port "本机端口" "本机监听端口。" "5353") || return 1
      target_host=$(input_required "目标 IP" "目标 IP 或域名。" "8.8.8.8") || return 1
      target_port=$(input_port "目标端口" "目标端口。" "53") || return 1
      args="-L=udp://:${local_port}/${target_host}:${target_port}"
      append_chain_args "$args"
      return
      ;;
    3)
      local_port=$(input_port "本机端口" "HTTP 代理监听端口。" "8080") || return 1
      auth=""
      if ask_yes "认证" "是否启用用户名密码？"; then
        user=$(input_required "用户名" "HTTP 用户名。" "user") || return 1
        pass=$(input_required "密码" "HTTP 密码。" "pass") || return 1
        auth="${user}:${pass}@"
      fi
      printf '%s\n' "-L=http://${auth}:${local_port}"
      return
      ;;
    4)
      local_port=$(input_port "本机端口" "SOCKS5 监听端口。" "1080") || return 1
      auth=""
      if ask_yes "认证" "是否启用用户名密码？"; then
        user=$(input_required "用户名" "SOCKS5 用户名。" "user") || return 1
        pass=$(input_required "密码" "SOCKS5 密码。" "pass") || return 1
        auth="${user}:${pass}@"
      fi
      printf '%s\n' "-L=socks5://${auth}:${local_port}"
      return
      ;;
    5)
      input_box "完整参数" "手写 gost 参数。" "-L=tcp://:8080/1.1.1.1:80"
      return
      ;;
    *) return 1 ;;
  esac
}

create_service() {
  ensure_gost
  local name args unit
  name=$(input_box "服务名称" "字母数字下划线中横线。" "demo") || return
  valid_name "$name" || { msg "错误" "服务名称格式不合法。"; return; }
  [[ ! -f "$(meta_file "$name")" ]] || { msg "错误" "服务已存在: $name"; return; }
  args=$(make_args_from_template) || return
  [[ -n "$args" ]] || { msg "错误" "参数不能为空。"; return; }
  write_service_files "$name" "$args"
  unit=$(unit_name "$name")
  systemctl daemon-reload
  if ask_yes "启动服务" "是否启用并立即启动 $unit？"; then
    systemctl enable --now "$unit" || msg "错误" "服务创建成功，但启动失败。\n请查看状态或日志。"
  fi
  msg "创建完成" "服务: $unit\n参数: $args"
}

show_services() {
  local name unit active enabled args meta
  echo
  printf '%-24s %-10s %-10s %s\n' "服务" "状态" "自启" "参数"
  printf '%-24s %-10s %-10s %s\n' "----" "----" "----" "----"
  while IFS= read -r name; do
    unit=$(unit_name "$name")
    active=$(systemctl is-active "$unit" 2>/dev/null || true)
    enabled=$(systemctl is-enabled "$unit" 2>/dev/null || true)
    meta=$(meta_file "$name")
    ARGS=""
    # shellcheck disable=SC1090
    source "$meta"
    printf '%-24s %-10s %-10s %s\n' "$unit" "$active" "$enabled" "$ARGS"
  done < <(service_names)
  echo
  pause
}

service_action() {
  local name="$1" action="$2" unit
  unit=$(unit_name "$name")
  case "$action" in
    start) systemctl start "$unit" || { msg "错误" "启动失败: $unit"; return; } ;;
    stop) systemctl stop "$unit" || { msg "错误" "停止失败: $unit"; return; } ;;
    restart) systemctl restart "$unit" || { msg "错误" "重启失败: $unit"; return; } ;;
    enable) systemctl enable "$unit" || { msg "错误" "设置自启失败: $unit"; return; } ;;
    disable) systemctl disable "$unit" || { msg "错误" "取消自启失败: $unit"; return; } ;;
    status) systemctl status "$unit" --no-pager || true; pause ;;
    logs) journalctl -u "$unit" -n 80 --no-pager || true; pause ;;
  esac
}

edit_service() {
  local name="$1" meta args
  meta=$(meta_file "$name")
  ARGS=""
  # shellcheck disable=SC1090
  source "$meta"
  args=$(input_command_line "修改参数" "$ARGS") || return
  [[ -n "$args" ]] || { msg "错误" "参数不能为空。"; return; }
  write_service_files "$name" "$args"
  systemctl daemon-reload
  if systemctl restart "$(unit_name "$name")"; then
    msg "修改完成" "已更新并重启: $(unit_name "$name")"
  else
    msg "修改完成" "已更新，但重启失败。\n请查看状态或日志。"
  fi
}

manage_service() {
  local name action
  while true; do
    name=$(choose_service) || return
    while true; do
      ui_print ""
      ui_print "[管理服务] 服务: $name"
      ui_print "  1) 启动"
      ui_print "  2) 停止"
      ui_print "  3) 重启"
      ui_print "  4) 开机自启"
      ui_print "  5) 取消自启"
      ui_print "  6) 查看状态"
      ui_print "  7) 查看最近日志"
      ui_print "  8) 修改 gost 参数"
      ui_print "  9) 删除服务"
      ui_print "  0) 返回服务列表"
      if has_tty; then
        read -r -e -p "请选择操作: " action </dev/tty
      else
        read -r -p "请选择操作: " action
      fi
      case "$action" in
        1) service_action "$name" "start" ;;
        2) service_action "$name" "stop" ;;
        3) service_action "$name" "restart" ;;
        4) service_action "$name" "enable" ;;
        5) service_action "$name" "disable" ;;
        6) service_action "$name" "status" ;;
        7) service_action "$name" "logs" ;;
        8) edit_service "$name" ;;
        9)
          delete_service_by_name "$name"
          break
          ;;
        0|q|Q|b|B|back|BACK|返回) break ;;
        *) msg "错误" "没有这个操作: $action" ;;
      esac
    done
  done
}

delete_service_by_name() {
  local name unit
  name="$1"
  unit=$(unit_name "$name")
  ask_yes "删除确认" "确认删除 $unit？这会停止服务、取消自启并删除对应 unit/run/meta 文件。" || return
  systemctl stop "$unit" 2>/dev/null || true
  systemctl disable "$unit" 2>/dev/null || true
  rm -f "$(unit_file "$name")" "$(run_file "$name")" "$(meta_file "$name")" "$GOST_TUI_HOME/units/$unit"
  systemctl daemon-reload
  systemctl reset-failed "$unit" 2>/dev/null || true
  msg "删除完成" "已删除: $unit"
}

repair_gost() {
  if [[ -x "$GOST_BIN" ]] && ask_yes "重新初始化" "已存在 $GOST_BIN，是否重新查找/下载并覆盖？"; then
    rm -f "$GOST_BIN"
  fi
  ensure_gost
  "$GOST_BIN" -V 2>/dev/null || "$GOST_BIN" -v 2>/dev/null || true
  pause
}

main_menu() {
  local choice
  while true; do
    ui_print ""
    ui_print "快捷命令: gci 可以快速打开本管理脚本。"
    choice=$(menu_box "$APP" "数据目录: $GOST_TUI_HOME" \
      "1" "初始化或修复 gost" \
      "2" "创建转发服务" \
      "3" "管理已有服务" \
      "0" "退出") || exit 0
    case "$choice" in
      1) repair_gost ;;
      2) create_service ;;
      3) manage_service ;;
      0) exit 0 ;;
    esac
  done
}

main() {
  init_line_editing
  check_root "$@"
  check_debian
  init_dirs
  register_gci_command
  refresh_existing_units
  main_menu
}

main "$@"
