#!/bin/sh
# shellcheck shell=dash

REPO="https://api.github.com/repos/ynovka/podkop/releases/latest"
DOWNLOAD_DIR="/tmp/podkop"
COUNT=3

# podkop-engine: sing-box with the xhttp transport, installed instead of the sing-box of OpenWrt
ENGINE_REPO="https://api.github.com/repos/podkop-net/podkop-engine/releases/latest"
ENGINE_DIR="/tmp/podkop-engine"
OPENWRT_RELEASE_FILE="/etc/openwrt_release"
PODKOP_INIT_SCRIPT="/etc/init.d/podkop"
ENGINE_FILE=""
ENGINE_STOPPED_PODKOP=0

# Cached flag to switch between ipk or apk package managers
PKG_IS_APK=0
command -v apk >/dev/null 2>&1 && PKG_IS_APK=1

rm -rf "$DOWNLOAD_DIR" "$ENGINE_DIR"
mkdir -p "$DOWNLOAD_DIR" "$ENGINE_DIR"

msg() {
    printf "\033[32;1m%s\033[0m\n" "$1"
}

pkg_is_installed () {
    local pkg_name="$1"

    if [ "$PKG_IS_APK" -eq 1 ]; then
        # grep -q should work without change based on example from documentation
        # apk list --installed --providers dnsmasq
        # <dnsmasq> dnsmasq-full-2.90-r3 x86_64 {feeds/base/package/network/services/dnsmasq} (GPL-2.0) [installed]
        apk list --installed | grep -q "$pkg_name"
    else
        opkg list-installed | grep -q "$pkg_name"
    fi
}

pkg_remove() {
    local pkg_name="$1"

    if [ "$PKG_IS_APK" -eq 1 ]; then
        # TODO: check --force-depends flag
        # Nothing here: https://openwrt.org/docs/guide-user/additional-software/opkg-to-apk-cheatsheet
        apk del "$pkg_name"
    else
        opkg remove --force-depends "$pkg_name"
    fi
}

pkg_list_update() {
    if [ "$PKG_IS_APK" -eq 1 ]; then
        apk update
    else
        opkg update
    fi
}

pkg_install() {
    local pkg_file="$1"

    if [ "$PKG_IS_APK" -eq 1 ]; then
        # Can't install without flag based on info from documentation
        # If you're installing a non-standard (self-built) package, use the --allow-untrusted option:
        apk add --allow-untrusted "$pkg_file"
    else
        opkg install "$pkg_file"
    fi
}

update_config() {
    printf "\033[48;5;196m\033[1m╔══════════════════════════════════════════════════════════════════════╗\033[0m\n"
    printf "\033[48;5;196m\033[1m║ ! Обнаружена старая версия podkop.                                   ║\033[0m\n"
    printf "\033[48;5;196m\033[1m║ Если продолжите обновление, вам потребуется настроить Podkop заново. ║\033[0m\n"
    printf "\033[48;5;196m\033[1m║ Старая конфигурация будет сохранена в /etc/config/podkop-070         ║\033[0m\n"
    printf "\033[48;5;196m\033[1m║ Подробности: https://github.com/itdoginfo/podkop                     ║\033[0m\n"
    printf "\033[48;5;196m\033[1m║ Точно хотите продолжить?                                             ║\033[0m\n"
    printf "\033[48;5;196m\033[1m╚══════════════════════════════════════════════════════════════════════╝\033[0m\n"

    echo ""

    printf "\033[48;5;196m\033[1m╔══════════════════════════════════════════════════════════════════════╗\033[0m\n"
    printf "\033[48;5;196m\033[1m║ ! Detected old podkop version.                                       ║\033[0m\n"
    printf "\033[48;5;196m\033[1m║ If you continue the update, you will need to RECONFIGURE podkop.     ║\033[0m\n"
    printf "\033[48;5;196m\033[1m║ Your old configuration will be saved to /etc/config/podkop-070       ║\033[0m\n"
    printf "\033[48;5;196m\033[1m║ Details: https://github.com/itdoginfo/podkop                         ║\033[0m\n"
    printf "\033[48;5;196m\033[1m║ Are you sure you want to continue?                                   ║\033[0m\n"
    printf "\033[48;5;196m\033[1m╚══════════════════════════════════════════════════════════════════════╝\033[0m\n"

    msg "Continue? (yes/no)"

    while true; do
            read -r -p '' CONFIG_UPDATE
            case $CONFIG_UPDATE in

            yes|y|Y)
                mv /etc/config/podkop /etc/config/podkop-070
                wget -O /etc/config/podkop https://raw.githubusercontent.com/ynovka/podkop/refs/heads/main/podkop/files/etc/config/podkop
                msg "Podkop config has been reset to default. Your old config saved in /etc/config/podkop-070"
                break
                ;;
            *)
                msg "Exit"
                exit 1
                ;;
        esac
    done
}

