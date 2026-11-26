#!/bin/bash

# 脚本版本独立于 Xray 核心版本；每次发布脚本修改时递增此版本号。
readonly SCRIPT_VERSION="1.2.0"

# --- 颜色定义 ---
readonly red='\e[91m' green='\e[92m' yellow='\e[93m'
readonly magenta='\e[95m' cyan='\e[96m' none='\e[0m'
# --- 提示函数 ---
error() { echo -e "\n${red}$1${none}\n" >&2; }
info() { echo -e "\n${yellow}$1${none}\n"; }
success() { echo -e "\n${green}$1${none}\n"; }
# --- 全局变量 ---
SERVER_IP=""
TEMP_FILES=()
ACTIVE_TRANSACTION=()
TRANSACTION_RESTARTING=false
TRANSACTION_WAS_ACTIVE=false
ACTIVE_GEO_TRANSACTION=()
ACTIVE_XRAY_UPGRADE=()
ACTIVE_GEO_SCHEDULE=()
XRM_LOCK_HELD=false

register_temp_file() {
    TEMP_FILES+=("$1")
}

cleanup_temp_files() {
    local temp_file
    for temp_file in "${TEMP_FILES[@]}"; do
        [ -e "$temp_file" ] && rm -rf -- "$temp_file"
    done
    return 0
}

url_encode() {
    jq -sRr @uri
}

# 普通字段直接输出；空值、数字字符串及特殊字符使用单引号，避免 YAML 改变类型或结构。
yaml_scalar() {
    local value="$1" lower="${1,,}"
    local number_pattern='^[-+]?([0-9_]+([.][0-9_]*)?([eE][-+]?[0-9]+)?|[.][0-9_]+|0[xX][0-9a-fA-F_]+|0[oO][0-7_]+|0[bB][01_]+)$'
    case "$lower" in
        ''|null|true|false|yes|no|on|off|y|n|~|.nan|.inf|+.inf|-.inf)
            printf "'%s'" "${value//\'/\'\'}"
            return
            ;;
    esac
    # 中文、空格和名称中间的 | 可以原样输出，不按 ASCII 白名单限制。
    local plain=true
    case "$value" in
        *','*|*'['*|*']'*|*'{'*|*'}'*|*':'*|*'#'*|*'"'*|*"'"*|*$'\n'*|*$'\r'*|*$'\t'*) plain=false ;;
    esac
    case "${value:0:1}" in
        '-'|'?'|':'|','|'['|']'|'{'|'}'|'#'|'&'|'*'|'!'|'|'|'>'|"'"|'"'|'%'|'@'|'`') plain=false ;;
    esac
    if [ "$plain" = true ] &&
       [[ ! "$value" =~ ^[[:space:]]|[[:space:]]$ ]] &&
       [[ ! "$value" =~ $number_pattern ]] &&
       [[ ! "$value" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2} ]]; then
        printf '%s' "$value"
    else
        printf "'%s'" "${value//\'/\'\'}"
    fi
}

# URI 地址中 IPv6 需要方括号；YAML / Xray 地址使用不带方括号的形式。
uri_host() {
    local address="${1#[}"
    address="${address%]}"
    if [[ "$address" == *:* ]]; then
        printf '[%s]' "$address"
    else
        printf '%s' "$address"
    fi
}
# ---路径常量 ---
readonly XRAY_CONFIG_PATH="/usr/local/etc/xray/config.json"
readonly XRAY_BINARY_PATH="/usr/local/bin/xray"
readonly YAML_NODES_FILE="/usr/local/etc/xray/clash_nodes.yaml"
readonly NODES_META_FILE="/usr/local/etc/xray/nodes_meta.json"
readonly OUTBOUND_PROFILES_FILE="/usr/local/etc/xray/outbound_profiles.json"
readonly XRAY_GEO_DIR="/usr/local/share/xray"
readonly XRAY_LOCK_PATH="/run/xrm.lock"
readonly AI_OUTBOUND_TAG="xrm-ai"
readonly AI_RULE_TAG="xrm-ai-route"
readonly AI_GEOSITE="geosite:category-ai-!cn"

acquire_xrm_lock() {
    command -v flock >/dev/null 2>&1 || { error "缺少 flock，请先安装依赖"; return 1; }
    mkdir -p "$(dirname "$XRAY_LOCK_PATH")" || return 1
    exec 9> "$XRAY_LOCK_PATH" || return 1
    if ! flock -n 9; then
        exec 9>&-
        error "另一个 xrm 操作正在进行，请稍后重试"
        return 75
    fi
    XRM_LOCK_HELD=true
}

release_xrm_lock() {
    flock -u 9
    exec 9>&-
    XRM_LOCK_HELD=false
}

# 同进程包装保留交互状态；锁覆盖读取、生成候选、提交及恢复。
with_xrm_lock() {
    local owns_lock=false result
    if [ "$XRM_LOCK_HELD" != true ]; then
        acquire_xrm_lock || return $?
        owns_lock=true
    fi
    if "$@"; then result=0; else result=$?; fi
    if [ "$owns_lock" = true ]; then release_xrm_lock; fi
    return "$result"
}

