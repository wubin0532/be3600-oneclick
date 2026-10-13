#!/bin/sh
# GL-BE3600: remove GL vendor Tailscale/AdGuard Home, install latest releases,
# and restore the actual OpenWrt description. No login credentials are needed.
set -eu
umask 077

MODE=apply
WORK=
LOCK=
CHANGED=0
TS_VENDOR=0
TS_CUSTOM=0
ADG_VENDOR=0
REMOVE_PACKAGES=

say() { printf '%s\n' "$*"; }
fail() { say "错误：$*" >&2; exit 1; }
usage() {
    cat <<'EOF'
用法：sh be3600-oneclick.sh [--check | --help]
默认执行：
  1. 卸载 GL 原厂 Tailscale 和 AdGuard Home 的专属组件与数据。
  2. 从各自 GitHub 仓库获取最新正式版 AndeyProxy、Tailscale LuCI、ScreenPlus。
  3. 恢复只读固件记录的真实 OpenWrt 版本描述。
--check：检查环境、下载并校验发布包、预检依赖；不卸载、不安装、不改配置。
重复执行保留自定义插件的配置、Tailscale 身份和启停状态；不自动降级。
EOF
}
cleanup() {
    result=$?
    trap - EXIT HUP INT TERM
    [ -z "$WORK" ] || rm -rf "$WORK"
    [ -z "$LOCK" ] || rmdir "$LOCK" 2>/dev/null || :
    if [ "$result" -ne 0 ] && [ "$CHANGED" -eq 1 ]; then
        say '执行中途停止。此前成功的更改可能已生效；修正报错后可重复运行。' >&2
    fi
    exit "$result"
}
installed() {
    opkg status "$1" 2>/dev/null | grep -q '^Status: .* installed$'
}
package_version() {
    opkg status "$1" 2>/dev/null | awk '/^Version: / {print $2; exit}'
}
valid_version() {
    case "$1" in ''|*[!a-zA-Z0-9.+_-]*) return 1;; esac
}
no_downgrade() {
    if installed "$1"; then
        current=$(package_version "$1")
        # opkg uses '>' for >=; '>>' is its strict greater-than operator.
        if opkg compare-versions "$current" '>>' "$2"; then
            fail "$1 已安装 ${current}，当前发布包为 $2；拒绝自动降级。"
        fi
    fi
}
files_present() {
    [ -s "$1" ] || return 1
    while IFS= read -r path; do
        [ -z "$path" ] && continue
        case "$path" in /*) ;; *) path=/$path;; esac
        [ -e "$path" ] || [ -L "$path" ] || return 1
    done < "$1"
}
stop_service() {
    if [ -x "/etc/init.d/$1" ]; then
        "/etc/init.d/$1" stop >/dev/null 2>&1 || fail "停止 $1 失败。"
        "/etc/init.d/$1" disable >/dev/null 2>&1 || fail "禁用 $1 自启动失败。"
    fi
}
drop_sections() {
    config=$1
    needle=$2
    # Re-read after each deletion: anonymous UCI section indices can shift.
    while :; do
        data=$(uci -q show "$config" 2>/dev/null || :)
        section=$(printf '%s\n' "$data" | awk -F= -v pattern="$needle" '
            tolower($0) ~ pattern { split($1, part, "."); print part[2]; exit }')
        [ -n "$section" ] || break
        uci -q delete "$config.$section" || fail "清除 $config.$section 失败。"
    done
    # A missing config does not need a commit.
    [ ! -f "/etc/config/$config" ] || uci commit "$config"
}
preflight() {
    [ "$(id -u)" -eq 0 ] || fail '请在路由器上以 root 运行。'
    [ "$(uname -s)" = Linux ] || fail '此脚本只能在 GL-BE3600 路由器上运行。'
    [ "$(uname -m)" = aarch64 ] || fail 'CPU 架构不是 aarch64。'
    for tool in opkg ubus uci jsonfilter curl sha256sum awk sed grep sort tar df mktemp pidof; do
        command -v "$tool" >/dev/null 2>&1 || fail "缺少命令：$tool"
    done
    board=$(ubus call system board)
    model=$(printf '%s' "$board" | jsonfilter -e '@.model')
    case "$model" in *BE3600*) ;; *) fail "机型不匹配：$model";; esac
    arch=$(sed -n "s/^DISTRIB_ARCH='\(.*\)'$/\1/p" /rom/etc/openwrt_release)
    [ "$arch" = aarch64_cortex-a53_neon-vfpv4 ] || fail "固件架构不匹配：$arch"
    [ -c /dev/net/tun ] || fail '缺少与当前内核匹配的 TUN 支持。'
    for path in /lib/functions.sh /etc/rc.common /usr/share/luci /etc/init.d/rpcd /etc/init.d/firewall; do
        [ -e "$path" ] || fail "缺少固件框架：$path"
    done
    command -v fw4 >/dev/null 2>&1 || fail '需要 firewall4。'
    if pidof opkg >/dev/null 2>&1; then fail '另一个 opkg 操作正在运行，请稍后再试。'; fi
    pending=$(uci changes firewall; uci changes network)
    [ -z "$pending" ] || fail '网络或防火墙有未保存的修改，请先保存或放弃修改。'
    for package in tailscale-luci-run tailscale-luci luci-app-tailscale luci-app-tailscaler; do
        if installed "$package"; then TS_CUSTOM=1; fi
    done
    [ ! -s /usr/share/tailscale-luci/installed-files ] || TS_CUSTOM=1
    [ ! -f /usr/lib/tailscale-luci.sh ] || TS_CUSTOM=1
    for package in gl-sdk4-ui-tailscaleview gl-sdk4-tailscale tailscale; do
        if installed "$package"; then TS_VENDOR=1; REMOVE_PACKAGES="$REMOVE_PACKAGES $package"; fi
    done
    if [ "$TS_VENDOR" -eq 1 ] && [ "$TS_CUSTOM" -eq 1 ]; then
        fail '原厂和自定义 Tailscale 组件同时存在，需先人工确认文件归属；没有执行清理。'
    fi
    if installed luci-app-tailscale || installed luci-app-tailscaler; then
        fail '检测到其他维护者的 Tailscale 插件；本脚本不会删除它们。'
    fi
    if installed adguardhome || installed luci-app-adguardhome; then
        fail '检测到非 GL 原厂的 AdGuard Home 软件包；本脚本不会删除它们。'
    fi
    for package in gl-sdk4-ui-adguardhome gl-sdk4-adguardhome adguardhome-conntrack; do
        if installed "$package"; then ADG_VENDOR=1; REMOVE_PACKAGES="$REMOVE_PACKAGES $package"; fi
    done
    # Native package records can already be gone while GL-specific files remain.
    if [ "$TS_CUSTOM" -eq 0 ] && { [ -f /usr/bin/gl_tailscale ] || [ -f /etc/firewall.tailscale.sh ]; }; then TS_VENDOR=1; fi
    if [ -f /usr/lib/oui-httpd/rpc/adguardhome ] || [ -d /etc/AdGuardHome ]; then ADG_VENDOR=1; fi
    tmp_kb=$(df -Pk /tmp | awk 'END {print $4}')
    case "$tmp_kb" in ''|*[!0-9]*) fail '无法确定临时空间。';; esac
    [ "$tmp_kb" -ge 131072 ] || fail '至少需要 128 MiB 临时空闲空间。'
    free_kb=$(df -Pk /overlay | awk 'END {print $4}')
    case "$free_kb" in ''|*[!0-9]*) fail '无法确定可写空间。';; esac
    [ "$free_kb" -ge 98304 ] || fail '至少需要 96 MiB 可写空闲空间。'
    say "机型：${model}；可写空闲空间：${free_kb} KiB。"
    if [ -n "$REMOVE_PACKAGES" ]; then
        say "原厂待卸载组件：$REMOVE_PACKAGES"
        # Names originate only from the fixed package allowlist above.
        # shellcheck disable=SC2086
        opkg --noaction remove $REMOVE_PACKAGES || fail '原厂组件依赖预检失败。'
    fi
}
fetch_release() {
    repo=$1
    key=$2
    pattern=$3
    release=$WORK/$key-release.json
    curl -fSL --retry 2 --connect-timeout 15 --max-time 90 \
        -H 'Accept: application/vnd.github+json' -H 'User-Agent: be3600-oneclick' \
        -o "$release" "https://api.github.com/repos/$repo/releases/latest" || fail "获取 $repo 最新正式版失败。"
    tag=$(jsonfilter -i "$release" -e '@.tag_name')
    valid_version "$tag" || fail "$repo 发布标签格式不支持：$tag"
    [ "$(jsonfilter -i "$release" -e '@.draft')" = false ] || fail '拒绝草稿发布。'
    [ "$(jsonfilter -i "$release" -e '@.prerelease')" = false ] || fail '拒绝预发布版本。'
    index=0
    count=0
    asset=
    digest=
    while :; do
        name=$(jsonfilter -i "$release" -e "@.assets[$index].name" 2>/dev/null || :)
        [ -n "$name" ] || break
        # The pattern is a fixed architecture glob supplied by this script.
        # shellcheck disable=SC2254
        case "$name" in
            $pattern)
                count=$((count + 1))
                asset=$name
                digest=$(jsonfilter -i "$release" -e "@.assets[$index].digest")
                ;;
        esac
        index=$((index + 1))
    done
    [ "$count" -eq 1 ] || fail "$repo 应只有一个匹配架构的包，实际找到 $count 个。"
    valid_version "$asset" || fail '发布资产文件名格式不支持。'
    hash=${digest#sha256:}
    [ "$hash" != "$digest" ] && [ "${#hash}" -eq 64 ] || fail "$asset 缺少发布端 SHA-256；停止执行。"
    case "$hash" in *[!a-fA-F0-9]*) fail 'SHA-256 格式无效。';; esac
    curl -fSL --retry 2 --connect-timeout 15 --max-time 300 \
        -o "$WORK/$asset" "https://github.com/$repo/releases/download/$tag/$asset" || fail "下载 $asset 失败。"
    printf '%s  %s\n' "$hash" "$WORK/$asset" | sha256sum -c - || fail "$asset 校验失败。"
    printf '%s\n' "$asset" > "$WORK/$key-name"
    printf '%s\n' "$tag" > "$WORK/$key-tag"
    say "${repo}：${tag}；已校验 ${asset}。"
}
prepare_packages() {
    fetch_release wubin0532/Reverse_Proxy andey 'luci-app-andeyproxy_*_aarch64_cortex-a53.ipk'
    fetch_release wubin0532/tailscale tailscale 'tailscale-luci_*_arm64.run'
    fetch_release VAIO-Dong/gl-be3600-screenplus screenplus 'screenplus_*_aarch64_cortex-a53_neon-vfpv4.ipk'
    ANDEY_ASSET=$(cat "$WORK/andey-name")
    TS_ASSET=$(cat "$WORK/tailscale-name")
    SCREEN_ASSET=$(cat "$WORK/screenplus-name")
    ANDEY_VERSION=${ANDEY_ASSET#luci-app-andeyproxy_}
    ANDEY_VERSION=${ANDEY_VERSION%_aarch64_cortex-a53.ipk}
    TS_VERSION=${TS_ASSET#tailscale-luci_}
    TS_VERSION=${TS_VERSION%_arm64.run}
    SCREEN_VERSION=${SCREEN_ASSET#screenplus_}
    SCREEN_VERSION=${SCREEN_VERSION%_aarch64_cortex-a53_neon-vfpv4.ipk}
    no_downgrade luci-app-andeyproxy "$ANDEY_VERSION"
    no_downgrade tailscale-luci-run "$TS_VERSION"
    no_downgrade screenplus "$SCREEN_VERSION"
    sh "$WORK/$TS_ASSET" --check || fail 'Tailscale 内置载荷校验失败。'
    opkg --noaction install "$WORK/$ANDEY_ASSET" "$WORK/$SCREEN_ASSET" || fail 'IPK 依赖或架构预检失败。'
}
remove_vendor() {
    say '清理 GL 原厂专属组件。'
    if [ "$ADG_VENDOR" -eq 1 ]; then
        if uci -q get adguardhome.config >/dev/null 2>&1; then
            uci set adguardhome.config.enabled=0
            uci commit adguardhome
        fi
        stop_service adguardhome
    fi
    [ "$TS_VENDOR" -eq 0 ] || stop_service tailscale
    if [ -n "$REMOVE_PACKAGES" ]; then
        # shellcheck disable=SC2086
        opkg remove $REMOVE_PACKAGES || fail '原厂组件卸载失败。'
    fi
    if [ "$ADG_VENDOR" -eq 1 ]; then
        mounts=$(awk '$2 ~ /^\/etc\/AdGuardHome(\/|$)/ {print $2}' /proc/mounts | sort -r)
        for mountpoint in $mounts; do umount "$mountpoint" || fail "无法卸载 ${mountpoint}。"; done
        rm -rf /etc/AdGuardHome /tmp/AGH_data
        rm -f /etc/config/adguardhome /etc/config/adguardhome-opkg /etc/config/adguardhome.bak \
            /etc/init.d/adguardhome /etc/gl-switch.d/adguardhome.sh /etc/nginx/gl-conf.d/adg.conf \
            /etc/uci-defaults/99-adguardhome /usr/bin/AdGuardHome /usr/lib/oui-httpd/rpc/adguardhome \
            /usr/share/oui/menu.d/adguardhome.json /lib/upgrade/keep.d/adguardhome-conntrack
        rm -f /etc/rc.d/S*adguardhome /etc/rc.d/K*adguardhome /tmp/lock/procd_adguardhome.lock
        drop_sections firewall adguardhome
    fi
    if [ "$TS_VENDOR" -eq 1 ]; then
        # This branch is unreachable when a custom Tailscale identity is present.
        rm -rf /etc/tailscale /tmp/lib/tailscale /var/run/tailscale
        rm -f /etc/config/tailscale /etc/config/tailscale-opkg /etc/config/tailscale.bak \
            /etc/init.d/tailscale /etc/firewall.tailscale.sh /usr/bin/gl_tailscale /usr/bin/ts_killswitch \
            /usr/lib/oui-httpd/rpc/tailscale /usr/sbin/tailscale /usr/sbin/tailscaled \
            /etc/hotplug.d/net/19-tailscale-net /etc/hotplug.d/iface/19-tailscale-iface \
            /usr/share/oui/menu.d/tailscaleview.json /lib/upgrade/keep.d/gl-sdk4-tailscale /lib/upgrade/keep.d/tailscale
        rm -f /etc/rc.d/S*tailscale /etc/rc.d/K*tailscale /tmp/lock/procd_tailscale.lock
        drop_sections firewall tailscale
        drop_sections network tailscale
        drop_sections ucitrack tailscale
    fi
    if [ "$ADG_VENDOR" -eq 1 ] || [ "$TS_VENDOR" -eq 1 ]; then
        # Clear a side-switch assignment to a removed vendor feature.
        switch_func=$(uci -q get 'switch-button.@main[0].func' 2>/dev/null || :)
        case "$switch_func" in tailscale|adguardhome)
            uci -q delete 'switch-button.@main[0].func'
            uci commit switch-button;;
        esac
        /etc/init.d/firewall reload || fail '防火墙重载失败。'
    fi
}
ensure_ipk() {
    package=$1
    version=$2
    file=$3
    if installed "$package" && [ "$(package_version "$package")" = "$version" ]; then
        if files_present "/usr/lib/opkg/info/$package.list"; then
            say "$package $version 已安装，保留现有配置。"
            return
        fi
        opkg install --force-reinstall "$file"
    else
        opkg install "$file"
    fi
    installed "$package" && [ "$(package_version "$package")" = "$version" ] || fail "$package 版本验证失败。"
}
install_plugins() {
    ensure_ipk luci-app-andeyproxy "$ANDEY_VERSION" "$WORK/$ANDEY_ASSET"
    if installed tailscale-luci-run && [ "$(package_version tailscale-luci-run)" = "$TS_VERSION" ] \
        && files_present /usr/share/tailscale-luci/installed-files \
        && /usr/sbin/tailscale version >/dev/null 2>&1; then
        say "Tailscale LuCI $TS_VERSION 已安装，保留身份、配置和启停状态。"
    else
        sh "$WORK/$TS_ASSET" --install || fail 'Tailscale 安装器失败。'
    fi
    installed tailscale-luci-run && [ "$(package_version tailscale-luci-run)" = "$TS_VERSION" ] || fail 'Tailscale 管理包版本验证失败。'
    ensure_ipk screenplus "$SCREEN_VERSION" "$WORK/$SCREEN_ASSET"
}
restore_description() {
    firmware_id=$(sed -n "s/^DISTRIB_ID='\(.*\)'$/\1/p" /rom/etc/openwrt_release)
    firmware_release=$(sed -n "s/^DISTRIB_RELEASE='\(.*\)'$/\1/p" /rom/etc/openwrt_release)
    firmware_revision=$(sed -n "s/^DISTRIB_REVISION='\(.*\)'$/\1/p" /rom/etc/openwrt_release)
    [ -n "$firmware_id" ] && [ -n "$firmware_release" ] || fail '只读固件中缺少实际版本信息。'
    actual="$firmware_id $firmware_release"
    [ -z "$firmware_revision" ] || actual="$actual $firmware_revision"
    # Reject characters that cannot be safely represented by the existing format.
    case "$actual" in *"'"*) fail '实际版本描述包含不支持的引号。';; esac
    [ "$(grep -c '^DISTRIB_DESCRIPTION=' /etc/openwrt_release)" -eq 1 ] || fail '当前版本描述字段格式异常。'
    tmp=$(mktemp /etc/.openwrt-release.XXXXXX)
    awk -v description="$actual" '
        /^DISTRIB_DESCRIPTION=/ { printf "DISTRIB_DESCRIPTION=\047%s\047\n", description; next }
        {print}
    ' /etc/openwrt_release > "$tmp"
    chmod 644 "$tmp"
    if cmp -s "$tmp" /etc/openwrt_release; then rm -f "$tmp"; else mv -f "$tmp" /etc/openwrt_release; fi
    live=$(ubus call system board | jsonfilter -e '@.release.description')
    [ "$live" = "$actual" ] || fail '系统返回的版本描述尚未匹配。'
    say "OpenWrt 版本显示：${actual}。"
}
verify_result() {
    for package in gl-sdk4-ui-tailscaleview gl-sdk4-tailscale tailscale gl-sdk4-ui-adguardhome gl-sdk4-adguardhome adguardhome-conntrack; do
        if installed "$package"; then fail "仍有原厂组件：$package"; fi
    done
    actual_andey=$(/usr/bin/andey-proxy -v)
    expected_andey=$(cat "$WORK/andey-tag")
    [ "$actual_andey" = "${expected_andey#v}" ] || fail 'AndeyProxy 主程序与发布版本不一致。'
    say "AndeyProxy 主程序：$actual_andey"
    /usr/sbin/tailscale version
    if [ "$(uci -q get screenplus.main.enabled 2>/dev/null || :)" = 1 ]; then
        count=0
        until pidof screenplus >/dev/null; do
            count=$((count + 1))
            [ "$count" -lt 10 ] || fail 'ScreenPlus 已启用但进程没有运行。'
            sleep 1
        done
    fi
    [ -f /usr/share/luci/menu.d/luci-app-andeyproxy.json ] || fail 'AndeyProxy 菜单缺失。'
    [ -f /usr/share/luci/menu.d/luci-app-tailscale.json ] || fail 'Tailscale 菜单缺失。'
    [ -f /usr/share/luci/menu.d/luci-app-screenplus.json ] || fail 'ScreenPlus 菜单缺失。'
    /usr/sbin/nginx -t || fail '管理页 Web 服务配置检查失败。'
    /etc/init.d/nginx reload
    /etc/init.d/rpcd restart
    say '完成。最新发布版本：'
    say "  AndeyProxy：$(cat "$WORK/andey-tag")，软件包 $ANDEY_VERSION"
    say "  Tailscale LuCI：$(cat "$WORK/tailscale-tag")，安装器 $TS_VERSION"
    say "  ScreenPlus：$(cat "$WORK/screenplus-tag")，软件包 $SCREEN_VERSION"
    say '新装的 AndeyProxy / Tailscale 保持默认关闭；Tailscale 需在 LuCI 中启用并登录。'
    say '已存在的自定义插件保留配置及启停状态。请刷新 GL / LuCI 管理页面。'
    df -h /overlay
}
main() {
    case "${1:-}" in
        '') [ "$#" -eq 0 ] || fail '参数过多。';;
        --check) [ "$#" -eq 1 ] || fail '参数过多。'; MODE=check;;
        --help|-h) usage; exit 0;;
        *) usage; fail '不支持的参数。';;
    esac
    preflight
    mkdir /tmp/be3600-oneclick.lock 2>/dev/null || fail '同类脚本正在运行，或上次异常退出后锁目录仍在。'
    LOCK=/tmp/be3600-oneclick.lock
    trap cleanup EXIT
    trap 'exit 130' HUP INT TERM
    WORK=$(mktemp -d /tmp/be3600-oneclick.XXXXXX)
    prepare_packages
    if [ "$MODE" = check ]; then
        say '检查通过。安装包已校验，未卸载、未安装、未修改系统配置。'
        return
    fi
    CHANGED=1
    remove_vendor
    install_plugins
    restore_description
    verify_result
}
main "$@"