# The architecture of packages, as in the names of the files of podkop-engine
pkg_arch() {
    local arch

    arch=$(sed -n "s/^DISTRIB_ARCH='\(.*\)'/\1/p" "$OPENWRT_RELEASE_FILE" 2>/dev/null)
    if [ -z "$arch" ] && [ "$PKG_IS_APK" -eq 1 ]; then
        arch=$(apk --print-arch 2>/dev/null)
    fi

    echo "$arch"
}

# The installed sing-box has the xhttp transport: podkop-engine says so in the Features line, sing-box-extended
# is recognized by its version
sing_box_has_xhttp() {
    local version_output

    command -v sing-box >/dev/null 2>&1 || return 1
    version_output=$(sing-box version 2>/dev/null)

    echo "$version_output" | grep -q '^Features:.*transport.xhttp' && return 0
    echo "$version_output" | head -n 1 | grep -q extended && return 0

    return 1
}

# Downloads a file of a release through api.github.com, with retries
download_file() {
    local url="$1"
    local filepath="$2"
    local attempt=0

    while [ $attempt -lt $COUNT ]; do
        if wget -q --header="Accept: application/octet-stream" -O "$filepath" "$url" && [ -s "$filepath" ]; then
            return 0
        fi
        rm -f "$filepath"
        attempt=$((attempt+1))
    done

    return 1
}

# Decides whether podkop-engine is installed and downloads it. The xhttp servers of subscriptions need a sing-box
# that has the xhttp transport, and the one of OpenWrt does not. PODKOP_ENGINE=yes installs it without asking,
# PODKOP_ENGINE=no never does.
engine_prepare() {
    local release_file="$ENGINE_DIR/release.json"
    local pkg_ext arch answer name url sums_url expected actual

    case "$PODKOP_ENGINE" in
    no | n | 0)
        return 0
        ;;
    esac

    if sing_box_has_xhttp; then
        msg "Установленный sing-box уже поддерживает xhttp (The installed sing-box already supports xhttp)"
        return 0
    fi

    arch=$(pkg_arch)
    if [ -z "$arch" ]; then
        msg "Не удалось определить архитектуру: podkop-engine не устанавливается (Cannot detect the architecture: podkop-engine is skipped)"
        return 0
    fi

    if [ "$PKG_IS_APK" -eq 1 ]; then
        pkg_ext=apk
    else
        pkg_ext=ipk
    fi

    if ! wget -qO "$release_file" "$ENGINE_REPO" 2>/dev/null || [ ! -s "$release_file" ]; then
        msg "Не удалось получить список релизов podkop-engine: он не устанавливается (Cannot get the release of podkop-engine: it is skipped)"
        return 0
    fi

    # "podkop-engine_" and not "podkop-engine-full_": the full build is not needed by podkop
    name=$(tr '{' '\n' < "$release_file" | sed -n "s|.*\"name\":\"\(podkop-engine_[^\"]*_openwrt_${arch}\.$pkg_ext\)\".*|\1|p" | head -n 1)
    url=$(tr '{' '\n' < "$release_file" | sed -n "s|.*\"url\":\"\([^\"]*/releases/assets/[0-9]*\)\".*\"name\":\"$name\".*|\1|p" | head -n 1)
    if [ -z "$name" ] || [ -z "$url" ]; then
        msg "Для архитектуры $arch нет podkop-engine: он не устанавливается, xhttp-серверы работать не будут (No podkop-engine for $arch: it is skipped, xhttp servers will not work)"
        return 0
    fi

    if [ -z "$PODKOP_ENGINE" ]; then
        msg "Для серверов с xhttp нужен sing-box с поддержкой xhttp. Заменить sing-box на podkop-engine ($name)? [Y/n]"
        msg "(xhttp servers need a sing-box with the xhttp transport. Replace sing-box with podkop-engine?)"
        read -r -p '' answer
        case "$answer" in
        n | N | no | No)
            msg "podkop-engine не устанавливается (podkop-engine is skipped)"
            return 0
            ;;
        esac
    fi

    msg "Download $name..."
    if ! download_file "$url" "$ENGINE_DIR/$name"; then
        msg "Не удалось скачать $name: podkop-engine не устанавливается (Cannot download $name: it is skipped)"
        return 0
    fi

    # The checksums are in the same release: they catch a damaged download
    sums_url=$(tr '{' '\n' < "$release_file" | sed -n "s|.*\"url\":\"\([^\"]*/releases/assets/[0-9]*\)\".*\"name\":\"SHA256SUMS\".*|\1|p" | head -n 1)
    if [ -n "$sums_url" ] && download_file "$sums_url" "$ENGINE_DIR/SHA256SUMS"; then
        expected=$(awk -v n="$name" '$2 == n || $2 == "*" n { print $1 }' "$ENGINE_DIR/SHA256SUMS" | head -n 1)
        actual=$(sha256sum "$ENGINE_DIR/$name" | awk '{ print $1 }')
        if [ -z "$expected" ] || [ "$expected" != "$actual" ]; then
            msg "Контрольная сумма $name не совпала: podkop-engine не устанавливается (Checksum of $name does not match: it is skipped)"
            rm -f "$ENGINE_DIR/$name"
            return 0
        fi
        msg "$name: checksum OK"
    else
        msg "Не удалось проверить контрольную сумму $name (Cannot check the checksum of $name)"
    fi

    ENGINE_FILE="$ENGINE_DIR/$name"
}