# 限制位数后按十进制解析，避免整数溢出和前导零被按八进制解释。
normalize_decimal() {
    local value="$1" minimum="$2" maximum="$3"
    [[ "$value" =~ ^[0-9]{1,18}$ ]] || return 1
    value=$((10#$value))
    [ "$value" -ge "$minimum" ] && [ "$value" -le "$maximum" ] || return 1
    printf '%s\n' "$value"
}

# 同目录替换，并沿用现有文件的属主/权限；保留已有配置软链接。
atomic_replace_file() {
    local source="$1" target="$2" reference="${3:-$2}" temp mode owner
    if [ -L "$target" ]; then
        target=$(readlink -f "$target") || return 1
    fi
    temp=$(mktemp "$(dirname "$target")/.xrm-write.XXXXXX") || return 1
    register_temp_file "$temp"
    if ! cat "$source" > "$temp"; then return 1; fi
    if [ -e "$reference" ]; then
        mode=$(stat -L -c '%a' "$reference") || return 1
        owner=$(stat -L -c '%u:%g' "$reference") || return 1
        chown "$owner" "$temp" && chmod "$mode" "$temp" || return 1
    else
        chmod 600 "$temp" || return 1
    fi
    mv -f "$temp" "$target"
}

validate_xray_config() {
    local candidate="$1" assets="${2:-}" binary="${3:-$XRAY_BINARY_PATH}" check_dir check_file result=0
    jq empty "$candidate" || { error "配置不是有效 JSON，未应用修改"; return 1; }
    # 新版 external loader 即使有 -format json 也会检查文件扩展名。
    # BusyBox mktemp 的模板必须以 XXXXXX 结尾，使用私有目录中的固定 .json 文件。
    check_dir=$(mktemp -d "${TMPDIR:-/tmp}/xrm-check.XXXXXX") || return 1
    register_temp_file "$check_dir"
    check_file="$check_dir/config.json"
    (umask 077; cat "$candidate" > "$check_file") || return 1
    if [ -n "$assets" ]; then
        env -u xray.location.confdir -u XRAY_LOCATION_CONFDIR \
            -u xray.mph.cache -u XRAY_MPH_CACHE \
            "xray.location.asset=$assets" "XRAY_LOCATION_ASSET=$assets" \
            "$binary" run -test -format json -config "$check_file" || result=$?
    else
        env -u xray.location.confdir -u XRAY_LOCATION_CONFDIR \
            "$binary" run -test -format json -config "$check_file" || result=$?
    fi
    if [ "$result" -ne 0 ]; then
        rm -rf -- "$check_dir"
        error "Xray 配置预检失败，未应用修改"
        return 1
    fi
    rm -rf -- "$check_dir"
}

xray_service_is_active() {
    if [ "$OS_TYPE" = debian ]; then
        systemctl is-active --quiet xray
    elif [ "$OS_TYPE" = alpine ]; then
        rc-service xray status >/dev/null 2>&1
    else
        return 1
    fi
}

stop_xray() {
    if [ "$OS_TYPE" = debian ]; then
        systemctl stop xray 9>&- || { error "停止 Xray 服务失败"; return 1; }
    elif [ "$OS_TYPE" = alpine ]; then
        rc-service xray stop 9>&- || { error "停止 Xray 服务失败"; return 1; }
    else
        return 1
    fi
    if xray_service_is_active; then
        error "Xray 服务仍在运行，停止操作未完成"
        return 1
    fi
    return 0
}

restore_node_state() {
    local config_backup="$1" meta_backup="$2" yaml_backup="$3"
    local meta_existed="$4" yaml_existed="$5" failed=0 backup
    atomic_replace_file "$config_backup" "$XRAY_CONFIG_PATH" "$config_backup" || failed=1
    if [ "$meta_existed" = true ]; then
        atomic_replace_file "$meta_backup" "$NODES_META_FILE" "$meta_backup" || failed=1
    else
        rm -f "$NODES_META_FILE" || failed=1
    fi
    if [ "$yaml_existed" = true ]; then
        atomic_replace_file "$yaml_backup" "$YAML_NODES_FILE" "$yaml_backup" || failed=1
    else
        rm -f "$YAML_NODES_FILE" || failed=1
    fi
    if [ "$failed" -ne 0 ]; then
        # 恢复失败时，不能让退出清理删除仅存的旧状态。
        for backup in "$config_backup" "$meta_backup" "$yaml_backup"; do
            [ -n "$backup" ] || continue
            TEMP_FILES=("${TEMP_FILES[@]/$backup/}")
        done
        error "恢复旧配置失败，备份保留在: $config_backup $meta_backup $yaml_backup"
        return 1
    fi
}

rollback_active_transaction() {
    [ "${#ACTIVE_TRANSACTION[@]}" -gt 0 ] || return 0
    local failed=0
    restore_node_state "${ACTIVE_TRANSACTION[@]}" || failed=1
    if [ "$failed" -eq 0 ] && [ "$TRANSACTION_RESTARTING" = true ]; then
        if [ "$TRANSACTION_WAS_ACTIVE" = true ]; then
            restart_xray || failed=1
        else
            stop_xray || failed=1
        fi
    fi
    ACTIVE_TRANSACTION=()
    if [ "$failed" -ne 0 ]; then
        error "原状态恢复未完成，请检查日志及保留的备份"
        return 1
    fi
}

rollback_active_operations() {
    local failed=0
    rollback_active_geo_schedule || failed=1
    rollback_active_geo_update || failed=1
    rollback_active_transaction || failed=1
    rollback_active_xray_upgrade || failed=1
    return "$failed"
}

finish_xrm() {
    local status="${1:-0}"
    # 恢复期间忽略重复信号；EXIT 与信号共用同一恢复入口，防止仅清理备份。
    trap - EXIT
    trap '' HUP INT TERM
    if ! rollback_active_operations && [ "$status" -eq 0 ]; then status=1; fi
    cleanup_temp_files
    exit "$status"
}

handle_interrupt() {
    finish_xrm "${1:-130}"
}

install_xrm_traps() {
    trap 'finish_xrm "$?"' EXIT
    trap 'handle_interrupt 129' HUP
    trap 'handle_interrupt 130' INT
    trap 'handle_interrupt 143' TERM
}

# 验证通过后才提交；备份保留到服务重启成功。元数据候选为空表示不修改。
commit_xray_state() {
    local candidate="$1" meta_candidate="${2:-}" yaml_candidate="${3:-}" assets="${4:-}"
    local config_backup meta_backup="" yaml_backup="" meta_existed=false yaml_existed=false
    local write_failed=false
    if [ -z "$assets" ] && jq -e --arg tag "$AI_RULE_TAG" \
        'any(.routing.rules[]?; .ruleTag == $tag)' "$candidate" >/dev/null; then
        resolve_xray_asset_context || return 1
        assets="$GEO_ASSET_PRIMARY"
    fi
    validate_xray_config "$candidate" "$assets" || return 1
    config_backup=$(mktemp "$(dirname "$XRAY_CONFIG_PATH")/.xrm-config-backup.XXXXXX") || return 1
    register_temp_file "$config_backup"
    cp -p "$XRAY_CONFIG_PATH" "$config_backup" || return 1
    if [ -f "$NODES_META_FILE" ]; then
        meta_existed=true
        meta_backup=$(mktemp "$(dirname "$NODES_META_FILE")/.xrm-meta-backup.XXXXXX") || return 1
        register_temp_file "$meta_backup"
        cp -p "$NODES_META_FILE" "$meta_backup" || return 1
    fi
    if [ -f "$YAML_NODES_FILE" ]; then
        yaml_existed=true
        yaml_backup=$(mktemp "$(dirname "$YAML_NODES_FILE")/.xrm-yaml-backup.XXXXXX") || return 1
        register_temp_file "$yaml_backup"
        cp -p "$YAML_NODES_FILE" "$yaml_backup" || return 1
    fi
    TRANSACTION_WAS_ACTIVE=false
    if xray_service_is_active; then TRANSACTION_WAS_ACTIVE=true; fi
    TRANSACTION_RESTARTING=false
    ACTIVE_TRANSACTION=("$config_backup" "$meta_backup" "$yaml_backup" "$meta_existed" "$yaml_existed")
    atomic_replace_file "$candidate" "$XRAY_CONFIG_PATH" || write_failed=true
    if [ "$write_failed" = false ] && [ -n "$meta_candidate" ]; then
        atomic_replace_file "$meta_candidate" "$NODES_META_FILE" || write_failed=true
    fi
    if [ "$write_failed" = false ] && [ -n "$yaml_candidate" ]; then
        atomic_replace_file "$yaml_candidate" "$YAML_NODES_FILE" || write_failed=true
    fi
    if [ "$write_failed" = true ]; then
        rollback_active_transaction || return 1
        error "写入失败，已恢复原配置和节点文件"
        return 1
    fi
    TRANSACTION_RESTARTING=true
    if ! restart_xray; then
        rollback_active_transaction || return 1
        error "新配置启动失败，已恢复原配置和服务状态"
        return 1
    fi
    ACTIVE_TRANSACTION=()
    rm -f "$config_backup" "$meta_backup" "$yaml_backup"
}

commit_xray_config() {
    commit_xray_state "$1"
}

# 先生成三个候选文件，生成失败不会留下半个节点。
commit_new_node() {
    local inbound="$1" tag="$2" link="$3" yaml="$4" client="$5"
    local config_candidate meta_candidate yaml_candidate
    config_candidate=$(mktemp) || return 1
    register_temp_file "$config_candidate"
    meta_candidate=$(mktemp) || return 1
    register_temp_file "$meta_candidate"
    yaml_candidate=$(mktemp) || return 1
    register_temp_file "$yaml_candidate"
    jq --argjson inbound "$inbound" '.inbounds += [$inbound]' "$XRAY_CONFIG_PATH" > "$config_candidate" || return 1
    local meta_source="$NODES_META_FILE"
    if [ ! -f "$meta_source" ]; then
        printf '{"nodes":[]}' > "$meta_candidate" || return 1
        meta_source="$meta_candidate"
    fi
    local meta_json
    meta_json=$(jq --arg tag "$tag" --arg link "$link" --arg yaml "$yaml" \
        --argjson client "$client" --arg time "$(date -u +%Y-%m-%dT%H:%M:%SZ)" '
        .nodes += [{tag:$tag, share_link:$link, yaml_config:$yaml,
                    client_config:$client, created_at:$time}]' "$meta_source") || return 1
    printf '%s\n' "$meta_json" > "$meta_candidate" || return 1
    sync_ai_sniffing "$config_candidate" "$meta_candidate" || return 1
    if [ -f "$YAML_NODES_FILE" ]; then
        cat "$YAML_NODES_FILE" > "$yaml_candidate" || return 1
    fi
    printf '%s\n' "$yaml" >> "$yaml_candidate" || return 1
    commit_xray_state "$config_candidate" "$meta_candidate" "$yaml_candidate"
}

# --- 检查是否为 root 用户 ---
check_root() {
    if [ "$(id -u)" -ne 0 ]; then
        error "需root权限运行脚本"
        exit 1
    fi
}

# --- 检查操作系统类型 ---
detect_os() {
    if [ -f /etc/alpine-release ]; then
        OS_TYPE="alpine"
    elif [ -f /etc/os-release ] && grep -qi "debian\|ubuntu" /etc/os-release; then
        OS_TYPE="debian"
    else
        error "不支持的操作系统"
        exit 1
    fi
    info "检测到系统: ${OS_TYPE}"
}

# --- 检查必要依赖 ---
check_dependencies() {
    local missing_deps=()
    
    for cmd in curl unzip jq openssl flock; do
        if ! command -v "$cmd" >/dev/null 2>&1; then
            if [ "$cmd" = flock ] && [ "$OS_TYPE" = debian ]; then
                missing_deps+=(util-linux)
            else
                missing_deps+=("$cmd")
            fi
        fi
    done
    
    if [ ${#missing_deps[@]} -gt 0 ]; then
        info "安装缺失的依赖: ${missing_deps[*]}"
        if [ "$OS_TYPE" = "alpine" ]; then
            apk add --no-cache "${missing_deps[@]}" || {
                error "依赖安装失败"
                return 1
            }
        elif [ "$OS_TYPE" = "debian" ]; then
            apt-get update -qq && apt-get install -y -qq "${missing_deps[@]}" || {
                error "依赖安装失败"
                return 1
            }
        fi
        success "安装完成"
    fi
}

# --- 校验 Xray Release 资产摘要 ---
verify_release_asset_digest() {
    local version="$1"
    local asset_name="$2"
    local file_path="$3"
    local release_json expected_digest actual_digest

    release_json=$(curl -fsSL --max-time 30 \
        "https://api.github.com/repos/XTLS/Xray-core/releases/tags/v${version}") || {
        error "获取Xray Release校验信息失败"
        return 1
    }

    expected_digest=$(printf '%s' "$release_json" | jq -r --arg asset "$asset_name" \
        '.assets[] | select(.name == $asset) | .digest // empty' | head -n 1)
    expected_digest=${expected_digest#sha256:}

    if ! [[ "$expected_digest" =~ ^[0-9a-fA-F]{64}$ ]]; then
        error "未找到 ${asset_name} 的有效 SHA256 校验值"
        return 1
    fi

    if command -v sha256sum >/dev/null 2>&1; then
        actual_digest=$(sha256sum "$file_path" | awk '{print $1}')
    else
        actual_digest=$(openssl dgst -sha256 "$file_path" | awk '{print $NF}')
    fi

    if [ "${actual_digest,,}" != "${expected_digest,,}" ]; then
        error "${asset_name} SHA256 校验失败"
        return 1
    fi

    return 0
}

# --- 校验 GitHub Contents 文件摘要 ---
verify_github_file_digest() {
    local file_path="$1"
    local metadata_url="$2"
    local metadata expected_sha actual_sha file_size

    metadata=$(curl -fsSL --max-time 30 "$metadata_url") || {
        error "获取全局命令校验信息失败"
        return 1
    }

    expected_sha=$(printf '%s' "$metadata" | jq -r '.sha // empty')
    if ! [[ "$expected_sha" =~ ^[0-9a-fA-F]{40}$ ]]; then
        error "未找到全局命令的有效校验值"
        return 1
    fi

    file_size=$(wc -c < "$file_path")
    actual_sha=$(printf 'blob %s\0' "$file_size" | cat - "$file_path" | openssl dgst -sha1 | awk '{print $NF}')

    if [ "${actual_sha,,}" != "${expected_sha,,}" ]; then
        error "全局命令 SHA1 校验失败"
        return 1
    fi

    return 0
}

# --- 检查端口是否可用 ---
check_port_available() {
    local port="$1"

    if ! port=$(normalize_decimal "$port" 1 65535); then
        error "无效端口: ${port} (应为 1-65535 的整数)"
        return 1
    fi

    # 检查是否与已有 Xray 入站端口冲突
    if [ -f "$XRAY_CONFIG_PATH" ]; then
        if jq -e --argjson port "$port" '.inbounds[]? | select((.port? // -1) == $port)' "$XRAY_CONFIG_PATH" >/dev/null 2>&1; then
            error "端口 ${port} 已占用，请选择其他端口"
            return 1
        fi
    fi

    # 优先使用 ss 检查系统监听端口
    if command -v ss >/dev/null 2>&1; then
        if ss -H -lntu 2>/dev/null | awk -v p=":${port}" '$5 ~ p"$" {found=1; exit} END {exit !found}'; then
            error "端口 ${port} 已占用，请选择其他端口"
            return 1
        fi
    else
        # 兜底: 直接读取 /proc/net，避免依赖额外工具
        local port_hex proc_file
        port_hex=$(printf '%04X' "$port")

        for proc_file in /proc/net/tcp /proc/net/tcp6 /proc/net/udp /proc/net/udp6; do
            [ -r "$proc_file" ] || continue
            if awk -v p=":${port_hex}" 'NR>1 {if (toupper($2) ~ p"$") {found=1; exit}} END {exit !found}' "$proc_file"; then
                error "端口 ${port} 已占用，请选择其他端口"
                return 1
            fi
        done
    fi

    return 0
}

# 文档要求非空 tag 唯一；同时检查入站和出站，避免覆盖或删除错误节点。
check_tag_available() {
    local tag="$1"
    if [ -z "$tag" ]; then
        error "节点标签不能为空"
        return 1
    fi
    if jq -e --arg tag "$tag" \
        'any((.inbounds[]?, .outbounds[]?); .tag == $tag)' \
        "$XRAY_CONFIG_PATH" >/dev/null; then
        error "标签已存在: $tag"
        return 1
    fi
    # jq 出错时不继续写入，以免把异常配置当成标签可用。
    if ! jq -e --arg tag "$tag" \
        'all((.inbounds[]?, .outbounds[]?); .tag != $tag)' \
        "$XRAY_CONFIG_PATH" >/dev/null; then
        error "无法读取配置或检查标签"
        return 1
    fi
}

# --- 获取 GitHub 标记的最新正式版本，不提供版本选择 ---
get_latest_xray_version() {
    local release version
    info "正在获取 Xray 最新正式版本..." >&2
    release=$(curl -fsSL --max-time 30 \
        "https://api.github.com/repos/XTLS/Xray-core/releases/latest") || {
        error "获取最新正式版本失败，请检查网络或 GitHub API 限额"
        return 1
    }
    version=$(printf '%s' "$release" | jq -er '
        select(.draft == false and .prerelease == false)
        | .tag_name | select(test("^v[0-9]+\\.[0-9]+\\.[0-9]+$"))
        | ltrimstr("v")') || {
        error "最新正式版本信息无效"
        return 1
    }
    printf '%s\n' "$version"
}

# --- Xray 自动安装函数 ---
install_xray() {
    local current_version version
    # 已有核心不自动升级；仍补齐未完成的安装步骤。
    if [ -f "$XRAY_BINARY_PATH" ]; then
        if [ ! -x "$XRAY_BINARY_PATH" ] || \
           ! current_version=$("$XRAY_BINARY_PATH" version 2>/dev/null); then
            error "现有 Xray 核心无法执行，请检查文件或手动重新安装"
            return 1
        fi
        current_version=$(printf '%s\n' "$current_version" | head -n 1 | awk '{print $2}')
        if [ -z "$current_version" ]; then
            error "现有 Xray 核心版本信息无效，请检查文件或手动重新安装"
            return 1
        fi
        success "Xray 已安装 (版本: ${current_version})"
    else
        info "未检测到 Xray，开始安装..."

        check_dependencies || return 1

        # 首次安装直接使用 GitHub 标记的最新正式版本。
        version=$(get_latest_xray_version) || return 1
        download_and_install_xray "$version" || return 1
    fi

    # 默认位置缺失时先确认实际加载位置，避免打开菜单就刷新自定义目录的数据。
    if [ ! -s /usr/local/share/xray/geoip.dat ] || \
       [ ! -s /usr/local/share/xray/geosite.dat ]; then
        resolve_xray_geo_targets || return 1
        if [ ! -s "$GEO_IP_PATH" ] || [ ! -s "$GEO_SITE_PATH" ]; then
            update_geo_data || return 1
        fi
    fi
    
    # 创建函数会保留已有服务，避免覆盖用户自定义运行参数和用户。
    create_service || return 1
    
    success "Xray 安装完成"
}

# --- Geo 数据更新：固定发布版本、摘要校验、预检和双文件回滚 ---
sha256_file() {
    if command -v sha256sum >/dev/null 2>&1; then
        sha256sum "$1" | awk '{print $1}'
    else
        openssl dgst -sha256 "$1" | awk '{print $NF}'
    fi
}

fetch_geo_release() {
    curl -fsSL --max-time 30 https://api.github.com/repos/Loyalsoldier/v2ray-rules-dat/releases/latest
}

# Xray 按“变量是否存在”选择资产目录；空值代表进程工作目录。
geo_context_error() {
    error "无法确认 Xray Geo 加载目录：$1。请先使用直接启动的 Xray 服务，或检查其资产目录配置"
    return 1
}

geo_context_absolute() {
    local path="$1" cwd="$2" component
    local -a components=() parts=()
    case "$path$cwd" in *$'\n'*|*$'\r'*) return 1 ;; esac
    [[ "$path" = /* ]] || path="$cwd/$path"
    IFS=/ read -r -a parts <<< "$path"
    for component in "${parts[@]}"; do
        case "$component" in
            ''|.) ;;
            ..) [ "${#components[@]}" -eq 0 ] || unset 'components[-1]' ;;
            *) components+=("$component") ;;
        esac
    done
    local IFS=/
    printf '/%s\n' "${components[*]}"
}

# 只拆分 systemctl 的静态引号，不执行变量展开、命令替换或 shell 代码。
geo_context_words() {
    local text="$1" word="" quote="" char next active=false i
    GEO_CONTEXT_WORDS=()
    for ((i=0; i<${#text}; i++)); do
        char="${text:i:1}"
        if [ "$char" = '\' ] && [ "$quote" != "'" ]; then
            i=$((i + 1))
            [ "$i" -lt "${#text}" ] || return 1
            next="${text:i:1}"
            case "$next" in ' '|$'\t'|'\'|'"'|"'") word+="$next" ;; *) return 1 ;; esac
            active=true
        elif [ -n "$quote" ]; then
            if [ "$char" = "$quote" ]; then quote=""; else word+="$char"; fi
        else
            case "$char" in
                "'"|'"') quote="$char"; active=true ;;
                ' '|$'\t')
                    if [ "$active" = true ]; then GEO_CONTEXT_WORDS+=("$word"); word=""; active=false; fi ;;
                $'\n'|$'\r') return 1 ;;
                *) word+="$char"; active=true ;;
            esac
        fi
    done
    [ -z "$quote" ] || return 1
    if [ "$active" = true ]; then GEO_CONTEXT_WORDS+=("$word"); fi
}

geo_context_process() {
    local pid="$1" managed="$2" item dotted="" upper="" dotted_set=false upper_set=false root ns own_ns path entry check_entry host_inode view_inode
    [[ "$pid" =~ ^[1-9][0-9]*$ ]] || { geo_context_error "服务主进程 PID 无效"; return 1; }
    GEO_ASSET_BINARY=$(readlink -f "/proc/$pid/exe") || { geo_context_error "无法读取服务实际核心路径"; return 1; }
    [ "$GEO_ASSET_BINARY" = "$managed" ] || { geo_context_error "服务主进程并非当前管理的核心"; return 1; }
    GEO_ASSET_CWD=$(readlink -f "/proc/$pid/cwd") || { geo_context_error "无法读取服务实际工作目录"; return 1; }
    root=$(readlink -f "/proc/$pid/root") || { geo_context_error "无法读取服务根目录"; return 1; }
    ns=$(readlink "/proc/$pid/ns/mnt") || { geo_context_error "无法读取服务挂载命名空间"; return 1; }
    own_ns=$(readlink /proc/self/ns/mnt) || { geo_context_error "无法读取当前挂载命名空间"; return 1; }
    if [ "$root" != / ]; then
        geo_context_error "服务使用独立根目录，无法保证文件映射一致"
        return 1
    fi
    [ -r "/proc/$pid/environ" ] || { geo_context_error "无法读取服务进程环境"; return 1; }
    while IFS= read -r -d '' item; do
        case "$item" in
            xray.location.asset=*) dotted_set=true; dotted="${item#*=}" ;;
            XRAY_LOCATION_ASSET=*) upper_set=true; upper="${item#*=}" ;;
        esac
    done < "/proc/$pid/environ"
    GEO_ASSET_EXPLICIT=true
    if [ "$dotted_set" = true ]; then
        GEO_ASSET_PRIMARY=$(geo_context_absolute "$dotted" "$GEO_ASSET_CWD") || return 1
    elif [ "$upper_set" = true ]; then
        GEO_ASSET_PRIMARY=$(geo_context_absolute "$upper" "$GEO_ASSET_CWD") || return 1
    else
        GEO_ASSET_EXPLICIT=false
        GEO_ASSET_PRIMARY=$(dirname "$GEO_ASSET_BINARY")
    fi
    # PrivateTmp / ProtectSystem 可建立 namespace 而不改变 Geo 视图；
    # 比较目录和两个数据文件的实际 inode，允许这种常见服务加固。
    if [ "$ns" != "$own_ns" ]; then
        for path in "$GEO_ASSET_PRIMARY" "$(dirname "$GEO_ASSET_BINARY")" "$XRAY_GEO_DIR" /usr/share/xray /opt/share/xray; do
            for entry in "$path" "$path/geoip.dat" "$path/geosite.dat"; do
                check_entry="$entry"
                while true; do
                    host_inode=$(stat -L -c '%d:%i' "$check_entry" 2>/dev/null) || host_inode=""
                    view_inode=$(stat -L -c '%d:%i' "/proc/$pid/root$check_entry" 2>/dev/null) || view_inode=""
                    if [ -n "$host_inode" ] || [ -n "$view_inode" ]; then
                        if [ "$host_inode" != "$view_inode" ]; then
                            geo_context_error "服务挂载命名空间改变了 Geo 文件视图"
                            return 1
                        fi
                        break
                    fi
                    # 首次写入时目录可能尚不存在；确认最近已有祖先也共享，
                    # 防止 host /tmp 新目录实际落在服务的 PrivateTmp 之外。
                    if [ "$check_entry" = / ]; then
                        geo_context_error "无法确认 Geo 目录已有祖先的文件映射"
                        return 1
                    fi
                    check_entry="${check_entry%/*}"
                    [ -n "$check_entry" ] || check_entry=/
                done
            done
        done
    fi
}

geo_context_systemd_property() {
    systemctl show xray.service --property="$1" --value 2>/dev/null || {
        geo_context_error "读取服务属性 $1 失败"; return 1;
    }
}

geo_context_manager_safe() {
    local unit_dotted="$1" unit_upper="$2" manager line
    manager=$(systemctl show-environment 2>/dev/null) || {
        geo_context_error "无法读取 systemd manager 环境"; return 1;
    }
    while IFS= read -r line; do
        case "$line" in
            xray.location.asset=*)
                if [ "$unit_dotted" != true ]; then
                    geo_context_error "manager 定义 dotted 资产环境，但停止的服务没有明确覆盖"; return 1
                fi ;;
            XRAY_LOCATION_ASSET=*)
                if [ "$unit_dotted" != true ] && [ "$unit_upper" != true ]; then
                    geo_context_error "manager 定义了资产环境，但停止的服务没有明确覆盖"; return 1
                fi ;;
        esac
    done <<< "$manager"
}

geo_context_systemd() {
    local managed="$1" load pid value property exec_start environment="" item asset="" dotted="" upper="" dotted_set=false upper_set=false
    load=$(geo_context_systemd_property LoadState) || { geo_context_error "无法读取 systemd 服务配置"; return 1; }
    if [ "$load" = not-found ]; then geo_context_manager_safe false false; return $?; fi
    [ "$load" = loaded ] || { geo_context_error "systemd 服务未正确加载"; return 1; }
    for property in RootDirectory RootImage BindPaths BindReadOnlyPaths TemporaryFileSystem MountImages ExtensionImages ExtensionDirectories; do
        value=$(geo_context_systemd_property "$property") || return 1
        [ -z "$value" ] || { geo_context_error "服务包含 $property 文件映射"; return 1; }
    done
    pid=$(geo_context_systemd_property MainPID) || return 1
    if [[ "$pid" =~ ^[1-9][0-9]*$ ]]; then
        geo_context_process "$pid" "$managed"
        return $?
    fi
    if xray_service_is_active; then geo_context_error "运行服务没有可确认的主进程"; return 1; fi
    for property in EnvironmentFiles PassEnvironment UnsetEnvironment PAMName; do
        value=$(geo_context_systemd_property "$property") || return 1
        [ -z "$value" ] || { geo_context_error "停止的服务包含 $property，需先启动后读取实际环境"; return 1; }
    done
    exec_start=$(geo_context_systemd_property ExecStart) || return 1
    if [[ "$exec_start" =~ ^\{[[:space:]]path=([^[:space:]\;]+)[[:space:]]\; ]]; then
        value="${BASH_REMATCH[1]}"
    else
        geo_context_error "停止的服务不是可确认的直接核心启动命令"
        return 1
    fi
    value=$(readlink -f "$value") || { geo_context_error "无法解析服务 ExecStart 路径"; return 1; }
    [ "$value" = "$managed" ] || { geo_context_error "服务 ExecStart 指向其他核心或包装程序"; return 1; }
    GEO_ASSET_CWD=$(geo_context_systemd_property WorkingDirectory) || return 1
    [ -n "$GEO_ASSET_CWD" ] || GEO_ASSET_CWD=/
    [[ "$GEO_ASSET_CWD" = /* ]] || { geo_context_error "服务工作目录无法直接解析"; return 1; }
    environment=$(geo_context_systemd_property Environment) || return 1
    geo_context_words "$environment" || { geo_context_error "服务环境包含无法解析的转义"; return 1; }
    for item in "${GEO_CONTEXT_WORDS[@]}"; do
        case "$item" in
            xray.location.asset=*) dotted="${item#*=}"; dotted_set=true ;;
            XRAY_LOCATION_ASSET=*) upper="${item#*=}"; upper_set=true ;;
        esac
    done
    # manager 环境可能由 DefaultEnvironment / PassEnvironment 等不同来源组成；
    # 未被 unit 明确覆盖时不猜测它是否会传给下一次启动的进程。
    geo_context_manager_safe "$dotted_set" "$upper_set" || return 1
    if [ "$dotted_set" = true ]; then asset="$dotted"; else asset="$upper"; fi
    if [ "$dotted_set" = true ] || [ "$upper_set" = true ]; then
        case "$asset" in *'%'*) geo_context_error "服务资产目录包含延迟展开的 specifier"; return 1 ;; esac
        GEO_ASSET_EXPLICIT=true
        GEO_ASSET_PRIMARY=$(geo_context_absolute "$asset" "$GEO_ASSET_CWD") || return 1
    fi
    value=$(geo_context_systemd_property PrivateTmp) || return 1
    case "$value" in
        ''|no|false|0) ;;
        *)
            case "$GEO_ASSET_PRIMARY/" in /tmp/*|/var/tmp/*)
                geo_context_error "停止的服务在独立临时目录内加载资产"; return 1 ;;
            esac ;;
    esac
}

geo_context_openrc_stopped() {
    local path line actual expected
    # OpenRC 配置是 shell；只接受本脚本生成的服务及静态、无资产覆盖的全局配置。
    for path in /etc/conf.d/xray /etc/conf.d/xray.*; do
        [ ! -f "$path" ] || ! grep -Eq '^[[:space:]]*[^#[:space:]]' "$path" || {
            geo_context_error "停止的 OpenRC 服务有自定义 conf.d 配置"; return 1;
        }
    done
    for path in /etc/rc.conf /etc/rc.conf.d/*.conf /etc/profile.env; do
        [ -f "$path" ] || continue
        while IFS= read -r line || [ -n "$line" ]; do
            case "${line//[[:space:]]/}" in ''|'#'*) continue ;; esac
            if [[ "$line" == *XRAY_LOCATION_ASSET* || "$line" == *xray.location.asset* || "$line" == *rc_env_allow* ||
                  "$line" == *'$'* || "$line" == *$'\x60'* || "$line" == *';'* ||
                  "$line" == *'&'* || "$line" == *'|'* || "$line" == *'<'* || "$line" == *'>'* ||
                  "$line" == *'('* || "$line" == *')'* || "$line" == *'\'* ]]; then
                geo_context_error "停止的 OpenRC 服务存在动态或资产环境配置"
                return 1
            fi
            geo_context_words "$line" || return 1
            if [ "${GEO_CONTEXT_WORDS[0]:-}" = export ]; then GEO_CONTEXT_WORDS=("${GEO_CONTEXT_WORDS[@]:1}"); fi
            [[ "${GEO_CONTEXT_WORDS[0]:-}" =~ ^[A-Za-z_][A-Za-z_0-9]*= ]] || return 1
            if [ "${#GEO_CONTEXT_WORDS[@]}" -gt 1 ] && [[ "${GEO_CONTEXT_WORDS[1]}" != \#* ]]; then
                geo_context_error "停止的 OpenRC 全局配置不是静态赋值"; return 1
            fi
        done < "$path"
    done
    [ -z "${RC_RUNLEVEL+x}${RC_PATH+x}" ] || { geo_context_error "当前 OpenRC 调用环境非默认"; return 1; }
    actual=$(sed -e '/^[[:space:]]*#/d' -e '/^[[:space:]]*$/d' -e 's/^[[:space:]]*//' /etc/init.d/xray) || {
        geo_context_error "无法读取 OpenRC 服务文件"; return 1;
    }
    expected=$(cat <<EOF
name="Xray"
description="Xray service"
command="$XRAY_BINARY_PATH"
command_args="run -config $XRAY_CONFIG_PATH"
supervisor="supervise-daemon"
supervise_daemon_args="--respawn-max 0 --respawn-delay 5"
output_log="/var/log/xray/access.log"
error_log="/var/log/xray/error.log"
depend() {
need net
use dns logger
}
EOF
)
    [ "$actual" = "$expected" ] || { geo_context_error "停止的 OpenRC 服务已自定义，需先启动后读取实际环境"; return 1; }
}

resolve_xray_asset_context() {
    local managed pid path count=0
    managed=$(readlink -f "$XRAY_BINARY_PATH") || { geo_context_error "无法解析当前管理的核心路径"; return 1; }
    GEO_ASSET_BINARY="$managed"
    GEO_ASSET_CWD=/
    GEO_ASSET_PRIMARY=$(dirname "$managed")
    GEO_ASSET_EXPLICIT=false
    if [ "$OS_TYPE" = debian ]; then
        geo_context_systemd "$managed"
    elif [ "$OS_TYPE" = alpine ]; then
        if xray_service_is_active; then
            for path in /proc/[0-9]*/exe; do
                [ "$(readlink -f "$path" 2>/dev/null)" = "$managed" ] || continue
                pid="${path%/exe}"; pid="${pid##*/}"; count=$((count + 1))
            done
            [ "$count" -eq 1 ] || { geo_context_error "无法唯一识别运行的 OpenRC 核心进程"; return 1; }
            geo_context_process "$pid" "$managed"
        elif [ -f /etc/init.d/xray ]; then
            geo_context_openrc_stopped
        fi
    else
        geo_context_error "不支持的服务管理方式"
        return 1
    fi
}

download_geo_asset() {
    local manifest="$1" name="$2" destination="$3" tag expected actual url
    tag=$(printf '%s' "$manifest" | jq -er '.tag_name | select(type == "string")') || return 1
    [[ "$tag" =~ ^[A-Za-z0-9][A-Za-z0-9._-]{0,63}$ ]] || { error "Geo 发布版本无效"; return 1; }
    expected=$(printf '%s' "$manifest" | jq -er --arg name "$name" \
        '.assets[] | select(.name == $name) | .digest | select(type == "string")') || return 1
    [[ "$expected" =~ ^sha256:[0-9a-fA-F]{64}$ ]] || { error "$name 缺少有效 SHA256，保留旧数据"; return 1; }
    expected="${expected#sha256:}"
    url="https://github.com/Loyalsoldier/v2ray-rules-dat/releases/download/${tag}/${name}"
    curl -fsSL --max-time 180 "$url" -o "$destination" || { error "下载 $name 失败"; return 1; }
    [ -s "$destination" ] || { error "$name 下载结果为空"; return 1; }
    actual=$(sha256_file "$destination") || return 1
    [ "${actual,,}" = "${expected,,}" ] || { error "$name SHA256 校验失败，保留旧数据"; return 1; }
    chmod 644 "$destination"
}

resolve_geo_asset_file() {
    local name="$1" source path
    for source in "$GEO_ASSET_PRIMARY" "$XRAY_GEO_DIR" /usr/share/xray /opt/share/xray; do
        path="$source/$name"
        if [ -e "$path" ]; then
            [ -f "$path" ] || { error "Geo 路径不是普通文件: $path"; return 1; }
            readlink -f "$path"
            return $?
        fi
    done
    # 全部缺失时，显式资产目录优先；默认安装继续使用原来的 share 目录。
    if [ "$GEO_ASSET_EXPLICIT" = true ]; then source="$GEO_ASSET_PRIMARY"; else source="$XRAY_GEO_DIR"; fi
    path="$source/$name"
    if [ -L "$path" ]; then
        readlink -f "$path" || { error "无法解析 Geo 软链接: $path"; return 1; }
    else
        printf '%s\n' "$path"
    fi
}

resolve_xray_geo_targets() {
    resolve_xray_asset_context || return 1
    GEO_IP_PATH=$(resolve_geo_asset_file geoip.dat) || return 1
    GEO_SITE_PATH=$(resolve_geo_asset_file geosite.dat) || return 1
    if [ "$GEO_IP_PATH" = "$GEO_SITE_PATH" ]; then
        error "GeoIP 与 GeoSite 指向同一文件，未更新"
        return 1
    fi
}

prepare_geo_overlay() {
    local candidate="$1" primary source entry name resolved
    primary="${GEO_ASSET_PRIMARY:-}"
    if [ -z "$primary" ]; then
        primary=$(printenv xray.location.asset 2>/dev/null || true)
        [ -n "$primary" ] || primary="${XRAY_LOCATION_ASSET:-$(dirname "$XRAY_BINARY_PATH")}"
    fi
    for source in "$primary" "$XRAY_GEO_DIR" /usr/share/xray /opt/share/xray; do
        [ -d "$source" ] || continue
        for entry in "$source"/*; do
            [ -e "$entry" ] || continue
            name="${entry##*/}"
            case "$name" in geoip.dat|geosite.dat|.xrm-*) continue ;; esac
            [ ! -e "$candidate/$name" ] || continue
            # 附加数据只读引用；不把工具可执行文件复制进候选资产目录。
            if [ -d "$entry" ] || [ ! -x "$entry" ]; then
                resolved=$(readlink -f "$entry") || return 1
                ln -s "$resolved" "$candidate/$name" || return 1
            fi
        done
    done
}

validate_geo_candidate() {
    local candidate="$1" probe
    probe=$(mktemp) || return 1
    register_temp_file "$probe"
    printf '%s\n' '{"outbounds":[{"tag":"geo-check","protocol":"blackhole"}],"routing":{"rules":[{"ip":["geoip:private","geoip:cn"],"outboundTag":"geo-check"},{"domain":["geosite:cn"],"outboundTag":"geo-check"}]}}' > "$probe" || return 1
    prepare_geo_overlay "$candidate" || return 1
    validate_xray_config "$probe" "$candidate" || return 1
    if [ -f "$XRAY_CONFIG_PATH" ]; then
        validate_xray_config "$XRAY_CONFIG_PATH" "$candidate" || return 1
    fi
}

rollback_active_geo_update() {
    [ "${#ACTIVE_GEO_TRANSACTION[@]}" -gt 0 ] || return 0
    local backup="${ACTIVE_GEO_TRANSACTION[0]}" had_ip="${ACTIVE_GEO_TRANSACTION[1]}"
    local had_site="${ACTIVE_GEO_TRANSACTION[2]}" was_active="${ACTIVE_GEO_TRANSACTION[3]}"
    local restarting="${ACTIVE_GEO_TRANSACTION[4]}" failed=0
    local ip_path="${ACTIVE_GEO_TRANSACTION[5]}" site_path="${ACTIVE_GEO_TRANSACTION[6]}"
    if [ "$had_ip" = true ]; then
        atomic_replace_file "$backup/geoip.dat" "$ip_path" "$backup/geoip.dat" || failed=1
    else
        rm -f "$ip_path" || failed=1
    fi
    if [ "$had_site" = true ]; then
        atomic_replace_file "$backup/geosite.dat" "$site_path" "$backup/geosite.dat" || failed=1
    else
        rm -f "$site_path" || failed=1
    fi
    if [ "$failed" -eq 0 ] && [ "$restarting" = true ]; then
        if [ "$was_active" = true ]; then restart_xray || failed=1
        else stop_xray || failed=1; fi
    fi
    ACTIVE_GEO_TRANSACTION=()
    if [ "$failed" -ne 0 ]; then
        TEMP_FILES=("${TEMP_FILES[@]/$backup/}")
        error "恢复 Geo 数据或服务失败，旧数据备份保留在 $backup"
        return 1
    fi
}

perform_geo_update() {
    local candidate="$1" restart="$2" manifest backup had_ip=false had_site=false was_active=false path
    manifest=$(fetch_geo_release) || { error "获取 Geo 发布信息失败，保留旧数据"; return 1; }
    download_geo_asset "$manifest" geoip.dat "$candidate/geoip.dat" || return 1
    download_geo_asset "$manifest" geosite.dat "$candidate/geosite.dat" || return 1
    resolve_xray_geo_targets || return 1
    local ip_path="$GEO_IP_PATH" site_path="$GEO_SITE_PATH"
    if cmp -s "$candidate/geoip.dat" "$ip_path" && \
       cmp -s "$candidate/geosite.dat" "$site_path"; then
        success "Geo 数据没有变化，无需更新或重启"
        return 0
    fi
    validate_geo_candidate "$candidate" || return 1
    for path in "$ip_path" "$site_path"; do
        if [ ! -d "$(dirname "$path")" ]; then install -d -m 755 "$(dirname "$path")" || return 1; fi
    done
    backup=$(mktemp -d "$XRAY_GEO_DIR/.xrm-geo-backup.XXXXXX") || return 1
    register_temp_file "$backup"
    if [ -e "$ip_path" ]; then
        had_ip=true
        cp -p "$ip_path" "$backup/geoip.dat" || return 1
    fi
    if [ -e "$site_path" ]; then
        had_site=true
        cp -p "$site_path" "$backup/geosite.dat" || return 1
    fi
    if xray_service_is_active; then was_active=true; fi
    ACTIVE_GEO_TRANSACTION=("$backup" "$had_ip" "$had_site" "$was_active" false "$ip_path" "$site_path")
    local ip_reference="$candidate/geoip.dat" site_reference="$candidate/geosite.dat"
    [ "$had_ip" != true ] || ip_reference="$ip_path"
    [ "$had_site" != true ] || site_reference="$site_path"
    if ! atomic_replace_file "$candidate/geoip.dat" "$ip_path" "$ip_reference" || \
       ! atomic_replace_file "$candidate/geosite.dat" "$site_path" "$site_reference"; then
        rollback_active_geo_update || return 1
        error "写入 Geo 数据失败，已恢复原数据"
        return 1
    fi
    if [ "$restart" = true ] && [ "$was_active" = true ]; then
        ACTIVE_GEO_TRANSACTION[4]=true
        if ! restart_xray; then
            rollback_active_geo_update || return 1
            error "新 Geo 数据启动失败，已恢复原数据和服务"
            return 1
        fi
    fi
    ACTIVE_GEO_TRANSACTION=()
    rm -rf -- "$backup"
    success "GeoIP / GeoSite 数据已校验并更新"
    info "GeoIP: $ip_path\nGeoSite: $site_path"
}

_update_geo_data() {
    local restart="${1:-false}" candidate result
    case "$restart" in true|false) ;; *) error "无效的 Geo 更新模式"; return 1 ;; esac
    [ -x "$XRAY_BINARY_PATH" ] || { error "请先安装 Xray 核心"; return 1; }
    if [ ! -d "$XRAY_GEO_DIR" ]; then
        install -d -m 755 "$XRAY_GEO_DIR" || return 1
    fi
    candidate=$(mktemp -d "$XRAY_GEO_DIR/.xrm-geo-candidate.XXXXXX") || return 1
    register_temp_file "$candidate"
    info "正在检查并校验 GeoIP / GeoSite 数据..."
    if perform_geo_update "$candidate" "$restart"; then result=0; else result=$?; fi
    rm -rf -- "$candidate"
    return "$result"
}

update_geo_data() {
    with_xrm_lock _update_geo_data "$@"
}

# 下载、校验并准备候选核心；此阶段不修改已安装核心或服务。
prepare_xray_binary() {
    local version="$1" destination="$2" binary_version
    
    # 检测架构
    local arch
    arch=$(uname -m)
    case "$arch" in
        x86_64)  arch="64" ;;
        aarch64) arch="arm64-v8a" ;;
        armv7l)  arch="arm32-v7a" ;;
        *) 
            error "不支持的架构: $arch"
            return 1
            ;;
    esac

    info "检测到架构: $arch"
    
    # 创建临时目录
    local tmpdir
    tmpdir=$(mktemp -d) || {
        error "创建临时目录失败"
        return 1
    }
    register_temp_file "$tmpdir"

    # 下载 - 使用 curl
    local url="https://github.com/XTLS/Xray-core/releases/download/v${version}/Xray-linux-${arch}.zip"
    info "正在下载 Xray-core v${version} ..."
    
    if ! curl -fL --progress-bar --max-time 300 -o "$tmpdir/xray.zip" "$url"; then
        error "下载失败: $url"
        rm -rf "$tmpdir"
        return 1
    fi

    verify_release_asset_digest "$version" "Xray-linux-${arch}.zip" "$tmpdir/xray.zip" || {
        rm -rf "$tmpdir"
        return 1
    }
    
    # 验证下载的文件大小
    local filesize
    filesize=$(stat -c%s "$tmpdir/xray.zip" 2>/dev/null || stat -f%z "$tmpdir/xray.zip" 2>/dev/null || wc -c < "$tmpdir/xray.zip" 2>/dev/null || echo 0)
    
    if [ "$filesize" -lt 1000000 ]; then
        error "下载的文件太小 ($filesize 字节)，可能下载失败"
        info "文件内容前10行:"
        head -n 10 "$tmpdir/xray.zip" 2>/dev/null || true
        info ""
        info "如果上面显示 HTML 内容，说明遇到了 GitHub 的防火墙或限制"
        info "建议: 1) 使用代理 2) 手动下载后再安装"
        rm -rf "$tmpdir"
        return 1
    fi
    
    info "下载完成，文件大小: $((filesize / 1024 / 1024)) MB"

    # 解压
    info "正在解压..."
    if ! unzip -qo "$tmpdir/xray.zip" -d "$tmpdir" 2>&1; then
        error "解压失败"
        info "尝试使用 -t 参数测试压缩包:"
        unzip -t "$tmpdir/xray.zip" 2>&1 || true
        rm -rf "$tmpdir"
        return 1
    fi

    # 检查解压出的文件
    if [ ! -f "$tmpdir/xray" ]; then
        error "解压后未找到 xray 可执行文件"
        rm -rf "$tmpdir"
        return 1
    fi

    chmod 755 "$tmpdir/xray" || return 1
    binary_version=$("$tmpdir/xray" version 2>/dev/null) || {
        error "下载的核心无法执行，未替换现有核心"
        return 1
    }
    binary_version=$(printf '%s\n' "$binary_version" | head -n 1 | awk '{print $2}' | sed 's/^v//')
    if [ "$binary_version" != "$version" ]; then
        error "下载的核心版本与目标 v${version} 不一致，未替换现有核心"
        return 1
    fi
    install -m 755 "$tmpdir/xray" "$destination" || {
        error "准备候选核心失败"
        rm -rf "$tmpdir"
        return 1
    }
    rm -rf "$tmpdir"
}

# --- 下载并安装 Xray 核心（初次安装入口）---
download_and_install_xray() {
    local version="$1" candidate binary_target="$XRAY_BINARY_PATH"
    if [ -L "$binary_target" ]; then binary_target=$(readlink -f "$binary_target") || return 1; fi
    mkdir -p "$(dirname "$binary_target")" /usr/local/etc/xray /usr/local/share/xray || return 1
    candidate=$(mktemp "$(dirname "$binary_target")/.xrm-core-candidate.XXXXXX") || return 1
    register_temp_file "$candidate"
    prepare_xray_binary "$version" "$candidate" || return 1
    info "正在安装 Xray 到 $XRAY_BINARY_PATH ..."
    local reference="$candidate"
    [ ! -e "$XRAY_BINARY_PATH" ] || reference="$XRAY_BINARY_PATH"
    atomic_replace_file "$candidate" "$XRAY_BINARY_PATH" "$reference" || {
        error "安装二进制文件失败"
        return 1
    }
    rm -f "$candidate"
    success "Xray v${version} 已安装到 $XRAY_BINARY_PATH"
}

# 普通失败和退出信号共用恢复流程；登记状态先于停服与替换操作。
rollback_active_xray_upgrade() {
    [ "${#ACTIVE_XRAY_UPGRADE[@]}" -gt 0 ] || return 0
    local backup="${ACTIVE_XRAY_UPGRADE[0]}" was_active="${ACTIVE_XRAY_UPGRADE[1]}"
    local service_touched="${ACTIVE_XRAY_UPGRADE[2]}" binary_replaced="${ACTIVE_XRAY_UPGRADE[3]}" failed=0
    if [ "$binary_replaced" = true ]; then
        atomic_replace_file "$backup" "$XRAY_BINARY_PATH" "$backup" || failed=1
    fi
    if [ "$failed" -eq 0 ] && [ "$service_touched" = true ]; then
        if [ "$was_active" = true ]; then restart_xray || failed=1
        else stop_xray || failed=1; fi
    fi
    ACTIVE_XRAY_UPGRADE=()
    if [ "$failed" -ne 0 ]; then
        TEMP_FILES=("${TEMP_FILES[@]/$backup/}")
        error "原核心或服务恢复未完成，备份保留在 $backup"
        return 1
    fi
}

# --- 升级至最新正式版（已有服务在成功后自动恢复运行）---
upgrade_xray() {
    with_xrm_lock _upgrade_xray "$@"
}