# Replaces the sing-box with the downloaded podkop-engine. It is done with podkop stopped: while it works, the DNS of
# the router is served by sing-box, and the packages are replaced one after another. On a failure the sing-box of
# OpenWrt is put back.
engine_install() {
    [ -n "$ENGINE_FILE" ] || return 0

    if [ -f "$PODKOP_INIT_SCRIPT" ] && { service podkop running >/dev/null 2>&1 || pidof sing-box >/dev/null 2>&1; }; then
        msg "Stopping podkop..."
        service podkop stop
        ENGINE_STOPPED_PODKOP=1
    fi

    msg "Installing podkop-engine..."
    if [ "$PKG_IS_APK" -eq 1 ]; then
        apk add --allow-untrusted "$ENGINE_FILE"
    else
        pkg_is_installed "^sing-box" && opkg remove --force-depends sing-box sing-box-tiny
        opkg install "$ENGINE_FILE"
    fi

    if sing_box_has_xhttp; then
        msg "$(sing-box version | head -n 1)"
        return 0
    fi

    msg "Не удалось установить podkop-engine, возвращаю sing-box из репозитория (podkop-engine failed, restoring sing-box)"
    if [ "$PKG_IS_APK" -eq 1 ]; then
        apk add sing-box
    else
        opkg install sing-box
    fi
}