_upgrade_xray() {
    local current_version target_version confirm backup candidate binary_target="$XRAY_BINARY_PATH" service_was_active=false
    if [ ! -x "$XRAY_BINARY_PATH" ]; then
        error "请先安装 Xray"
        return 1
    fi
    current_version=$("$XRAY_BINARY_PATH" version 2>/dev/null | head -n 1 | awk '{print $2}' | sed 's/^v//')
    if ! [[ "$current_version" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
        error "无法识别当前核心版本"
        return 1
    fi
    target_version=$(get_latest_xray_version) || return 1
    info "当前版本: v${current_version}；最新正式版: v${target_version}"
    if jq -en --arg current "$current_version" --arg target "$target_version" \
        '($current | split(".") | map(tonumber)) >= ($target | split(".") | map(tonumber))' >/dev/null; then
        success "当前已是最新正式版或更高版本，无需升级"
        return 0
    fi
    read -r -p "确认升级到 v${target_version}? [Y/n]: " confirm || return 1
    if [[ "$confirm" =~ ^[Nn]$ ]]; then
        info "已取消升级"
        return 0
    fi
    # 与实际核心放在同一目录，保留 Xray 对可执行目录内资产的查找行为。
    if [ -L "$binary_target" ]; then binary_target=$(readlink -f "$binary_target") || return 1; fi
    candidate=$(mktemp "$(dirname "$binary_target")/.xrm-core-candidate.XXXXXX") || return 1
    register_temp_file "$candidate"
    prepare_xray_binary "$target_version" "$candidate" || return 1
    if [ -f "$XRAY_CONFIG_PATH" ] && ! validate_xray_config "$XRAY_CONFIG_PATH" "" "$candidate"; then
        error "新核心配置检查失败，现有核心和服务未修改"
        return 1
    fi
    backup=$(mktemp "$(dirname "$binary_target")/.xrm-core-backup.XXXXXX") || return 1
    register_temp_file "$backup"
    cp -p "$XRAY_BINARY_PATH" "$backup" || { error "备份核心失败"; return 1; }

    if xray_service_is_active; then service_was_active=true; fi
    ACTIVE_XRAY_UPGRADE=("$backup" "$service_was_active" false false)
    if [ "$service_was_active" = true ]; then
        ACTIVE_XRAY_UPGRADE[2]=true
        if ! stop_xray; then
            rollback_active_xray_upgrade || return 1
            error "停止服务失败，已取消升级并恢复原服务状态"
            return 1
        fi
    fi
    ACTIVE_XRAY_UPGRADE[3]=true
    if ! atomic_replace_file "$candidate" "$XRAY_BINARY_PATH" "$XRAY_BINARY_PATH"; then
        rollback_active_xray_upgrade || return 1
        error "升级失败，已恢复原核心"
        return 1
    fi
    if [ "$service_was_active" = true ] && ! restart_xray; then
        rollback_active_xray_upgrade || return 1
        error "新核心启动失败，已恢复原核心及服务"
        return 1
    fi
    ACTIVE_XRAY_UPGRADE=()
    rm -f "$backup" "$candidate"
    success "Xray 已升级到 v${target_version}"
    if [ "$service_was_active" = false ]; then info "服务原先未运行，升级后保持停止"; fi
}

# --- 获取服务器地址（IP 或域名）---
get_server_address() {
    if [ -n "$SERVER_IP" ]; then
        # 如果已经设置过，询问是否继续使用
        read -r -p "继续使用之前的地址 ($SERVER_IP)? [Y/n]: " reuse || return 1
        if [[ ! "$reuse" =~ ^[Nn]$ ]]; then
            return 0
        fi
    fi
    
    info "正在获取出口 IP"
    local detected_ip
    detected_ip=$(curl -s4 --max-time 3 ip.sb 2>/dev/null || curl -s4 --max-time 3 ifconfig.me 2>/dev/null || echo "")
    
    if [ -z "$detected_ip" ]; then
        detected_ip=$(curl -s6 --max-time 3 ip.sb 2>/dev/null || curl -s6 --max-time 3 ifconfig.me 2>/dev/null || echo "")
    fi
    
    if [ -n "$detected_ip" ]; then
        info "检测到服务器 IP: $detected_ip"
    fi
    
    read -r -p "使用 1)IP , 2)域名  [1/2]: " use_domain || return 1
    
    if [ "$use_domain" = "2" ]; then
        read -r -p "请输入域名: " DOMAIN || return 1
        
        if [ -z "$DOMAIN" ]; then
            error "域名不能为空"
            return 1
        fi
        
        SERVER_IP="$DOMAIN"
        success "使用域名: $SERVER_IP"
    else
        if [ -n "$detected_ip" ]; then
            read -r -p "使用检测到的 IP ($detected_ip)? [Y/n]: " use_detected || return 1
            if [[ ! "$use_detected" =~ ^[Nn]$ ]]; then
                SERVER_IP="$detected_ip"
            else
                read -r -p "请输入服务器 IP: " SERVER_IP || return 1
                if [ -z "$SERVER_IP" ]; then
                    error "IP 地址不能为空"
                    return 1
                fi
            fi
        else
            read -r -p "请输入服务器 IP: " SERVER_IP || return 1
            if [ -z "$SERVER_IP" ]; then
                error "IP 地址不能为空"
                return 1
            fi
        fi
        success "使用 IP: $SERVER_IP"
    fi
}

# --- 选择使用 IP 还是域名 ---
get_domain() {
    read -r -p "使用 1)IP , 2)域名  [1/2]: " use_domain || return 1
    
    if [ "$use_domain" = "2" ]; then
        read -r -p "请输入域名: " DOMAIN || return 1
        
        if [ -z "$DOMAIN" ]; then
            error "域名不能为空"
            exit 1
        fi

        SERVER_IP="$DOMAIN"
        success "使用域名: $SERVER_IP"
    else
        success "使用 IP: $SERVER_IP"
    fi
}

# --- 创建系统服务 ---
create_service() {
    # 根据操作系统类型创建对应服务
    if [ "$OS_TYPE" = "debian" ]; then
        create_systemd_service
    elif [ "$OS_TYPE" = "alpine" ]; then
        create_openrc_service
    else
        error "未知的操作系统: $OS_TYPE"
        return 1
    fi
}

# --- 创建 systemd 服务 ---
create_systemd_service() {
    if [ -f /etc/systemd/system/xray.service ] || [ -L /etc/systemd/system/xray.service ]; then
        success "systemd 服务已存在"
        return 0
    fi

    # 发行版安装的 unit 可能位于 /lib、/usr/lib 或 /run；不创建覆盖它的 /etc unit。
    if systemctl cat xray.service >/dev/null 2>&1; then
        success "systemd 服务已存在，保留当前 unit 配置"
        return 0
    fi

    info "正在创建 systemd 服务..."

    local service_file
    service_file=$(mktemp /etc/systemd/system/xray.service.tmp.XXXXXX) || {
        error "创建 systemd 临时服务文件失败"
        return 1
    }
    register_temp_file "$service_file"

    cat > "$service_file" <<'EOF'
[Unit]
Description=Xray Service
Documentation=https://github.com/xtls
After=network.target nss-lookup.target

[Service]
Type=simple
User=root
CapabilityBoundingSet=CAP_NET_ADMIN CAP_NET_BIND_SERVICE
AmbientCapabilities=CAP_NET_ADMIN CAP_NET_BIND_SERVICE
NoNewPrivileges=true
ExecStart=/usr/local/bin/xray run -config /usr/local/etc/xray/config.json
Restart=on-failure
RestartPreventExitStatus=23
LimitNPROC=10000
LimitNOFILE=1000000

[Install]
WantedBy=multi-user.target
EOF

    if ! chmod 644 "$service_file" || ! mv -f "$service_file" /etc/systemd/system/xray.service || \
       ! systemctl daemon-reload || ! systemctl enable xray; then
        rm -f "$service_file"
        error "创建或启用 systemd 服务失败"
        return 1
    fi
    
    success "systemd 服务已创建并设置为开机自启"
}

# --- 创建 OpenRC 服务 ---
create_openrc_service() {
    if [ -x /etc/init.d/xray ]; then
        success "OpenRC 服务已存在"
        return 0
    fi

    info "正在创建 OpenRC 服务..."
    
    # 创建日志目录
    mkdir -p /var/log/xray || {
        error "创建 Xray 日志目录失败"
        return 1
    }

    local service_file
    service_file=$(mktemp /etc/init.d/xray.tmp.XXXXXX) || {
        error "创建 OpenRC 临时服务文件失败"
        return 1
    }
    register_temp_file "$service_file"

    cat > "$service_file" <<'EOF'
#!/sbin/openrc-run
name="Xray"
description="Xray service"

command="/usr/local/bin/xray"
command_args="run -config /usr/local/etc/xray/config.json"
supervisor="supervise-daemon"
supervise_daemon_args="--respawn-max 0 --respawn-delay 5"
output_log="/var/log/xray/access.log"
error_log="/var/log/xray/error.log"

depend() {
    need net
    use dns logger
}
EOF

    if ! chmod 755 "$service_file" || ! mv -f "$service_file" /etc/init.d/xray || \
       ! rc-update add xray default; then
        rm -f "$service_file"
        error "创建或启用 OpenRC 服务失败"
        return 1
    fi
    
    success "OpenRC 服务已创建并设置为开机自启"
}

# --- Geo 定时更新：只管理带本脚本标记的 timer / root crontab 条目 ---
geo_schedule_file_owned() {
    [ -f "$1" ] && grep -Fxq '# xrm-managed-geo-update' "$1"
}

read_geo_root_crontab() {
    local target="$1" errors
    errors=$(mktemp) || return 1
    register_temp_file "$errors"
    if ! LC_ALL=C crontab -u root -l > "$target" 2> "$errors"; then
        if grep -Eq 'no crontab for|No such file or directory' "$errors"; then
            : > "$target"
        else
            error "无法读取 root crontab，未修改定时任务"
            return 1
        fi
    fi
}

# 调度备份同时保留链接本身和目标内容，关闭后也能恢复原来的 unit 布局。
backup_geo_schedule_unit() {
    local path="$1" backup="$2"
    cp -pL "$path" "$backup" || return 1
    if [ -L "$path" ]; then readlink "$path" > "$backup.link" || return 1; fi
}

restore_geo_schedule_unit() {
    local backup="$1" path="$2" link
    if [ -f "$backup" ]; then
        if [ -f "$backup.link" ] && [ ! -L "$path" ]; then
            link=$(cat "$backup.link") || return 1
            ln -s "$link" "$path" || return 1
        fi
        atomic_replace_file "$backup" "$path" "$backup"
    else
        rm -f "$path"
    fi
}

geo_crond_is_enabled() {
    rc-update show default 2>/dev/null | grep -Eq '^[[:space:]]*crond[[:space:]]'
}

# 所有备份完成后登记；调用者必须在首次修改正式文件或服务状态之前调用。
begin_geo_schedule_transaction() {
    local work="$1" operation="$2" was_enabled=false was_active=false path name
    if [ "$OS_TYPE" = debian ]; then
        for name in service timer; do
            path="/etc/systemd/system/xrm-geo-update.$name"
            if { [ -e "$path" ] || [ -L "$path" ]; } && ! geo_schedule_file_owned "$path"; then
                if [ "$operation" = enable ]; then
                    error "存在同名非本脚本定时配置，未覆盖: $path"
                    return 1
                fi
                continue
            fi
            if [ "$operation" = enable ] || geo_schedule_file_owned "$path"; then
                : > "$work/manage.$name" || return 1
                [ ! -f "$path" ] || backup_geo_schedule_unit "$path" "$work/old.$name" || return 1
            fi
        done
        if [ -f "$work/manage.timer" ]; then
            if systemctl is-enabled --quiet xrm-geo-update.timer 2>/dev/null; then was_enabled=true; fi
            if systemctl is-active --quiet xrm-geo-update.timer 2>/dev/null; then was_active=true; fi
        fi
    elif [ "$OS_TYPE" = alpine ]; then
        read_geo_root_crontab "$work/old.cron" || return 1
        if geo_crond_is_enabled; then was_enabled=true; fi
        if rc-service crond status >/dev/null 2>&1; then was_active=true; fi
    else
        error "不支持的操作系统: $OS_TYPE"
        return 1
    fi
    ACTIVE_GEO_SCHEDULE=("$OS_TYPE" "$work" "$was_enabled" "$was_active" "$operation")
}

rollback_active_geo_schedule() {
    [ "${#ACTIVE_GEO_SCHEDULE[@]}" -gt 0 ] || return 0
    local platform="${ACTIVE_GEO_SCHEDULE[0]}" work="${ACTIVE_GEO_SCHEDULE[1]}"
    local was_enabled="${ACTIVE_GEO_SCHEDULE[2]}" was_active="${ACTIVE_GEO_SCHEDULE[3]}"
    local operation="${ACTIVE_GEO_SCHEDULE[4]}" failed=0 name
    if [ "$platform" = debian ]; then
        for name in service timer; do
            if [ -f "$work/manage.$name" ]; then
                restore_geo_schedule_unit "$work/old.$name" "/etc/systemd/system/xrm-geo-update.$name" || failed=1
            fi
        done
        if [ -f "$work/manage.service" ] || [ -f "$work/manage.timer" ]; then
            systemctl daemon-reload || failed=1
        fi
        if [ -f "$work/manage.timer" ]; then
            if [ "$was_enabled" = true ]; then
                systemctl enable xrm-geo-update.timer || failed=1
            elif ! systemctl disable xrm-geo-update.timer >/dev/null 2>&1; then
                # 首次启用失败后 unit 可能已移除；确认未启用即可。
                if systemctl is-enabled --quiet xrm-geo-update.timer 2>/dev/null; then failed=1; fi
            fi
            if [ "$was_active" = true ]; then
                systemctl restart xrm-geo-update.timer || failed=1
            elif ! systemctl stop xrm-geo-update.timer >/dev/null 2>&1; then
                if systemctl is-active --quiet xrm-geo-update.timer 2>/dev/null; then failed=1; fi
            fi
        fi
    elif [ "$platform" = alpine ]; then
        crontab -u root "$work/old.cron" || failed=1
        # 关闭计划不管理共享的 crond；仅撤销启用计划期间的服务变更。
        if [ "$operation" = enable ]; then
            if [ "$was_enabled" = true ]; then
                if ! geo_crond_is_enabled; then rc-update add crond default || failed=1; fi
            elif geo_crond_is_enabled; then
                rc-update del crond default || failed=1
            fi
            if [ "$was_active" = true ]; then
                if ! rc-service crond status >/dev/null 2>&1; then rc-service crond start 9>&- || failed=1; fi
            elif rc-service crond status >/dev/null 2>&1; then
                rc-service crond stop 9>&- || failed=1
            fi
        fi
    else
        failed=1
    fi
    ACTIVE_GEO_SCHEDULE=()
    if [ "$failed" -ne 0 ]; then
        TEMP_FILES=("${TEMP_FILES[@]/$work/}")
        error "原 Geo 定时任务恢复未完成，备份保留在 $work"
        return 1
    fi
}

enable_geo_schedule() {
    with_xrm_lock _enable_geo_schedule "$@"
}

_enable_geo_schedule() {
    local frequency="${1:-weekly}" calendar cron_time version comparison
    case "$frequency" in
        daily) calendar='*-*-* 04:00:00'; cron_time='0 4 * * *' ;;
        weekly) calendar='Sun *-*-* 04:00:00'; cron_time='0 4 * * 0' ;;
        *) error "不支持的 Geo 更新频率: $frequency"; return 1 ;;
    esac
    if [ ! -x /usr/local/bin/xrm ] || ! version=$(read_script_version /usr/local/bin/xrm); then
        error "请先将全局命令 xrm 更新到 v1.1.0 或更高版本，再启用定时更新"
        return 1
    fi
    comparison=$(compare_script_versions "$version" 1.1.0) || return 1
    if [ "$comparison" -lt 0 ]; then
        error "已安装的 xrm 为 v${version}，请先更新到 v1.1.0 或更高版本"
        return 1
    fi

    local work
    work=$(mktemp -d) || return 1
    register_temp_file "$work"
    if [ "$OS_TYPE" = debian ]; then
        local service=/etc/systemd/system/xrm-geo-update.service
        local timer=/etc/systemd/system/xrm-geo-update.timer
        cat > "$work/new.service" <<'EOF' || return 1
# xrm-managed-geo-update
[Unit]
Description=Xray GeoIP and GeoSite update (xrm)
Wants=network-online.target
After=network-online.target

[Service]
Type=oneshot
Environment=PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
ExecStart=/usr/local/bin/xrm --update-geo
TimeoutStartSec=10min
EOF
        cat > "$work/new.timer" <<EOF || return 1
# xrm-managed-geo-update
[Unit]
Description=Scheduled Xray GeoIP and GeoSite update (xrm)

[Timer]
OnCalendar=$calendar
Persistent=true
Unit=xrm-geo-update.service

[Install]
WantedBy=timers.target
EOF
        begin_geo_schedule_transaction "$work" enable || return 1
        if ! atomic_replace_file "$work/new.service" "$service" || \
           ! atomic_replace_file "$work/new.timer" "$timer" || \
           { [ ! -f "$work/old.service" ] && ! chmod 644 "$service"; } || \
           { [ ! -f "$work/old.timer" ] && ! chmod 644 "$timer"; } || \
           ! systemctl daemon-reload || ! systemctl enable xrm-geo-update.timer || \
           ! systemctl restart xrm-geo-update.timer; then
            rollback_active_geo_schedule || return 1
            error "定时任务启用失败，已恢复原任务配置"
            return 1
        fi
    elif [ "$OS_TYPE" = alpine ]; then
        command -v crontab >/dev/null 2>&1 || { error "未找到 crontab，请先安装 Alpine cron 服务"; return 1; }
        begin_geo_schedule_transaction "$work" enable || return 1
        if ! awk '$0 !~ / # xrm-managed-geo-update$/ {print}' "$work/old.cron" > "$work/new.cron" || \
           ! printf '%s PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin /usr/local/bin/xrm --update-geo >> /var/log/xrm-geo-update.log 2>&1 # xrm-managed-geo-update\n' \
            "$cron_time" >> "$work/new.cron"; then
            rollback_active_geo_schedule || return 1
            return 1
        fi
        if ! crontab -u root "$work/new.cron" || ! rc-update add crond default || \
           { [ "${ACTIVE_GEO_SCHEDULE[3]}" != true ] && ! rc-service crond start 9>&-; }; then
            rollback_active_geo_schedule || return 1
            error "无法启用 Geo 定时任务，已恢复原任务配置"
            return 1
        fi
    else
        error "不支持的操作系统: $OS_TYPE"
        return 1
    fi
    ACTIVE_GEO_SCHEDULE=()
    rm -rf -- "$work"
    if [ "$frequency" = weekly ]; then
        success "已启用 Geo 每周更新：周日 04:00（服务器本地时区）"
    else
        success "已启用 Geo 每日更新：04:00（服务器本地时区）"
    fi
}

disable_geo_schedule() {
    with_xrm_lock _disable_geo_schedule "$@"
}

_disable_geo_schedule() {
    local work changed=false failed=false
    work=$(mktemp -d) || return 1
    register_temp_file "$work"
    if [ "$OS_TYPE" = debian ]; then
        local service=/etc/systemd/system/xrm-geo-update.service
        local timer=/etc/systemd/system/xrm-geo-update.timer
        begin_geo_schedule_transaction "$work" disable || return 1
        if [ -f "$work/manage.timer" ]; then
            if ! systemctl disable --now xrm-geo-update.timer || ! rm -f "$timer"; then failed=true; fi
            changed=true
        fi
        if [ "$failed" = false ] && [ -f "$work/manage.service" ]; then
            if ! systemctl stop xrm-geo-update.service || ! rm -f "$service"; then failed=true; fi
            changed=true
        fi
        if [ "$failed" = false ] && [ "$changed" = true ]; then
            systemctl daemon-reload || failed=true
        fi
    elif [ "$OS_TYPE" = alpine ]; then
        if command -v crontab >/dev/null 2>&1; then
            begin_geo_schedule_transaction "$work" disable || return 1
            if ! awk '$0 !~ / # xrm-managed-geo-update$/ {print}' "$work/old.cron" > "$work/new.cron"; then
                failed=true
            elif ! cmp -s "$work/old.cron" "$work/new.cron"; then
                crontab -u root "$work/new.cron" || failed=true
            fi
        fi
    else
        error "不支持的操作系统: $OS_TYPE"
        return 1
    fi
    if [ "$failed" = true ]; then
        rollback_active_geo_schedule || return 1
        error "关闭 Geo 定时任务失败，已恢复原任务配置"
        return 1
    fi
    ACTIVE_GEO_SCHEDULE=()
    rm -rf -- "$work"
    success "Geo 定时更新已关闭"
}

show_geo_schedule() {
    local schedule="" enabled=false
    if [ "$OS_TYPE" = debian ]; then
        if geo_schedule_file_owned /etc/systemd/system/xrm-geo-update.timer; then
            schedule=$(sed -n 's/^OnCalendar=//p' /etc/systemd/system/xrm-geo-update.timer)
            if systemctl is-enabled --quiet xrm-geo-update.timer && systemctl is-active --quiet xrm-geo-update.timer; then
                enabled=true
            fi
        fi
    elif [ "$OS_TYPE" = alpine ]; then
        if command -v crontab >/dev/null 2>&1; then
            local current
            current=$(mktemp) || return 1
            register_temp_file "$current"
            read_geo_root_crontab "$current" || return 1
            schedule=$(awk '/ # xrm-managed-geo-update$/ {print $1" "$2" "$3" "$4" "$5; exit}' "$current")
            if [ -n "$schedule" ] && rc-service crond status >/dev/null 2>&1; then enabled=true; fi
        fi
    fi
    case "$schedule" in
        'Sun *-*-* 04:00:00'|'0 4 * * 0') info "Geo 更新计划：每周日 04:00（服务器本地时区）" ;;
        '*-*-* 04:00:00'|'0 4 * * *') info "Geo 更新计划：每日 04:00（服务器本地时区）" ;;
        '') info "Geo 定时更新：未启用"; return 0 ;;
        *) info "Geo 更新计划已配置（服务器本地时区）" ;;
    esac
    if [ "$enabled" = true ]; then
        info "定时任务状态：已启用"
        if [ "$OS_TYPE" = debian ]; then systemctl list-timers --all --no-pager xrm-geo-update.timer || true; fi
    else
        info "定时任务状态：未启用或调度服务未运行"
    fi
}

manage_geo_data() {
    local choice
    while true; do
        echo -e "\n${cyan}=== 更新 Geo 数据 ===${none}\n"
        show_geo_schedule || return 1
        echo "1) 手动更新"
        echo "2) 每周更新（周日 04:00）"
        echo "3) 每日更新（04:00）"
        echo "4) 关闭自动更新"
        echo "0) 返回"
        read -r -p "请选择操作 [0-4]: " choice || return 1
        case "$choice" in
            1) update_geo_data true ;;
            2) enable_geo_schedule weekly ;;
            3) enable_geo_schedule daily ;;
            4) disable_geo_schedule ;;
            0) return 0 ;;
            *) error "无效的选择" ;;
        esac
    done
}

# --- 初始化配置文件 ---
init_config() {
    # 检查配置文件是否已存在
    if [ -f "$XRAY_CONFIG_PATH" ]; then
        success "保留已有配置文件: $XRAY_CONFIG_PATH"
    else
        info "正在创建初始配置文件..."

        mkdir -p "$(dirname "$XRAY_CONFIG_PATH")"

        jq -n '{
            "log": {
                "loglevel": "none"
            },
            "inbounds": [],
            "outbounds": [
                {
                    "tag": "direct",
                    "protocol": "freedom"
                },
                {
                    "tag": "block",
                    "protocol": "blackhole"
                }
            ],
            "routing": {
                "domainStrategy": "IPIfNonMatch",
                "rules": [
                    {
                        "ip": ["geoip:private"],
                        "outboundTag": "block"
                    },
                    {
                        "ip": ["geoip:cn"],
                        "outboundTag": "block"
                    }
                ]
            }
        }' > "$XRAY_CONFIG_PATH"

        if [ $? -eq 0 ]; then
            success "配置文件已创建: $XRAY_CONFIG_PATH"
        else
            error "配置文件创建失败"
            return 1
        fi

    fi

    # 初始化 YAML 节点文件
    if [ ! -f "$YAML_NODES_FILE" ]; then
        cat > "$YAML_NODES_FILE" << 'EOF'
# Clash 节点列表：复制节点到现有 YAML 的 proxies 部分
# 客户端字段与 URI 格式按用户要求保留，兼容性需在客户端自行验证

EOF
        success "YAML 节点文件已创建: $YAML_NODES_FILE"
    fi

    # 初始化节点元数据文件
    if [ ! -f "$NODES_META_FILE" ]; then
        echo '{"nodes":[]}' > "$NODES_META_FILE"
        success "节点元数据文件已创建: $NODES_META_FILE"
    fi
}

# --- 初始化/补齐路由策略（仅执行一次）---
ensure_routing_policy() {
    if [ ! -f "$XRAY_CONFIG_PATH" ]; then
        error "配置文件不存在: $XRAY_CONFIG_PATH"
        return 1
    fi

    # 已存在 routing 则不覆盖，避免改动用户自定义分流。
    if jq -e '.routing != null' "$XRAY_CONFIG_PATH" >/dev/null 2>&1; then
        return 0
    fi

    local temp
    temp=$(mktemp) || return 1
    register_temp_file "$temp"

    jq '.routing = {
           "domainStrategy": "IPIfNonMatch",
           "rules": [
               {
                   "ip": ["geoip:private"],
                   "outboundTag": "block"
               },
               {
                   "ip": ["geoip:cn"],
                   "outboundTag": "block"
               }
           ]
       }' "$XRAY_CONFIG_PATH" > "$temp" &&
        validate_xray_config "$temp" && atomic_replace_file "$temp" "$XRAY_CONFIG_PATH"

    if [ $? -eq 0 ]; then
        success "已初始化路由策略（禁止回国流量）"
        return 0
    else
        error "初始化路由策略失败"
        rm -f "$temp"
        return 1
    fi
}

# --- 保存节点元数据 ---
save_node_meta() {
    local tag="$1"
    local share_link="$2"
    local yaml_config="$3"
    # client_config 是本脚本的元数据，不是 Xray 配置字段。
    local client_config="${4:-null}"
    
    # 确保元数据文件存在
    if [ ! -f "$NODES_META_FILE" ]; then
        echo '{"nodes":[]}' > "$NODES_META_FILE"
    fi
    
    local temp
    temp=$(mktemp) || {
        error "创建临时文件失败"
        return 1
    }
    register_temp_file "$temp"
    
    jq --arg tag "$tag" \
       --arg link "$share_link" \
       --arg yaml "$yaml_config" \
       --argjson client "$client_config" \
       --arg time "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
       '.nodes += [{
           "tag": $tag,
           "share_link": $link,
           "yaml_config": $yaml,
           "client_config": $client,
           "created_at": $time
       }]' "$NODES_META_FILE" > "$temp" && atomic_replace_file "$temp" "$NODES_META_FILE"
    
    if [ $? -eq 0 ]; then
        info "节点元数据已保存"
    else
        rm -f "$temp"
        error "保存节点元数据失败"
        return 1
    fi
}

# --- 生成 UUID ---
generate_uuid() {
    "$XRAY_BINARY_PATH" uuid 2>/dev/null || {
        error "生成 UUID 失败"
        return 1
    }
}

# --- 生成 SS 密码 / SS2022 密钥 ---
generate_ss_password() {
    local method="$1"
    local key_length

    case "$method" in
        aes-128-gcm|aes-256-gcm)
            # 传统 SS 使用普通密码，无固定密钥长度要求；默认生成随机密码。
            key_length=24
            ;;
        2022-blake3-aes-128-gcm)
            key_length=16
            ;;
        2022-blake3-aes-256-gcm|2022-blake3-chacha20-poly1305)
            key_length=32
            ;;
        *)
            error "不支持的 SS 加密方式: $method"
            return 1
            ;;
    esac

    if command -v openssl >/dev/null 2>&1; then
        openssl rand -base64 "$key_length" 2>/dev/null
    else
        head -c "$key_length" /dev/urandom | base64 | tr -d '\n'
    fi
}

# --- 检查 SS 密码（传统 AEAD 接受普通非空密码，SS2022 校验预共享密钥）---
validate_ss_password() {
    local method="$1"
    local password="$2"
    local key_length decoded_file decoded_length

    case "$method" in
        aes-128-gcm|aes-256-gcm)
            if [ -z "$password" ]; then
                error "SS 密码不能为空"
                return 1
            fi
            return 0
            ;;
        2022-blake3-aes-128-gcm)
            key_length=16
            ;;
        2022-blake3-aes-256-gcm|2022-blake3-chacha20-poly1305)
            key_length=32
            ;;
        *)
            error "不支持的 SS 加密方式: $method"
            return 1
            ;;
    esac

    if ! [[ "$password" =~ ^[A-Za-z0-9+/]+={0,2}$ ]] || [ $(( ${#password} % 4 )) -ne 0 ]; then
        error "密码必须是合法的 Base64 字符串"
        return 1
    fi

    decoded_file=$(mktemp) || {
        error "创建临时文件失败"
        return 1
    }
    register_temp_file "$decoded_file"

    if ! printf '%s' "$password" | openssl base64 -d -A -out "$decoded_file" 2>/dev/null; then
        rm -f "$decoded_file"
        error "密码不是合法的 Base64 字符串"
        return 1
    fi

    decoded_length=$(wc -c < "$decoded_file")
    rm -f "$decoded_file"

    # 官方 SS 文档注明：Go 实现中 32 字节密钥始终工作，AES-128 也接受此长度。
    if [ "$decoded_length" -ne "$key_length" ] && [ "$decoded_length" -ne 32 ]; then
        error "密码解码后必须是 ${key_length} 字节（Go 实现也支持 32 字节）"
        return 1
    fi
}

# URI 组件按百分号编码解码；+ 是密钥的一部分，不按表单规则变为空格。
decode_uri_component() {
    local encoded="$1" hex byte
    URI_DECODED=""
    while [ -n "$encoded" ]; do
        if [[ "$encoded" == %* ]]; then
            hex="${encoded:1:2}"
            if ! [[ "$hex" =~ ^[0-9A-Fa-f]{2}$ ]] || [ "$hex" = 00 ]; then
                error "URI 包含无效的百分号编码或 NUL 字节"
                return 1
            fi
            printf -v byte '%b' "\\x$hex"
            URI_DECODED+="$byte"
            encoded="${encoded:3}"
        else
            URI_DECODED+="${encoded:0:1}"
            encoded="${encoded:1}"
        fi
    done
}

# --- 解析 SS / SS2022 URI（标准明文认证及旧 Base64 / Base64URL 链接）---
parse_ss_uri() {
    local uri="$1"
    local body encoded_credentials endpoint decoded_credentials decoded_file

    URI_SERVER=""
    URI_PORT=""
    URI_METHOD=""
    URI_PASSWORD=""

    case "$uri" in
        ss://*)
            body="${uri#ss://}"
            ;;
        *)
            error "无效的 SS URI，应以 ss:// 开头"
            return 1
            ;;
    esac

    body="${body%%#*}"
    if [[ "$body" == *\?* ]]; then
        error "暂不支持 SS URI 查询参数，请改用不含插件参数的链接或手动填写"
        return 1
    fi
    if [[ "$body" != *@* ]]; then
        error "无效的 SS URI，缺少服务器地址"
        return 1
    fi

    encoded_credentials="${body%@*}"
    endpoint="${body##*@}"
    endpoint="${endpoint%/}"

    if [[ "$encoded_credentials" == *:* ]]; then
        # SIP002 的 SS2022 使用 method:password，两部分分别进行百分号解码。
        decode_uri_component "${encoded_credentials%%:*}" || return 1
        URI_METHOD="$URI_DECODED"
        decode_uri_component "${encoded_credentials#*:}" || return 1
        URI_PASSWORD="$URI_DECODED"
    else
        encoded_credentials=$(printf '%s' "$encoded_credentials" | tr '_-' '/+')
        if ! [[ "$encoded_credentials" =~ ^[A-Za-z0-9+/]+={0,2}$ ]]; then
            error "URI 中的认证信息不是有效 Base64"
            return 1
        fi
        case $(( ${#encoded_credentials} % 4 )) in
            0) ;;
            2) encoded_credentials+="==" ;;
            3) encoded_credentials+="=" ;;
            *) error "URI 中的认证信息不是有效 Base64"; return 1 ;;
        esac
        decoded_file=$(mktemp) || return 1
        register_temp_file "$decoded_file"
        if ! printf '%s' "$encoded_credentials" | base64 -d > "$decoded_file" 2>/dev/null; then
            rm -f "$decoded_file"
            error "URI 中的认证信息不是有效 Base64"
            return 1
        fi
        # read 到 EOF 保留密码末尾换行；读到 NUL 则拒绝，避免 Bash 静默删除它。
        if IFS= read -r -d '' decoded_credentials < "$decoded_file"; then
            rm -f "$decoded_file"
            error "URI 中的认证信息包含 NUL 字节"
            return 1
        fi
        rm -f "$decoded_file"
        if [[ "$decoded_credentials" != *:* ]]; then
            error "URI 中的认证信息缺少加密方式或密码分隔符"
            return 1
        fi
        URI_METHOD="${decoded_credentials%%:*}"
        URI_PASSWORD="${decoded_credentials#*:}"
    fi

    if [[ "$endpoint" =~ ^\[([^]]+)\]:([0-9]+)$ ]]; then
        URI_SERVER="${BASH_REMATCH[1]}"
        URI_PORT="${BASH_REMATCH[2]}"
    elif [[ "$endpoint" =~ ^([^:]+):([0-9]+)$ ]]; then
        URI_SERVER="${BASH_REMATCH[1]}"
        URI_PORT="${BASH_REMATCH[2]}"
    else
        error "URI 中的服务器地址或端口格式无效"
        return 1
    fi

    if ! URI_PORT=$(normalize_decimal "$URI_PORT" 1 65535); then
        error "URI 中的端口应为 1-65535"
        return 1
    fi
    validate_ss_password "$URI_METHOD" "$URI_PASSWORD" || return 1
}

# --- 生成 Reality 密钥对 ---
generate_reality_keypair() {
    local output
    if ! output=$("$XRAY_BINARY_PATH" x25519 2>&1); then
        error "生成 Reality 密钥失败"
        if [ -n "$output" ]; then
            echo "错误输出: $output" >&2
        fi
        return 1
    fi
    
    if [ -z "$output" ]; then
        error "命令执行成功但无输出"
        return 1
    fi
    
    echo "$output"
}

# --- 添加 SS / SS2022 节点 ---
add_ss_node() {
    with_xrm_lock _add_ss_node "$@"
}

_add_ss_node() {
    # 获取服务器地址
    get_server_address || return 1
    
    local tag port password method port_source
    
    # 端口自定义
    read -r -p "请输入端口 (默认: 443): " port || return 1
    if [ -z "$port" ]; then
        port=443
        port_source="default"
    else
        port_source="custom"
    fi

    port=$(normalize_decimal "$port" 1 65535) || { error "无效端口，应为 1-65535"; return 1; }
    check_port_available "$port" || return 1

    if [ "$port_source" = "default" ]; then
        info "使用默认端口: $port"
    else
        info "使用自定义端口: $port"
    fi
    
    # 节点标签
    read -r -p "请输入节点标签 (默认: ss-${port}): " tag || return 1
    [ -z "$tag" ] && tag="ss-${port}"
    check_tag_available "$tag" || return 1

    # 选择加密方式
    echo "1) 2022-blake3-aes-128-gcm"
    echo "2) 2022-blake3-aes-256-gcm"
    echo "3) 2022-blake3-chacha20-poly1305"
    echo "4) aes-128-gcm"
    echo "5) aes-256-gcm"
    read -r -p "请选择加密方式 [1-5，默认: 1]: " method || return 1
    case "${method:-1}" in
        1)
            method="2022-blake3-aes-128-gcm"
            ;;
        2)
            method="2022-blake3-aes-256-gcm"
            ;;
        3)
            method="2022-blake3-chacha20-poly1305"
            ;;
        4)
            method="aes-128-gcm"
            ;;
        5)
            method="aes-256-gcm"
            ;;
        *)
            error "无效的加密方式，请输入 1-5"
            return 1
            ;;
    esac
    info "加密方法: $method"
    
    # 密码自定义
    IFS= read -r -s -p "请输入密码 (留空自动生成): " password || return 1
    echo
    if [ -z "$password" ]; then
        password=$(generate_ss_password "$method") || { error "生成 SS 密码失败"; return 1; }
        [ -n "$password" ] || { error "生成 SS 密码为空"; return 1; }
        info "自动生成密码: $password"
    else
        validate_ss_password "$method" "$password" || return 1
        info "使用自定义密码"
    fi
    
    # 构建 inbound 配置
    local inbound
    inbound=$(jq -n \
        --arg tag "$tag" \
        --arg port "$port" \
        --arg password "$password" \
        --arg method "$method" \
        '{
            "tag": $tag,
            "listen": "::",
            "port": ($port | tonumber),
            "protocol": "shadowsocks",
            "settings": {
                "method": $method,
                "password": $password,
                "network": "tcp,udp"
            }
        }') || return 1
    
    # Clash 节点和分享链接沿用原脚本格式；Xray 文档未确认第三方客户端格式。
    local share_link="" yaml_config="" client_config
    local encoded_tag yaml_name yaml_server yaml_password uri_address raw_address
    encoded_tag=$(printf '%s' "$tag" | url_encode) || return 1
    uri_address=$(uri_host "$SERVER_IP")
    yaml_name=$(yaml_scalar "$tag")
    raw_address="${SERVER_IP#[}"
    raw_address="${raw_address%]}"
    yaml_server=$(yaml_scalar "$raw_address")
    yaml_password=$(yaml_scalar "$password")
    local encoded_credentials
    encoded_credentials=$(printf '%s' "${method}:${password}" | base64 | tr -d '\r\n')
    case "$method" in
        aes-128-gcm|aes-256-gcm)
            encoded_credentials=$(printf '%s' "$encoded_credentials" | tr '/+' '_-' | tr -d '=')
            ;;
    esac
    share_link="ss://${encoded_credentials}@${uri_address}:${port}#${encoded_tag}"
    yaml_config="- {name: ${yaml_name}, type: ss, server: ${yaml_server}, port: ${port}, cipher: ${method}, password: ${yaml_password}, udp: true}"
    client_config=$(jq -n --arg tag "$tag" --arg address "${SERVER_IP#[}" \
        --arg port "$port" --arg method "$method" --arg password "$password" '
        {outbounds: [{tag: $tag, protocol: "shadowsocks", settings: {
            address: ($address | rtrimstr("]")), port: ($port | tonumber),
            method: $method, password: $password
        }}]}') || {
        return 1
    }
    
    commit_new_node "$inbound" "$tag" "$share_link" "$yaml_config" "$client_config" || return 1

    success "SS 节点添加成功！"
    echo -e "\n${cyan}Shadowrocket 分享链接:${none}"
    printf '%s\n' "$share_link"
    echo -e "${cyan}Clash 节点（复制到 proxies）:${none}"
    printf '%s\n' "$yaml_config"
}

# --- 添加 vless reality vision 节点 ---
add_reality_node() {
    with_xrm_lock _add_reality_node "$@"
}