main() {
    check_system
    sing_box

    /usr/sbin/ntpd -q -p 194.190.168.1 -p 216.239.35.0 -p 216.239.35.4 -p 162.159.200.1 -p 162.159.200.123

    pkg_list_update || { echo "Packages list update failed"; exit 1; }

    if [ -f "/etc/init.d/podkop" ]; then
        msg "Podkop is already installed. Upgrading..."
    else
        msg "Installing podkop..."
    fi

    if command -v curl >/dev/null 2>&1; then
        check_response=$(curl -s "https://api.github.com/repos/ynovka/podkop/releases/latest")

        if echo "$check_response" | grep -q 'API rate limit '; then
            msg "You've reached the GitHub rate limit. Repeat in five minutes."
            exit 1
        fi
    fi

    local pkg_ext
    if [ "$PKG_IS_APK" -eq 1 ]; then
        pkg_ext=apk
    else
        pkg_ext=ipk
    fi

    engine_prepare

    # Download assets through api.github.com, not browser_download_url: the 302 from
    # github.com carries a ~9KB Content-Security-Policy header and uclient-fetch
    # (/usr/bin/wget) stalls until timeout on header lines over its 4KB read buffer
    wget -qO- "$REPO" | tr '{' '\n' \
        | sed -n "s|.*\"url\":\"\([^\"]*/releases/assets/[0-9]*\)\".*\"name\":\"\([^\"]*\.$pkg_ext\)\".*|\1 \2|p" \
        | while read -r url filename; do
        filepath="$DOWNLOAD_DIR/$filename"

        attempt=0
        while [ $attempt -lt $COUNT ]; do
            msg "Download $filename (count $((attempt+1)))..."
            if wget -q --header="Accept: application/octet-stream" -O "$filepath" "$url"; then
                if [ -s "$filepath" ]; then
                    msg "$filename successfully downloaded"
                    break
                fi
            fi
            msg "Download error for $filename. Retrying..."
            rm -f "$filepath"
            attempt=$((attempt+1))
        done

        if [ $attempt -eq $COUNT ]; then
            msg "Failed to download $filename after $COUNT attempts"
        fi
    done

    # Check if any files were downloaded
    if ! ls "$DOWNLOAD_DIR"/*podkop* >/dev/null 2>&1; then
        msg "No packages were downloaded successfully"
        exit 1
    fi

    # Before podkop: its dependency on sing-box is then met by podkop-engine, not by the sing-box of OpenWrt
    engine_install

    for pkg in podkop luci-app-podkop; do
        file=""
        for f in "$DOWNLOAD_DIR"/"$pkg"*; do
            if [ -f "$f" ]; then
                file=$(basename "$f")
                break
            fi
        done
        if [ -n "$file" ]; then
            msg "Installing $file..."
            pkg_install "$DOWNLOAD_DIR/$file"
            sleep 3
        fi
    done

    ru=""
    for f in "$DOWNLOAD_DIR"/luci-i18n-podkop-ru*; do
        if [ -f "$f" ]; then
            ru=$(basename "$f")
            break
        fi
    done
    if [ -n "$ru" ]; then
        if pkg_is_installed luci-i18n-podkop-ru; then
                msg "Upgrading Russian translation..."
                pkg_remove luci-i18n-podkop*
                pkg_install "$DOWNLOAD_DIR/$ru"
        else
            msg "Русский язык интерфейса ставим? y/n (Install the Russian interface language?)"
            while true; do
                read -r -p '' RUS
                case $RUS in
                y)
                    pkg_remove luci-i18n-podkop*
                    pkg_install "$DOWNLOAD_DIR/$ru"
                    break
                    ;;
                n)
                    break
                    ;;
                *)
                    echo "Введите y или n"
                    ;;
                esac
            done
        fi
    fi

    find "$DOWNLOAD_DIR" -type f -name '*podkop*' -exec rm {} \;
    rm -rf "$ENGINE_DIR"

    if [ "$ENGINE_STOPPED_PODKOP" -eq 1 ]; then
        msg "Starting podkop..."
        service podkop start
    fi
}

check_system() {
    # Get router model
    MODEL=$(cat /tmp/sysinfo/model)
    msg "Router model: $MODEL"

    # Check OpenWrt version
    openwrt_version=$(cat /etc/openwrt_release | grep DISTRIB_RELEASE | cut -d"'" -f2 | cut -d'.' -f1)
    if [ "$openwrt_version" = "23" ]; then
        msg "OpenWrt 23.05 не поддерживается начиная с podkop 0.5.0"
        msg "Для OpenWrt 23.05 используйте podkop версии 0.4.11 или устанавливайте зависимости и podkop вручную"
        msg "Подробности: https://podkop.net/docs/install/#%d1%83%d1%81%d1%82%d0%b0%d0%bd%d0%be%d0%b2%d0%ba%d0%b0-%d0%bd%d0%b0-2305"
        exit 1
    fi

    # Check available space
    AVAILABLE_SPACE=$(df /overlay | awk 'NR==2 {print $4}')
    REQUIRED_SPACE=15360 # 15MB in KB

    if [ "$AVAILABLE_SPACE" -lt "$REQUIRED_SPACE" ]; then
        msg "Error: Insufficient space in flash"
        msg "Available: $((AVAILABLE_SPACE/1024))MB"
        msg "Required: $((REQUIRED_SPACE/1024))MB"
        exit 1
    fi

    if ! nslookup google.com >/dev/null 2>&1; then
        msg "DNS is not working."
        exit 1
    fi

    # Check version
    if command -v podkop > /dev/null 2>&1; then
        local version
        version=$(/usr/bin/podkop show_version 2> /dev/null)
        if [ -n "$version" ]; then
            version=$(echo "$version" | sed 's/^v//')
            local major
            local minor
            local patch
            major=$(echo "$version" | cut -d. -f1)
            minor=$(echo "$version" | cut -d. -f2)
            patch=$(echo "$version" | cut -d. -f3)

            # Compare version: must be >= 0.7.0
            if [ "$major" -gt 0 ] ||
                [ "$major" -eq 0 ] && [ "$minor" -gt 7 ] ||
                [ "$major" -eq 0 ] && [ "$minor" -eq 7 ] && [ "$patch" -ge 0 ]; then
                msg "Podkop version >= 0.7.0"
                break
            else
                msg "Podkop version < 0.7.0"
                update_config
            fi
        else
            msg "Unknown podkop version"
            update_config
        fi
    fi

    if pkg_is_installed https-dns-proxy; then
        msg "Conflicting package detected: https-dns-proxy. Remove?"

        while true; do
                read -r -p '' DNSPROXY
                case $DNSPROXY in

                yes|y|Y)
                    pkg_remove luci-app-https-dns-proxy
                    pkg_remove https-dns-proxy
                    pkg_remove luci-i18n-https-dns-proxy*
                    break
                    ;;
                *)
                    msg "Exit"
                    exit 1
                    ;;
        esac
    done
    fi
}

sing_box() {
    if ! pkg_is_installed "^sing-box"; then
        return
    fi

    sing_box_version=$(sing-box version | head -n 1 | awk '{print $3}')
    required_version="1.12.4"

    if [ "$(printf '%s\n%s\n' "$sing_box_version" "$required_version" | sort -V | head -n 1)" != "$required_version" ]; then
        msg "sing-box version $sing_box_version is older than the required version $required_version."
        msg "Removing old version..."
        service podkop stop
        pkg_remove sing-box
    fi
}

main