_add_reality_node() {
    # 获取服务器地址
    get_server_address || return 1
    
    local tag port uuid target domain private_key public_key short_id port_source
    
    # 端口自定义
    read -r -p "端口 (默认: 443): " port || return 1
    if [ -z "$port" ]; then
        port=443
        port_source="default"
    else
        port_source="custom"
    fi

    port=$(normalize_decimal "$port" 1 65535) || { error "无效端口，应为 1-65535"; return 1; }
    check_port_available "$port" || return 1

    if [ "$port_source" = "default" ]; then
        info "默认端口: $port"
    else
        info "自定义端口: $port"
    fi
    
    # 节点标签
    read -r -p "请输入节点标签 (默认: vvr-${port}): " tag || return 1
    [ -z "$tag" ] && tag="vvr-${port}"
    check_tag_available "$tag" || return 1
    
    # UUID 自定义
    read -r -p "请输入 UUID (留空自动生成): " uuid || return 1
    if [ -z "$uuid" ]; then
        if ! uuid=$(generate_uuid) || [ -z "$uuid" ]; then
            error "UUID 生成失败"
            return 1
        fi
        info "自动生成 UUID: $uuid"
    else
        if ! [[ "$uuid" =~ ^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$ ]]; then
            error "无效的 UUID 格式"
            return 1
        fi
        info "使用自定义 UUID"
    fi
    
    # 生成 Reality 密钥对
    info "正在生成 Reality 密钥对..."
    
    local keypair
    if ! keypair=$("$XRAY_BINARY_PATH" x25519 2>&1) || [ -z "$keypair" ]; then
        error "xray x25519 命令执行失败"
        return 1
    fi
    
    # 命令输出标签沿用原脚本已处理的名称；官方文档未定义完整输出格式。
    # 只接受明确标识的单个值，不使用 Hash32，也不把密钥输出到屏幕。
    private_key=$(printf '%s\n' "$keypair" | awk '
        index($0, ":") {
            label = tolower(substr($0, 1, index($0, ":") - 1))
            gsub(/[[:space:]]/, "", label)
            if (label == "privatekey") {
                value = substr($0, index($0, ":") + 1)
                gsub(/^[[:space:]]+|[[:space:]]+$/, "", value)
                if (value != "" && value !~ /[[:space:]]/) { result = value; count++ }
            }
        }
        END { if (count == 1) print result; else exit 1 }
    ') || { error "无法识别唯一的 REALITY 私钥输出，未写入配置"; return 1; }

    # 按文档从该私钥生成对应的客户端 password，再提取明确标识的值。
    if ! keypair=$("$XRAY_BINARY_PATH" x25519 -i "$private_key" 2>&1); then
        error "按私钥生成对应公钥失败"
        return 1
    fi
    public_key=$(printf '%s\n' "$keypair" | awk '
        index($0, ":") {
            label = tolower(substr($0, 1, index($0, ":") - 1))
            gsub(/[[:space:]]/, "", label)
            if (label == "publickey" || label == "password" || label == "password(publickey)") {
                value = substr($0, index($0, ":") + 1)
                gsub(/^[[:space:]]+|[[:space:]]+$/, "", value)
                if (value != "" && value !~ /[[:space:]]/) { result = value; count++ }
            }
        }
        END { if (count == 1) print result; else exit 1 }
    ') || { error "无法识别唯一的 REALITY 公钥输出，未写入配置"; return 1; }
    success "REALITY 密钥已自动生成，将写入配置和客户端节点"
    
    # SNI 域名自定义
    # 不把某个具体网站当成已确认可用的目标；由用户在服务器选择。
    read -r -p "SNI（目标接受的域名，必填，不支持 * 通配符）: " domain || return 1
    if [ -z "$domain" ] || [[ "$domain" == *'*'* ]]; then
        error "请填写非空且不含 * 的 SNI"
        return 1
    fi

    # 官方现名 target；dest 仍被文档列为别名。这里采用现名。
    read -r -p "target（默认: ${domain}:443）: " target || return 1
    [ -z "$target" ] && target="${domain}:443"
    
    # Short ID 自定义
    read -r -p "请输入 Short ID (留空自动生成): " short_id || return 1
    if [ -z "$short_id" ]; then
        if command -v openssl >/dev/null 2>&1; then
            short_id=$(openssl rand -hex 4)
        else
            short_id=$(head -c 4 /dev/urandom | od -An -tx1 | tr -d ' \n')
        fi
        info "Short ID: $short_id"
    else
        # 官方要求十六进制位数为偶数，最多 16 位；留空用于自动生成。
        if ! [[ "$short_id" =~ ^([0-9a-f]{2}){1,8}$ ]]; then
            error "无效的 Short ID（需要 2、4、6、8、10、12、14 或 16 位小写十六进制字符）"
            return 1
        fi
        info "使用自定义 Short ID"
    fi
    
    # clients/network 同时兼容 26.3.27 和 26.10.21。
    # 旧核心会忽略 users，且配置检查可能仍通过，不能仅凭启动成功判断节点可用。
    local inbound
    inbound=$(jq -n \
        --arg tag "$tag" \
        --arg port "$port" \
        --arg uuid "$uuid" \
        --arg domain "$domain" \
        --arg target "$target" \
        --arg private_key "$private_key" \
        --arg short_id "$short_id" \
        '{
            "tag": $tag,
            "listen": "::",
            "port": ($port | tonumber),
            "protocol": "vless",
            "settings": {
                "clients": [{
                    "id": $uuid,
                    "flow": "xtls-rprx-vision"
                }],
                "decryption": "none"
            },
            "streamSettings": {
                "network": "raw",
                "security": "reality",
                "realitySettings": {
                    "show": false,
                    "target": $target,
                    "xver": 0,
                    "serverNames": [$domain],
                    "privateKey": $private_key,
                    "shortIds": [$short_id]
                }
            }
        }') || return 1
    
    # 仅使用指定文档中的 VLESS 出站和 RealityObject 字段。
    local share_link="" yaml_config="" client_config
    local encoded_tag encoded_domain encoded_public_key encoded_authority uri_address raw_address
    local yaml_name yaml_server yaml_domain yaml_public_key yaml_short_id yaml_uuid
    encoded_tag=$(printf '%s' "$tag" | url_encode) || return 1
    encoded_domain=$(printf '%s' "$domain" | url_encode) || return 1
    encoded_public_key=$(printf '%s' "$public_key" | url_encode) || return 1
    uri_address=$(uri_host "$SERVER_IP")
    yaml_name=$(yaml_scalar "$tag")
    raw_address="${SERVER_IP#[}"
    raw_address="${raw_address%]}"
    yaml_server=$(yaml_scalar "$raw_address")
    yaml_domain=$(yaml_scalar "$domain")
    yaml_public_key=$(yaml_scalar "$public_key")
    yaml_short_id=$(yaml_scalar "$short_id")
    yaml_uuid=$(yaml_scalar "$uuid")
    # 小火箭专用格式：只编码 auto:UUID@地址:端口，不编码协议头和查询参数。
    # tls=1 配合 pbk/sid 表示 REALITY，xtls=2 表示 Vision；默认使用 TCP。
    if ! encoded_authority=$(set -o pipefail; printf '%s' "auto:${uuid}@${uri_address}:${port}" | base64 | tr -d '\r\n'); then
        error "生成 Shadowrocket Base64 URI 失败"
        return 1
    fi
    # 此链接同时用于终端显示和节点元数据的 share_link 字段。
    share_link="vless://${encoded_authority}?remark=${encoded_tag}&tls=1&xtls=2&sni=${encoded_domain}&fp=chrome&pbk=${encoded_public_key}&sid=${short_id}"
    # YAML 独立生成，继续明文保存；support-x25519mlkem768 位置沿用 reality-opts。
    yaml_config="- {name: ${yaml_name}, type: vless, server: ${yaml_server}, port: ${port}, uuid: ${yaml_uuid}, udp: true, tls: true, network: tcp, flow: xtls-rprx-vision, servername: ${yaml_domain}, client-fingerprint: chrome, reality-opts: {public-key: ${yaml_public_key}, short-id: ${yaml_short_id}, support-x25519mlkem768: true}}"
    client_config=$(jq -n --arg tag "$tag" --arg address "${SERVER_IP#[}" \
        --arg port "$port" --arg uuid "$uuid" --arg domain "$domain" \
        --arg password "$public_key" --arg short_id "$short_id" '
        {outbounds: [{tag: $tag, protocol: "vless", settings: {
            address: ($address | rtrimstr("]")), port: ($port | tonumber),
            id: $uuid, encryption: "none", flow: "xtls-rprx-vision"
        }, streamSettings: {network: "raw", security: "reality", realitySettings: {
            serverName: $domain, fingerprint: "chrome", password: $password,
            shortId: $short_id
        }}}]}') || {
        return 1
    }
    
    commit_new_node "$inbound" "$tag" "$share_link" "$yaml_config" "$client_config" || return 1

    success "vless reality vision 节点添加成功！"
    echo -e "\n${cyan}Shadowrocket 分享链接:${none}"
    printf '%s\n' "$share_link"
    echo -e "${cyan}Clash 节点（复制到 proxies）:${none}"
    printf '%s\n' "$yaml_config"
}

# --- 列出所有节点 ---
list_nodes() {
    if [ ! -f "$NODES_META_FILE" ]; then
        info "暂无节点信息"
        return 0
    fi
    
    local node_count
    node_count=$(jq '.nodes | length' "$NODES_META_FILE" 2>/dev/null || echo 0)
    
    if [ "$node_count" -eq 0 ]; then
        info "暂无节点"
        return 0
    fi
    
    echo -e "\n${cyan}=== 节点列表 (共 $node_count 个) ===${none}\n"
    
    local index=1
    local nodes_json
    nodes_json=$(jq -r '.nodes[] | @json' "$NODES_META_FILE")
    
    while IFS= read -r node; do
        local tag=$(echo "$node" | jq -r '.tag')
        local share_link=$(echo "$node" | jq -r '.share_link')
        local yaml_config=$(echo "$node" | jq -r '.yaml_config')
        
        echo -e "${green}[$index]${none} ${magenta}$tag${none}"
        if [ -n "$share_link" ] && [ "$share_link" != null ]; then
            echo -e "${cyan}Shadowrocket URI:${none}"
            printf '%s\n' "$share_link"
        fi
        if [ -n "$yaml_config" ] && [ "$yaml_config" != null ]; then
            echo -e "${cyan}Clash YAML:${none}"
            printf '%s\n' "$yaml_config"
        fi
        if echo "$node" | jq -e '.client_config != null' >/dev/null 2>&1; then
            echo -e "${cyan}Xray 客户端出站片段:${none}"
            echo "$node" | jq '.client_config'
        fi
        echo "---"
        echo
        
        ((index++))
    done <<< "$nodes_json"
}

# --- 删除节点 ---
delete_node() {
    with_xrm_lock _delete_node "$@"
}

_delete_node() {
    if [ ! -f "$NODES_META_FILE" ]; then info "暂无节点信息"; return 0; fi
    local node_count choice confirm delete_tag
    node_count=$(jq -er '.nodes | length' "$NODES_META_FILE") || return 1
    if [ "$node_count" -eq 0 ]; then info "暂无节点"; return 0; fi
    echo -e "\n${cyan}=== 选择要删除的节点 ===${none}\n"
    jq -r '.nodes | to_entries[] | "[\(.key + 1)] \(.value.tag)"' "$NODES_META_FILE" || return 1
    echo "[0] 取消"
    read -r -p "请输入要删除的节点序号: " choice || return 1
    choice=$(normalize_decimal "$choice" 0 "$node_count") || { error "无效的节点序号"; return 1; }
    if [ "$choice" -eq 0 ]; then info "已取消删除"; return 0; fi
    delete_tag=$(jq -er --argjson index "$((choice - 1))" '.nodes[$index].tag' "$NODES_META_FILE") || return 1
    read -r -p "确认删除节点 '${delete_tag}' ? [Y/n]: " confirm || return 1
    if [[ "$confirm" =~ ^[Nn]$ ]]; then info "已取消删除"; return 0; fi

    local config_candidate meta_candidate yaml_candidate
    config_candidate=$(mktemp) || return 1
    register_temp_file "$config_candidate"
    meta_candidate=$(mktemp) || return 1
    register_temp_file "$meta_candidate"
    yaml_candidate=$(mktemp) || return 1
    register_temp_file "$yaml_candidate"
    jq --arg tag "$delete_tag" 'del(.inbounds[] | select(.tag == $tag))' \
        "$XRAY_CONFIG_PATH" > "$config_candidate" || return 1
    jq --arg tag "$delete_tag" 'del(.nodes[] | select(.tag == $tag))' \
        "$NODES_META_FILE" > "$meta_candidate" || return 1
    printf '%s\n\n' '# Clash 节点列表：复制节点到现有 YAML 的 proxies 部分' > "$yaml_candidate" || return 1
    jq -r '.nodes[].yaml_config // empty | select(length > 0)' "$meta_candidate" >> "$yaml_candidate" || return 1
    commit_xray_state "$config_candidate" "$meta_candidate" "$yaml_candidate" || return 1
    success "节点 '${delete_tag}' 已删除"
}

# --- 卸载 Xray ---
uninstall_xray() {
    with_xrm_lock _uninstall_xray "$@"
}

_uninstall_xray() {
    echo -e "\n${red}=== 卸载 Xray ===${none}\n"
    echo -e "${yellow}警告: 此操作将完全删除以下内容:${none}"
    echo "  - Xray 二进制文件"
    echo "  - Xray 配置文件"
    echo "  - Xray 系统服务"
    echo "  - 所有节点配置和元数据"
    echo "  - GeoIP/GeoSite 数据文件"
    echo "  - 全局命令 xrm"
    echo
    
    local confirm
    read -r -p "确认完全卸载 Xray? [Y/n]: " confirm || {
        info "未收到确认，已取消卸载"
        return 1
    }
    if [[ "$confirm" =~ ^[Nn]$ ]]; then
        info "已取消卸载"
        return 0
    fi

    info "开始卸载 Xray..."

    # 先确认停服成功，再移除定时任务和安装文件。
    if xray_service_is_active 2>/dev/null; then
        info "正在停止 Xray 服务..."
        stop_xray || { error "无法停止 Xray，已取消卸载"; return 1; }
    fi
    disable_geo_schedule || { error "清理 Geo 定时任务失败，已取消卸载"; return 1; }
    
    # 停止并删除系统服务
    if [ "$OS_TYPE" = "debian" ]; then
        if systemctl is-enabled --quiet xray 2>/dev/null; then
            info "正在禁用 Xray 服务..."
            systemctl disable xray || { error "禁用 Xray 服务失败，已取消卸载"; return 1; }
        fi
        
        if [ -f /etc/systemd/system/xray.service ]; then
            info "正在删除 systemd 服务文件..."
            rm -f /etc/systemd/system/xray.service || { error "删除 systemd 服务文件失败，已取消卸载"; return 1; }
            systemctl daemon-reload || { error "重新加载 systemd 失败，已取消卸载"; return 1; }
        fi
    elif [ "$OS_TYPE" = "alpine" ]; then
        if [ -x /etc/init.d/xray ]; then
            info "正在删除 OpenRC 服务..."
            local default_services
            default_services=$(rc-update show default) || { error "读取 OpenRC 服务状态失败，已取消卸载"; return 1; }
            if printf '%s\n' "$default_services" | grep -Eq '^[[:space:]]*xray[[:space:]]'; then
                rc-update del xray default || { error "禁用 OpenRC 服务失败，已取消卸载"; return 1; }
            fi
            rm -f /etc/init.d/xray || { error "删除 OpenRC 服务文件失败，已取消卸载"; return 1; }
        fi
        
        # 删除日志目录
        if [ -d /var/log/xray ]; then
            rm -rf /var/log/xray
        fi
    fi
    
    # 删除 Xray 二进制文件
    if [ -f "$XRAY_BINARY_PATH" ]; then
        info "正在删除 Xray 二进制文件..."
        rm -f "$XRAY_BINARY_PATH"
    fi
    
    # 删除配置文件
    if [ -f "$XRAY_CONFIG_PATH" ]; then
        info "正在删除配置文件..."
        rm -f "$XRAY_CONFIG_PATH"
    fi
    
    if [ -f "$YAML_NODES_FILE" ]; then
        info "正在删除 YAML 节点文件..."
        rm -f "$YAML_NODES_FILE"
    fi
    
    if [ -f "$NODES_META_FILE" ]; then
        info "正在删除节点元数据..."
        rm -f "$NODES_META_FILE"
    fi

    if [ -f "$OUTBOUND_PROFILES_FILE" ]; then
        info "正在删除出口配置档案..."
        rm -f "$OUTBOUND_PROFILES_FILE" || {
            error "删除出口配置档案失败"
            return 1
        }
    fi
    
    # 删除配置目录（如果为空）
    if [ -d "$(dirname "$XRAY_CONFIG_PATH")" ]; then
        rmdir --ignore-fail-on-non-empty "$(dirname "$XRAY_CONFIG_PATH")" 2>/dev/null || true
    fi
    
    # 删除 GeoIP/GeoSite 数据文件
    if [ -d /usr/local/share/xray ]; then
        info "正在删除 GeoIP/GeoSite 数据文件..."
        rm -rf /usr/local/share/xray
    fi
    
    # 删除全局命令
    if [ -f /usr/local/bin/xrm ]; then
        info "正在删除全局命令 xrm..."
        rm -f /usr/local/bin/xrm
    fi
    
    success "Xray 已完全卸载！"
    success "再见！"
    exit 0
}

# --- 重启服务 ---
restart_xray() {
    info "正在重启 Xray 服务..."
    
    if [ "$OS_TYPE" = "debian" ]; then
        systemctl restart xray 9>&- || { error "重启 Xray 服务失败"; return 1; }
        sleep 2
        if systemctl is-active --quiet xray; then
            success "Xray 服务已重启"
        else
            error "Xray 服务启动失败，请检查配置"
            journalctl -u xray -n 20 --no-pager
            return 1
        fi
    elif [ "$OS_TYPE" = "alpine" ]; then
        rc-service xray restart 9>&- || { error "重启 Xray 服务失败"; return 1; }
        sleep 2
        if rc-service xray status >/dev/null 2>&1; then
            success "Xray 服务已重启"
        else
            error "Xray 服务启动失败，请检查配置"
            return 1
        fi
    else
        error "不支持的服务管理方式: $OS_TYPE"
        return 1
    fi
    return 0
}

# --- 修改出口配置 ---
# --- 初始化出口配置文件 ---
init_outbound_profiles() {
    if [ ! -f "$OUTBOUND_PROFILES_FILE" ]; then
        local temp
        temp=$(mktemp) || { error "创建临时文件失败"; return 1; }
        register_temp_file "$temp"
        if ! printf '[]\n' > "$temp" || ! atomic_replace_file "$temp" "$OUTBOUND_PROFILES_FILE"; then
            rm -f "$temp"
            error "初始化出口配置失败"
            return 1
        fi
    fi
    if ! jq -e 'type == "array"' "$OUTBOUND_PROFILES_FILE" >/dev/null 2>&1; then
        error "出口配置文件不是有效的 JSON 数组"
        return 1
    fi
}

# --- 保存 SS / SS2022 出口配置 ---
save_ss_profile() {
    with_xrm_lock _save_ss_profile "$@"
}

_save_ss_profile() {
    local name="$1" server="$2" port="$3" password="$4"
    local method="${5:-2022-blake3-aes-128-gcm}"
    
    [ -n "$name" ] && [ -n "$server" ] || { error "出口名称和服务器地址不能为空"; return 1; }
    port=$(normalize_decimal "$port" 1 65535) || { error "无效的端口号"; return 1; }
    validate_ss_password "$method" "$password" || return 1
    init_outbound_profiles || return 1
    
    local temp
    temp=$(mktemp) || { error "创建临时文件失败"; return 1; }
    register_temp_file "$temp"
    
    # 检查是否已存在同名配置
    # 名称通过 jq 参数传入，避免引号等字符被当作 jq 代码。
    if jq -e --arg name "$name" '.[] | select(.name == $name)' "$OUTBOUND_PROFILES_FILE" >/dev/null 2>&1; then
        # 更新已存在的配置
        jq --arg name "$name" \
           --arg server "$server" \
           --arg port "$port" \
           --arg password "$password" \
           --arg method "$method" \
           'map(if .name == $name then {
               "name": $name,
               "server": $server,
               "port": $port,
               "password": $password,
               "method": $method
            } else . end)' "$OUTBOUND_PROFILES_FILE" > "$temp" && atomic_replace_file "$temp" "$OUTBOUND_PROFILES_FILE"
    else
        # 添加新配置
        jq --arg name "$name" \
           --arg server "$server" \
           --arg port "$port" \
           --arg password "$password" \
           --arg method "$method" \
           '. += [{
               "name": $name,
               "server": $server,
               "port": $port,
               "password": $password,
               "method": $method
            }]' "$OUTBOUND_PROFILES_FILE" > "$temp" && atomic_replace_file "$temp" "$OUTBOUND_PROFILES_FILE"
    fi
    
    if [ $? -eq 0 ]; then
        success "配置 '$name' 已保存"
    else
        error "保存配置失败"
        rm -f "$temp"
        return 1
    fi
}

# --- 应用 直连出口 配置 ---
apply_direct_outbound() {
    with_xrm_lock _apply_direct_outbound "$@"
}

_apply_direct_outbound() {
    local temp
    temp=$(mktemp) || { error "创建临时文件失败"; return 1; }
    register_temp_file "$temp"

    # 首出站是未命中路由时的默认出口；保留现有 tag，避免破坏自定义路由引用。
    jq '(.outbounds // []) as $outbounds |
        if any($outbounds[]; .tag == "direct" and .protocol != "freedom") then
            error("direct 标签已被非 freedom 出站使用")
        else
            ($outbounds | map(select(.tag == "direct")) | .[0] //
                {tag: "direct", protocol: "freedom"}) as $direct |
            .outbounds = ([$direct] + [$outbounds[] | select(.tag != "direct")] |
                if any(.[]; .tag == "block") then .
                else . + [{tag: "block", protocol: "blackhole"}] end)
        end' "$XRAY_CONFIG_PATH" > "$temp" && commit_xray_config "$temp"

    if [ $? -eq 0 ]; then
        success "已切换到直连出口"
        return 0
    else
        error "配置失败"
        rm -f "$temp"
        return 1
    fi
}

# --- 应用 SS / SS2022 出口配置 ---
apply_ss_outbound() {
    with_xrm_lock _apply_ss_outbound "$@"
}

_apply_ss_outbound() {
    local server="$1" port="$2" password="$3" method="${4:-2022-blake3-aes-128-gcm}"
    [ -n "$server" ] || { error "服务器地址不能为空"; return 1; }
    port=$(normalize_decimal "$port" 1 65535) || { error "无效的端口号"; return 1; }
    validate_ss_password "$method" "$password" || return 1
    
    local temp
    temp=$(mktemp) || { error "创建临时文件失败"; return 1; }
    register_temp_file "$temp"
    
    jq --arg server "$server" \
       --arg port "$port" \
       --arg password "$password" \
       --arg method "$method" \
       '(.outbounds // []) as $outbounds |
        if any($outbounds[]; .tag == "proxy" and .protocol != "shadowsocks") then
            error("proxy 标签已被非 shadowsocks 出站使用")
        else
            (($outbounds | map(select(.tag == "proxy")) | .[0] //
                {tag: "proxy", protocol: "shadowsocks"}) |
                .settings = {
                    address: $server,
                    port: ($port | tonumber),
                    method: $method,
                    password: $password
                }) as $proxy |
            .outbounds = ([$proxy] + [$outbounds[] | select(.tag != "proxy")] |
                if any(.[]; .tag == "block") then .
                else . + [{tag: "block", protocol: "blackhole"}] end)
        end' "$XRAY_CONFIG_PATH" > "$temp" && commit_xray_config "$temp"
    
    if [ $? -eq 0 ]; then
        success "已切换到 SS 出口"
        info "加密方法: $method"
        info "服务器: $server:$port"
        return 0
    else
        error "配置失败"
        rm -f "$temp"
        return 1
    fi
}

# 选择页读取同一份快照；未保存任何出口时也可选择直连。
write_profile_snapshot() {
    local destination="$1"
    if [ -f "$OUTBOUND_PROFILES_FILE" ]; then
        jq -e 'select(type == "array")' "$OUTBOUND_PROFILES_FILE" > "$destination" || {
            error "无法读取已保存出口，暂只显示内置选项；原档案保留，请检查后重试"
            printf '[]\n' > "$destination" || return 1
        }
    else
        printf '[]\n' > "$destination"
    fi
}

load_selected_profile() {
    local profile="$1" field encoded
    local -a fields=()
    if ! printf '%s' "$profile" | jq -e '
        type == "object" and (.name | type == "string") and
        (.server | type == "string") and (.password | type == "string") and
        (.port | type == "number" or type == "string") and
        ((.method // "2022-blake3-aes-128-gcm") | type == "string")' >/dev/null; then
        error "出口配置记录无效"; return 1
    fi
    # Base64 传递字段，避免 jq 的文本换行转换或命令替换改变密码字节。
    while IFS= read -r -d '' encoded; do
        if IFS= read -r -d '' field < <(printf '%s' "$encoded" | base64 -d); then
            error "出口字段包含 NUL 字节，未应用"
            return 1
        fi
        fields+=("$field")
    done < <(
        printf '%s' "$profile" | jq -j '
            [.name,.server,(.port | tostring),.password,(.method // "2022-blake3-aes-128-gcm")][] |
            @base64,"\u0000"'
    )
    [ "${#fields[@]}" -eq 5 ] || { error "无法读取出口配置字段"; return 1; }
    SELECTED_PROFILE_NAME="${fields[0]}"
    SELECTED_PROFILE_SERVER="${fields[1]}"
    SELECTED_PROFILE_PORT=$(normalize_decimal "${fields[2]}" 1 65535) || { error "无效的出口端口"; return 1; }
    SELECTED_PROFILE_PASSWORD="${fields[3]}"
    SELECTED_PROFILE_METHOD="${fields[4]}"
    [ -n "$SELECTED_PROFILE_SERVER" ] || { error "出口服务器地址不能为空"; return 1; }
    validate_ss_password "$SELECTED_PROFILE_METHOD" "$SELECTED_PROFILE_PASSWORD"
}

read_ai_metadata() {
    local destination="$1"
    if [ -f "$NODES_META_FILE" ]; then
        cat "$NODES_META_FILE" > "$destination" || return 1
    else
        printf '{"nodes":[]}\n' > "$destination" || return 1
    fi
    if ! jq -e '
        type == "object" and (.nodes | type == "array") and
        (.xrm_ai_routing == null or (.xrm_ai_routing |
            .version == 1 and (.mode == "follow" or .mode == "direct" or .mode == "profile") and
            ((.outbound_owned // false) | type == "boolean") and
            (.domain_strategy_before == null or (.domain_strategy_before | type == "string")) and
            ((.sniffing_tags // []) | type == "array" and all(.[]; type == "string"))))
        ' "$destination" >/dev/null; then
        error "节点元数据或 AI 分流状态无效，未修改配置"
        return 1
    fi
}

# 只管理此前没有 sniffing 的脚本节点；恢复跟随时保留用户后续修改。
sync_ai_sniffing() {
    local config="$1" metadata="$2" pair
    if ! jq -e '.xrm_ai_routing != null' "$metadata" >/dev/null; then return 0; fi
    if ! jq -e '.xrm_ai_routing | .version == 1 and
        (.mode == "follow" or .mode == "direct" or .mode == "profile")' "$metadata" >/dev/null; then
        error "不支持当前 AI 分流元数据版本，未修改节点"
        return 1
    fi
    pair=$(mktemp) || return 1
    register_temp_file "$pair"
    jq --slurpfile metadata "$metadata" '
        {config: ., metadata: $metadata[0]} |
        {enabled:true, routeOnly:true, destOverride:["http","tls","quic"]} as $sniff |
        (.metadata.xrm_ai_routing.sniffing_tags // []) as $old |
        if .metadata.xrm_ai_routing.mode == "follow" then
            if (.config.inbounds | type) == "array" then
                .config.inbounds |= map(.tag as $tag |
                    if ($old | index($tag)) != null and .sniffing == $sniff
                    then del(.sniffing) else . end)
            else . end |
            .metadata.xrm_ai_routing.sniffing_tags = []
        else
            [.metadata.nodes[]?.tag] as $managed |
            [.config.inbounds[]? | .tag as $tag |
                select(($managed | index($tag)) != null and
                    (.protocol == "shadowsocks" or .protocol == "vless") and
                    (has("sniffing") | not)) | .tag] as $added |
            if (.config.inbounds | type) == "array" then
                .config.inbounds |= map(.tag as $tag |
                    if ($added | index($tag)) != null then .sniffing = $sniff else . end)
            else . end |
            [.config.inbounds[]?.tag] as $present |
            .metadata.xrm_ai_routing.sniffing_tags =
                ([$old[] | . as $tag | select(($present | index($tag)) != null)] + $added | unique)
        end' "$config" > "$pair" || return 1
    jq '.config' "$pair" > "$config" && jq '.metadata' "$pair" > "$metadata"
}

show_ai_routing_status() {
    local metadata mode name
    metadata=$(mktemp) || return 1
    register_temp_file "$metadata"
    read_ai_metadata "$metadata" || return 1
    mode=$(jq -r '.xrm_ai_routing.mode // "follow"' "$metadata") || return 1
    case "$mode" in
        follow) info "当前 AI 分流：跟随选择出口" ;;
        direct) info "当前 AI 分流：直连" ;;
        profile)
            name=$(jq -r '.xrm_ai_routing.profile_name // "已指定出口"' "$metadata") || return 1
            printf '\n当前 AI 分流：%s\n\n' "$name" ;;
    esac
    rm -f "$metadata"
}

apply_ai_routing() {
    with_xrm_lock _apply_ai_routing "$@"
}

_apply_ai_routing() {
    local mode="$1" profile="${2:-}" metadata candidate owned=false outbound='null' name="" strategy_changed=false
    case "$mode" in follow|direct|profile) ;; *) error "无效的 AI 分流模式"; return 1 ;; esac
    metadata=$(mktemp) || return 1
    register_temp_file "$metadata"
    read_ai_metadata "$metadata" || return 1
    if jq -e '.xrm_ai_routing.outbound_owned == true' "$metadata" >/dev/null; then owned=true; fi
    # 未设置和已跟随均为无副作用操作，返回页面不会生成分流配置。
    if [ "$mode" = follow ] &&
        jq -e '(.xrm_ai_routing.mode // "follow") == "follow"' "$metadata" >/dev/null &&
        ! jq -e --arg rule "$AI_RULE_TAG" 'any(.routing.rules[]?; .ruleTag == $rule)' "$XRAY_CONFIG_PATH" >/dev/null; then
        success "AI 分流已跟随选择出口"
        return 0
    fi
    if [ "$mode" = profile ]; then
        load_selected_profile "$profile" || return 1
        name="$SELECTED_PROFILE_NAME"
        outbound=$(jq -n --arg tag "$AI_OUTBOUND_TAG" --arg server "$SELECTED_PROFILE_SERVER" \
            --arg port "$SELECTED_PROFILE_PORT" --arg password "$SELECTED_PROFILE_PASSWORD" \
            --arg method "$SELECTED_PROFILE_METHOD" '
            {tag:$tag, protocol:"shadowsocks", settings:{address:$server, port:($port|tonumber),
                method:$method, password:$password}}') || return 1
    fi
    candidate=$(mktemp) || return 1
    register_temp_file "$candidate"
    if ! jq --arg mode "$mode" --arg ai "$AI_OUTBOUND_TAG" --arg rule "$AI_RULE_TAG" \
        --arg geosite "$AI_GEOSITE" --argjson owned "$owned" --argjson outbound "$outbound" \
        --slurpfile metadata "$metadata" '
        (.outbounds // []) as $outbounds |
        (.routing.rules // []) as $all_rules |
        if ((.routing.script // "") != "") then error("当前使用路由脚本，请手动配置 AI 分流")
        elif any($outbounds[]; .tag == $ai) and ($owned | not) then
            error("AI 专用标签已被自定义出站使用，未覆盖")
        elif ($metadata[0].xrm_ai_routing == null) and any($all_rules[]; .ruleTag == $rule) then
            error("AI 规则标签已被自定义路由使用，未覆盖")
        elif ($outbounds[0].tag // "") == $ai then
            error("AI 专用出口不能作为默认出口，请先选择普通出口")
        elif $mode == "direct" and any($outbounds[]; .tag == "direct" and .protocol != "freedom") then
            error("direct 标签已被非 freedom 出站使用")
        else
            .outbounds = (if ($outbounds | length) == 0 then [{tag:"direct",protocol:"freedom"}] else $outbounds end) |
            if $mode == "profile" then
                if any(.outbounds[]; .tag == $ai and .protocol != "shadowsocks") then
                    error("AI 专用出站类型异常，未覆盖")
                else
                    ([.outbounds[] | select(.tag == $ai)] | .[0] // {}) as $previous |
                    .outbounds = ([.outbounds[] | select(.tag != $ai)] + [$previous + $outbound])
                end
            elif $mode == "direct" and (any(.outbounds[]; .tag == "direct") | not) then
                .outbounds += [{tag:"direct",protocol:"freedom"}]
            else . end |
            [$all_rules[] | select(.ruleTag != $rule)] as $rules |
            if $mode == "follow" then
                .routing.rules = $rules |
                if .routing.domainStrategy == "IPOnDemand" and
                    ($metadata[0].xrm_ai_routing.domain_strategy_before | type) == "string" then
                    .routing.domainStrategy = $metadata[0].xrm_ai_routing.domain_strategy_before
                else . end
            else
                [.outbounds[] | select(.protocol == "blackhole" or .protocol == "block") |
                    .tag | select(type == "string" and length > 0)] as $deny |
                ([$rules | to_entries[] | .value.outboundTag as $tag |
                    select(($deny | index($tag)) == null) | .key] | .[0] // ($rules | length)) as $start |
                if any($rules[$start:][]; .outboundTag as $tag | ($deny | index($tag)) != null) then
                    error("请先将现有拦截规则放在普通路由规则之前，再启用 AI 分流")
                else
                    # IPIfNonMatch 会在域名规则命中后跳过 DNS/IP 第二轮；
                    # 有前置 IP 拦截时先解析，确保 AI 也遵循相同保护。
                    if ((.routing.domainStrategy // "AsIs") | ascii_downcase) == "ipifnonmatch" and
                        any($rules[:$start][]; ((.ip // []) | length) > 0) then
                        .routing.domainStrategy = "IPOnDemand"
                    else . end |
                    .routing.rules = ($rules[:$start] + [{type:"field", ruleTag:$rule,
                        domain:[$geosite], outboundTag:(if $mode == "direct" then "direct" else $ai end)}] + $rules[$start:])
                end
            end
        end' "$XRAY_CONFIG_PATH" > "$candidate"; then
        error "AI 分流配置未应用"
        return 1
    fi
    local meta_next
    meta_next=$(mktemp) || return 1
    register_temp_file "$meta_next"
    if jq -e --slurpfile before "$XRAY_CONFIG_PATH" '
        .routing.domainStrategy == "IPOnDemand" and .routing.domainStrategy != $before[0].routing.domainStrategy
        ' "$candidate" >/dev/null; then strategy_changed=true; fi
    jq --arg mode "$mode" --arg name "$name" --argjson owned "$owned" \
        --argjson strategy_changed "$strategy_changed" --slurpfile before "$XRAY_CONFIG_PATH" '
        .xrm_ai_routing = ((.xrm_ai_routing // {}) + {version:1,mode:$mode,
            outbound_owned:($owned or $mode == "profile")}) |
        if $mode == "follow" then del(.xrm_ai_routing.domain_strategy_before)
        elif $strategy_changed then
            .xrm_ai_routing.domain_strategy_before //= $before[0].routing.domainStrategy
        else . end |
        if $mode == "profile" then .xrm_ai_routing.profile_name = $name
        else del(.xrm_ai_routing.profile_name) end' "$metadata" > "$meta_next" || return 1
    sync_ai_sniffing "$candidate" "$meta_next" || return 1
    resolve_xray_asset_context || return 1
    commit_xray_state "$candidate" "$meta_next" "" "$GEO_ASSET_PRIMARY" || return 1
    success "AI 分流设置已应用"
    if [ "$mode" != follow ] && [ "$strategy_changed" = true ]; then
        info "已启用按需域名解析，保持前置 IP 拦截优先；恢复跟随时自动还原"
    fi
    show_ai_routing_status
}

select_ai_outbound() {
    local snapshot count choice index profile
    echo -e "\n${cyan}=== AI 分流 ===${none}\n"
    show_ai_routing_status || return 1
    snapshot=$(mktemp) || return 1
    register_temp_file "$snapshot"
    write_profile_snapshot "$snapshot" || return 1
    count=$(jq 'length' "$snapshot") || return 1
    echo "1) 直连"
    echo "2) 跟随选择出口（默认）"
    jq -r 'to_entries[] | "\(.key + 3)) \(.value.name) - \(.value.server):\(.value.port)"' "$snapshot"
    echo "0) 返回"
    read -r -p "请选择 AI 出口 [0-$((count + 2))]: " choice || return 1
    case "$choice" in
        ''|0) return 0 ;;
        1) apply_ai_routing direct; return $? ;;
        2) apply_ai_routing follow; return $? ;;
    esac
    choice=$(normalize_decimal "$choice" 1 "$((count + 2))") || { error "无效的选择"; return 1; }
    # 前两项也接受十进制前导零。
    case "$choice" in
        1) apply_ai_routing direct; return $? ;;
        2) apply_ai_routing follow; return $? ;;
    esac
    index=$((choice - 3))
    profile=$(jq -ce --argjson index "$index" '.[$index]' "$snapshot") || return 1
    apply_ai_routing profile "$profile"
}

# --- 查看已保存的 SS / SS2022 配置 ---
list_ss_profiles() {
    init_outbound_profiles || return 1
    
    local count
    count=$(jq 'length' "$OUTBOUND_PROFILES_FILE") || return 1
    
    if [ "$count" -eq 0 ]; then
        info "暂无已保存的出口配置"
        return 1
    fi
    
    echo -e "\n${cyan}=== 已保存的 SS 出口配置 ===${none}\n"
    
    jq -r 'to_entries[] | "\(.key + 1)) \(.value.name) - \(.value.server):\(.value.port)"' "$OUTBOUND_PROFILES_FILE"
    
    return 0
}

# --- 选择并应用已保存的配置 ---
select_and_apply_profile() {
    local snapshot count choice index profile
    echo -e "\n${cyan}=== 选择出口 ===${none}\n"
    snapshot=$(mktemp) || return 1
    register_temp_file "$snapshot"
    write_profile_snapshot "$snapshot" || return 1
    count=$(jq 'length' "$snapshot") || return 1
    echo "1) 直连"
    jq -r 'to_entries[] | "\(.key + 2)) \(.value.name) - \(.value.server):\(.value.port)"' "$snapshot"
    echo "0) 返回"
    read -r -p "请选择出口 [0-$((count + 1))]: " choice || return 1
    case "$choice" in ''|0) return 0 ;; esac
    if ! choice=$(normalize_decimal "$choice" 1 "$((count + 1))"); then
        error "无效的选择"
        return 1
    fi
    if [ "$choice" -eq 1 ]; then apply_direct_outbound; return $?; fi
    index=$((choice - 2))
    profile=$(jq -ce --argjson index "$index" '.[$index]' "$snapshot") || return 1
    load_selected_profile "$profile" || return 1
    printf '\n正在应用出口：%s\n' "$SELECTED_PROFILE_NAME"
    apply_ss_outbound "$SELECTED_PROFILE_SERVER" "$SELECTED_PROFILE_PORT" \
        "$SELECTED_PROFILE_PASSWORD" "$SELECTED_PROFILE_METHOD"
}

# --- 删除已保存的 SS / SS2022 配置 ---
delete_ss_profile() {
    with_xrm_lock _delete_ss_profile "$@"
}

_delete_ss_profile() {
    if ! list_ss_profiles; then
        return 1
    fi
    
    local count
    count=$(jq 'length' "$OUTBOUND_PROFILES_FILE") || return 1
    
    echo
    local choice
    read -r -p "请选择要删除的配置编号 [1-$count] (0 返回): " choice || return 1
    
    if [ "$choice" = "0" ]; then
        return 0
    fi
    
    if ! choice=$(normalize_decimal "$choice" 1 "$count"); then
        error "无效的选择"
        return 1
    fi
    
    local index=$((10#$choice - 1))
    local profile
    profile=$(jq -ce --argjson index "$index" '.[$index] |
        select(type == "object" and (.name | type == "string"))' "$OUTBOUND_PROFILES_FILE") || {
        error "出口配置记录无效"
        return 1
    }
    
    local name
    name=$(printf '%s' "$profile" | jq -r '.name')
    
    # 二次确认
    local confirm
    read -r -p "确认删除配置 '$name'? [Y/n]: " confirm || return 1
    if [[ "$confirm" =~ ^[Nn]$ ]]; then
        info "已取消删除"
        return 0
    fi
    
    local temp
    temp=$(mktemp) || { error "创建临时文件失败"; return 1; }
    register_temp_file "$temp"
    
    jq --argjson index "$index" 'del(.[$index])' "$OUTBOUND_PROFILES_FILE" > "$temp" &&
        atomic_replace_file "$temp" "$OUTBOUND_PROFILES_FILE"
    
    if [ $? -eq 0 ]; then
        success "配置 '$name' 已删除"
    else
        error "删除失败"
        rm -f "$temp"
        return 1
    fi
}

change_outbound() {
    while true; do
        echo -e "\n${cyan}=== 出口管理 ===${none}\n"
        echo
        echo "1) 添加出口"
        echo "2) 查看出口"
        echo "3) 删除出口"
        echo "4) 选择出口"
        echo "5) AI 分流"
        echo "0) 返回主菜单"
        echo

        read -r -p "请选择操作 [0-5]: " outbound_choice || return 1

        case "$outbound_choice" in
        1)
            # 添加新的 SS / SS2022 出口
            info "添加 SS 出口"
            echo

            echo "1) 粘贴 SS URI（含 SS2022）"
            echo "2) 手动填写"
            read -r -p "请选择配置方式 [1-2]: " profile_input_mode || return 1

            local ss_name ss_server ss_port ss_password ss_method
            if [ "$profile_input_mode" = "1" ]; then
                read -r -p "请粘贴 SS URI: " ss_uri || return 1
                parse_ss_uri "$ss_uri" || continue
                ss_server="$URI_SERVER"
                ss_port="$URI_PORT"
                ss_password="$URI_PASSWORD"
                ss_method="$URI_METHOD"
                read -r -p "配置名称 (用于保存，默认: ss-${ss_port}): " ss_name || return 1
                [ -z "$ss_name" ] && ss_name="ss-${ss_port}"
            elif [ "$profile_input_mode" = "2" ]; then
                read -r -p "配置名称 (用于保存): " ss_name || return 1
                if [ -z "$ss_name" ]; then
                    error "配置名称不能为空"
                    continue
                fi
                read -r -p "服务器地址: " ss_server || return 1
                if [ -z "$ss_server" ]; then
                    error "服务器地址不能为空"
                    continue
                fi

                echo "1) 2022-blake3-aes-128-gcm"
                echo "2) 2022-blake3-aes-256-gcm"
                echo "3) 2022-blake3-chacha20-poly1305"
                echo "4) aes-128-gcm"
                echo "5) aes-256-gcm"
                read -r -p "请选择加密方式 [1-5，默认: 1]: " ss_method || return 1
                case "${ss_method:-1}" in
                    1)
                        ss_method="2022-blake3-aes-128-gcm"
                        ;;
                    2)
                        ss_method="2022-blake3-aes-256-gcm"
                        ;;
                    3)
                        ss_method="2022-blake3-chacha20-poly1305"
                        ;;
                    4)
                        ss_method="aes-128-gcm"
                        ;;
                    5)
                        ss_method="aes-256-gcm"
                        ;;
                    *)
                        error "无效的加密方式，请输入 1-5"
                        continue
                        ;;
                esac

                read -r -p "端口: " ss_port || return 1
                if ! ss_port=$(normalize_decimal "$ss_port" 1 65535); then
                    error "无效的端口号"
                    continue
                fi
                IFS= read -r -s -p "密码: " ss_password || return 1
                echo
                if [ -z "$ss_password" ]; then
                    error "密码不能为空"
                    continue
                fi
                validate_ss_password "$ss_method" "$ss_password" || continue
            else
                error "无效的配置方式"
                continue
            fi

            info "加密方法: $ss_method"
            if save_ss_profile "$ss_name" "$ss_server" "$ss_port" "$ss_password" "$ss_method"; then
                info "配置已保存，请使用选项 4 选择出口，或选项 5 设置 AI 分流"
            fi
            ;;
        2)
            # 查看已保存的配置
            list_ss_profiles
            ;;
        3)
            # 删除已保存的配置
            delete_ss_profile
            ;;
        4)
            select_and_apply_profile
            ;;
        5)
            select_ai_outbound
            ;;
        0)
            return 0
            ;;
        *)
            error "无效的选择"
            ;;
        esac
    done
}

# --- 节点管理菜单 ---
manage_nodes() {
    while true; do
        echo -e "\n${cyan}=== 管理节点 ===${none}\n"
        echo "1) 查看节点"
        echo "2) 删除节点"
        echo "0) 返回主菜单"
        echo

        local node_management_choice
        read -r -p "请选择操作 [0-2]: " node_management_choice || return 1

        case "$node_management_choice" in
        1)
            list_nodes
            ;;
        2)
            delete_node
            ;;
        0)
            return 0
            ;;
        *)
            error "无效的选择"
            ;;
        esac
    done
}

# --- 新增节点菜单 ---
add_node_menu() {
    while true; do
        echo -e "\n${cyan}=== 新增节点 ===${none}\n"
        echo "1) SS 节点（含 SS2022）"
        echo "2) vless reality vision 节点"
        echo "0) 返回主菜单"
        echo

        local node_choice
        read -r -p "请选择节点类型 [0-2]: " node_choice || return 1

        case "$node_choice" in
        1)
            add_ss_node
            ;;
        2)
            add_reality_node
            ;;
        0)
            return 0
            ;;
        *)
            error "无效的选择"
            ;;
        esac
    done
}

# --- Xray 管理菜单 ---
manage_xray() {
    while true; do
        echo -e "\n${cyan}=== 管理 Xray ===${none}\n"
        echo "1) 升级 Xray（最新正式版）"
        echo "2) 重启 Xray"
        echo "3) 查看状态"
        echo "4) 更新 Geo 数据"
        echo "5) 卸载 Xray"
        echo "0) 返回主菜单"
        echo
        local management_choice
        read -r -p "请选择操作 [0-5]: " management_choice || return 1
        case "$management_choice" in
            1) upgrade_xray ;;
            2) restart_xray ;;
            3) show_status ;;
            4) manage_geo_data ;;
            5) uninstall_xray ;;
            0) return 0 ;;
            *) error "无效的选择" ;;
        esac
    done
}

# --- 安装全局命令 ---
install_global_command() {
    local target="/usr/local/bin/xrm"
    local script_url="https://raw.githubusercontent.com/makemecoffee/quick_installation/refs/heads/master/xray_mini.sh"
    
    # 检查是否已安装
    if [ -f "$target" ] && [ -x "$target" ]; then
        local installed_version
        if installed_version=$(read_script_version "$target"); then
            success "全局命令 xrm 已安装，脚本版本: v${installed_version}"
        else
            success "全局命令 xrm 已安装（旧版无版本号，可从菜单更新）"
        fi
        return 0
    fi
    
    info "正在安装全局命令 xrm..."
    
    local tmpfile remote_version
    tmpfile=$(mktemp "${target}.tmp.XXXXXX") || {
        error "创建临时文件失败"
        return 1
    }
    register_temp_file "$tmpfile"

    # 先下载并校验，成功后再替换目标文件
    if ! curl -fsSL --max-time 60 "$script_url" -o "$tmpfile"; then
        rm -f "$tmpfile"
        error "全局命令安装失败"
        return 1
    fi

    if ! verify_github_file_digest "$tmpfile" \
        "https://api.github.com/repos/makemecoffee/quick_installation/contents/xray_mini.sh?ref=master"; then
        rm -f "$tmpfile"
        return 1
    fi

    if ! remote_version=$(validate_script_candidate "$tmpfile"); then
        rm -f "$tmpfile"
        return 1
    fi

    if ! chmod 755 "$tmpfile" || ! mv -f "$tmpfile" "$target"; then
        rm -f "$tmpfile"
        error "安装全局命令失败"
        return 1
    fi

    rm -f "$tmpfile"
    success "全局命令安装成功，脚本版本: v${remote_version}"
    info "现在可以在任何目录使用 xrm 命令"
}

is_valid_script_version() {
    [[ "$1" =~ ^(0|[1-9][0-9]{0,5})\.(0|[1-9][0-9]{0,5})\.(0|[1-9][0-9]{0,5})$ ]]
}

# 只读取版本声明，不执行下载文件或旧脚本。
read_script_version() {
    local version
    [ -f "$1" ] || return 1
    version=$(sed -n 's/^readonly SCRIPT_VERSION="\([0-9.]*\)"[[:space:]]*$/\1/p' "$1") || return 1
    is_valid_script_version "$version" || return 1
    printf '%s\n' "$version"
}

# 输出 -1 / 0 / 1，分别表示左侧版本低于 / 等于 / 高于右侧版本。
compare_script_versions() {
    is_valid_script_version "$1" && is_valid_script_version "$2" || return 1
    local -a left right
    local index left_number right_number
    IFS=. read -r -a left <<< "$1"
    IFS=. read -r -a right <<< "$2"
    for index in 0 1 2; do
        left_number=$((10#${left[index]}))
        right_number=$((10#${right[index]}))
        if [ "$left_number" -lt "$right_number" ]; then printf '%s\n' -1; return 0; fi
        if [ "$left_number" -gt "$right_number" ]; then printf '%s\n' 1; return 0; fi
    done
    printf '%s\n' 0
}

validate_script_candidate() {
    bash -n "$1" || { error "下载的脚本语法检查失败，保留原脚本"; return 1; }
    read_script_version "$1" || {
        error "远端脚本缺少有效版本号，请确认 GitHub master 已发布带版本号的脚本"
        return 1
    }
}

# --- 更新全局脚本 ---
update_script() {
    with_xrm_lock _update_script "$@"
}

_update_script() {
    local target="/usr/local/bin/xrm"
    local script_url="https://raw.githubusercontent.com/makemecoffee/quick_installation/refs/heads/master/xray_mini.sh"
    local tmpfile current_version="" current_label="未安装" remote_version comparison

    if [ -f "$target" ]; then
        if current_version=$(read_script_version "$target"); then
            current_label="v${current_version}"
        else
            current_label="旧版（无版本号）"
        fi
    fi
    info "已安装脚本版本: $current_label"
    info "正在检查 GitHub 上的脚本版本..."

    tmpfile=$(mktemp "${target}.tmp.XXXXXX") || {
        error "创建临时文件失败"
        return 1
    }
    register_temp_file "$tmpfile"

    if ! curl -fsSL --max-time 60 "$script_url" -o "$tmpfile"; then
        rm -f "$tmpfile"
        error "下载脚本失败"
        return 1
    fi

    if ! verify_github_file_digest "$tmpfile" \
        "https://api.github.com/repos/makemecoffee/quick_installation/contents/xray_mini.sh?ref=master"; then
        rm -f "$tmpfile"
        return 1
    fi

    if ! remote_version=$(validate_script_candidate "$tmpfile"); then
        rm -f "$tmpfile"
        return 1
    fi
    info "远端脚本版本: v${remote_version}"
    if [ -n "$current_version" ]; then
        comparison=$(compare_script_versions "$current_version" "$remote_version") || { rm -f "$tmpfile"; return 1; }
        if [ "$comparison" -eq 0 ]; then
            rm -f "$tmpfile"
            success "当前已是最新版本 v${current_version}，无需更新"
            if [ "$SCRIPT_VERSION" != "$current_version" ]; then
                info "当前会话仍为 v${SCRIPT_VERSION}，请退出后重新执行 xrm"
            fi
            return 0
        elif [ "$comparison" -gt 0 ]; then
            rm -f "$tmpfile"
            info "已安装版本 v${current_version} 高于远端 v${remote_version}，保留已安装版本"
            if [ "$SCRIPT_VERSION" != "$current_version" ]; then
                info "当前会话仍为 v${SCRIPT_VERSION}，请退出后重新执行 xrm"
            fi
            return 0
        fi
    fi

    if ! chmod 755 "$tmpfile" || ! mv -f "$tmpfile" "$target"; then
        rm -f "$tmpfile"
        error "更新全局命令失败"
        return 1
    fi

    rm -f "$tmpfile"
    success "脚本更新成功: ${current_label} → v${remote_version}"
    info "当前会话仍为 v${SCRIPT_VERSION}；请退出后重新执行 xrm，使用 v${remote_version}"
}

# --- 主菜单 ---
show_menu() {
    echo -e "\n${cyan}=== Xray 快速安装脚本 ===${none}"
    echo -e "${magenta}脚本版本: v${SCRIPT_VERSION}${none}"
    
    # 获取 Xray 版本并显示
    if [ -f "$XRAY_BINARY_PATH" ]; then
        local xray_version
        xray_version=$("$XRAY_BINARY_PATH" version 2>/dev/null | head -n 1 | awk '{print $2}')
        if [ -n "$xray_version" ]; then
            echo -e "${magenta}Xray 版本: ${xray_version}${none}\n"
        else
            echo ""
        fi
    else
        echo ""
    fi
    
    echo "1) 新增节点"
    echo "2) 管理节点"
    echo "3) 管理出口"
    echo "4) 管理 Xray"
    echo "5) 更新脚本"
    echo "0) 退出脚本"
    echo
}

# --- 查看服务状态 ---
show_status() {
    if [ "$OS_TYPE" = "debian" ]; then
        systemctl status xray --no-pager
    elif [ "$OS_TYPE" = "alpine" ]; then
        rc-service xray status
    fi
}

# --- 主函数 ---
check_geo_update_dependencies() {
    local dependency
    for dependency in curl jq openssl flock; do
        command -v "$dependency" >/dev/null 2>&1 || {
            error "Geo 自动更新缺少依赖 $dependency，请运行 xrm 安装所需依赖"
            return 1
        }
    done
    [ -x "$XRAY_BINARY_PATH" ] && [ -f "$XRAY_CONFIG_PATH" ] || {
        error "Geo 自动更新要求已有 Xray 核心和配置，请先完成安装"
        return 1
    }
}

main() {
    case "${1:-}" in
        --version|-v)
            printf 'xrm %s\n' "$SCRIPT_VERSION"
            return 0
            ;;
        --update-geo)
            umask 077
            install_xrm_traps
            check_root
            detect_os
            check_geo_update_dependencies || return 1
            update_geo_data true
            return $?
            ;;
    esac
    umask 077
    install_xrm_traps

    check_root
    detect_os
    check_dependencies || exit 1
    
    # 安装 Xray
    install_xray || exit 1
    
    # 初始化配置
    init_config || exit 1

    # 保留既有配置的所有者和权限，兼容以非 root 用户运行的 Xray 服务。
    chmod 600 "$YAML_NODES_FILE" "$NODES_META_FILE" "$OUTBOUND_PROFILES_FILE" 2>/dev/null || true

    # 仅在启动时确保一次路由策略
    ensure_routing_policy || exit 1
    
    # 第一次运行时安装全局命令
    if [ ! -f "/usr/local/bin/xrm" ]; then
        install_global_command
    fi
    
    # 主循环
    while true; do
        show_menu
        read -r -p "请选择操作 [0-5]: " choice || break
        
        case $choice in
            1)
                add_node_menu
                ;;
            2)
                manage_nodes
                ;;
            3)
                change_outbound
                ;;
            4)
                manage_xray
                ;;
            5)
                update_script
                ;;
            0)
                success "退出脚本"
                exit 0
                ;;
            *)
                error "无效的选择"
                ;;
        esac
    done
}

# --- 脚本入口 ---
main "$@"
