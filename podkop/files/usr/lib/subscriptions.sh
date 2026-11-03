# Checks if the given link is an HTTPS subscription URL
is_subscription_url() {
    local link="$1"

    case "$link" in
    https://*) return 0 ;;
    esac

    return 1
}

# Returns the host[:port] part of a URL without userinfo
_subscription_url_get_authority() {
    local url="$1"

    url="${url#*://}"
    url="${url%%[/?#]*}"

    echo "${url##*@}"
}

# Extracts the host part from a subscription URL
subscription_url_get_host() {
    local authority
    authority="$(_subscription_url_get_authority "$1")"

    echo "${authority%%:*}"
}

# Extracts the port from a subscription URL (443 if not specified)
subscription_url_get_port() {
    local authority port
    authority="$(_subscription_url_get_authority "$1")"
    port="${authority#*:}"

    if [ "$port" = "$authority" ]; then
        port=443
    fi

    echo "$port"
}

# Returns the path of the cache file for a subscription URL (the fragment is ignored)
subscription_cache_path() {
    local url="$1"

    local hash
    hash="$(printf '%s' "${url%%#*}" | md5sum | cut -c1-32)"

    echo "$SUBSCRIPTION_CACHE_FOLDER/$hash.txt"
}

# Returns the path of the file with the checksum of the proxies downloaded for the cache file. The cache holds only
# the proxies sing-box accepts, so it differs from the download when the subscription has others. The checksum lets
# the next update skip checking the same download again. It is kept in RAM: after a reboot the check runs once.
subscription_source_sum_path() {
    local cache_file="$1"

    echo "$TMP_SING_BOX_FOLDER/subscription_$(basename "$cache_file" .txt).sum"
}

# Prints the checksum of the lines of a file regardless of their order
subscription_lines_sum() {
    sort "$1" | md5sum | cut -c1-32
}

#######################################
# Print the cron schedule for updating subscriptions.
# Arguments:
#   interval: "<N>m" (1-59), "<N>h" (1-23) or "<N>d" (1-28); the default one if empty
# Returns:
#   0 and the five cron fields, 1 if the interval is invalid
#######################################
subscription_cron_schedule() {
    local interval="${1:-$SUBSCRIPTION_DEFAULT_UPDATE_INTERVAL}"
    local number="${interval%[mhd]}"

    case "$number" in
    "" | *[!0-9]*) return 1 ;;
    esac
    [ "$number" -ge 1 ] || return 1

    case "$interval" in
    *m)
        [ "$number" -le 59 ] || return 1
        echo "*/$number * * * *"
        ;;
    *h)
        [ "$number" -le 23 ] || return 1
        echo "43 */$number * * *"
        ;;
    *d)
        [ "$number" -le 28 ] || return 1
        echo "43 9 */$number * *"
        ;;
    *) return 1 ;;
    esac
}

#######################################
# Get the hardware ID (HWID) that is sent to subscription servers. Some panels limit the number of devices of a
# subscription and require it. The default one is derived from the MAC address of the router, so it stays the same
# across restarts and updates and does not reveal the address.
# Arguments:
#   setting: the subscription_hwid option: empty or "auto" for the default HWID, "off" to send nothing,
#            anything else is sent as is
# Outputs:
#   The HWID, nothing if it is disabled
#######################################
subscription_get_hwid() {
    local setting="$1"

    case "$setting" in
    off | 0 | false | no | disabled) return 0 ;;
    "" | auto | 1 | on | true | yes) ;;
    *)
        echo "$setting"
        return 0
        ;;
    esac

    local interface address=""
    for interface in br-lan eth0 lan wan; do
        [ -r "/sys/class/net/$interface/address" ] && address="$(cat "/sys/class/net/$interface/address")"
        [ -n "$address" ] && break
    done
    if [ -z "$address" ]; then
        address="$(cat /sys/class/net/*/address 2> /dev/null | grep -v '^00:00:00:00:00:00$' | head -n1)"
    fi
    [ -n "$address" ] || return 0

    printf 'podkop:%s' "$address" | md5sum | cut -c1-32
}

# Prints a value that is safe to send in an HTTP header
_subscription_header_value() {
    tr -cd 'A-Za-z0-9 ._()/+-' | cut -c1-64
}

#######################################
# Download a subscription URL. The host is resolved via the bootstrap DNS server, because the router's own DNS
# points to sing-box, which is not running yet while podkop starts.
# Arguments:
#   url: subscription URL
#   outfile: path to save the response body to
#   bootstrap_dns_server: IPv4 address of the DNS server used to resolve the host
#   attempts: number of download attempts (default: 1)
#   user_agent: User-Agent header (default: SUBSCRIPTION_USER_AGENT)
#   hwid: HWID to send in the x-hwid header together with the OS and model of the device (optional)
# Returns:
#   0 on success, the exit code of the last curl attempt otherwise
#######################################
subscription_fetch() {
    local url="$1"
    local outfile="$2"
    local bootstrap_dns_server="$3"
    local attempts="${4:-1}"
    local user_agent="${5:-$SUBSCRIPTION_USER_AGENT}"
    local hwid="$6"

    local host port ip attempt rc os_version device_model
    host="$(subscription_url_get_host "$url")"
    port="$(subscription_url_get_port "$url")"
    url="${url%%#*}"

    set -- -fsL --proto =https --proto-redir =https --max-filesize 5M --connect-timeout 5 -m 15 -A "$user_agent"
    if [ -n "$hwid" ]; then
        os_version="$(grep DISTRIB_RELEASE /etc/openwrt_release 2> /dev/null | cut -d"'" -f2 | _subscription_header_value)"
        device_model="$(cat /tmp/sysinfo/model 2> /dev/null | _subscription_header_value)"
        set -- "$@" -H "x-hwid: $(echo "$hwid" | _subscription_header_value)" -H "x-device-os: OpenWrt" \
            -H "x-ver-os: $os_version" -H "x-device-model: $device_model"
    fi

    attempt=1
    while [ "$attempt" -le "$attempts" ]; do
        ip=""
        if ! is_ipv4 "$host" && [ -n "$bootstrap_dns_server" ]; then
            ip="$(dig +short +time=2 +tries=1 @"$bootstrap_dns_server" A "$host" 2> /dev/null |
                grep -E '^[0-9]+(\.[0-9]+){3}$' | head -n1)"
        fi

        if [ -n "$ip" ]; then
            curl "$@" --resolve "$host:$port:$ip" -o "$outfile" "$url" 2> /dev/null
        else
            curl "$@" -o "$outfile" "$url" 2> /dev/null
        fi
        rc=$?
        [ "$rc" -eq 0 ] && return 0

        log "Attempt $attempt/$attempts to download subscription from $host failed (curl exit code $rc)" "warn"
        attempt=$((attempt + 1))
        [ "$attempt" -le "$attempts" ] && sleep 5
    done

    return "$rc"
}

# Removes CR characters, surrounding whitespace and empty lines
_subscription_normalize() {
    tr -d '\r' | sed 's/^[[:space:]]*//; s/[[:space:]]*$//' | grep -v '^$'
}

#######################################
# Take the proxy outbounds of a sing-box configuration returned by a subscription. Panels return it to sing-box
# clients instead of a list of links. Every outbound is saved as a one-line JSON object. Groups (selector, urltest),
# direct, block and the like are skipped, and so are the options that refer to other parts of the original
# configuration.
# Arguments:
#   infile: path to the response body
#   outfile: path to save the outbounds to, one per line
# Returns:
#   0 if at least one outbound was found, 1 otherwise
#######################################
_subscription_parse_singbox() {
    local infile="$1"
    local outfile="$2"

    jq -c '
        (if type == "array" then .[] else . end)
        | objects
        | .outbounds[]?
        | select(
            type == "object"
            and (.type | IN("vless", "vmess", "trojan", "shadowsocks", "hysteria2", "hysteria", "tuic", "anytls"))
            and (.server | type == "string")
        )
        | del(.detour, .domain_resolver, .domain_strategy, .bind_interface, .inet4_bind_address,
              .inet6_bind_address, .routing_mark, .netns)
    ' "$infile" 2> /dev/null | awk '!seen[$0]++' > "$outfile"

    [ -s "$outfile" ]
}

#######################################
# Turn the Xray JSON that a panel returns for Xray clients into links, see subscription_xray.jq.
# Arguments:
#   infile: path to the response body
#   outfile: path to save the links to, one per line
# Returns:
#   0 if at least one link was made, 1 otherwise
#######################################
_subscription_parse_xray() {
    local infile="$1"
    local outfile="$2"

    jq -r -f "$PODKOP_LIB/subscription_xray.jq" "$infile" 2> /dev/null > "$outfile"

    [ -s "$outfile" ]
}

#######################################
# Parse a subscription response body and keep only the proxies that podkop can turn into sing-box outbounds.
# The body is a plain or base64-encoded list of links, a sing-box configuration or Xray JSON.
# Globals:
#   SUBSCRIPTION_PARSED_KIND: "links", "singbox" or "xray", the format of the response
#   SUBSCRIPTION_XHTTP_SKIPPED: the number of servers skipped because sing-box has no xhttp transport
# Arguments:
#   infile: path to the response body
#   outfile: path to save the supported proxies to, one per line: a link or a one-line JSON object of an outbound
# Returns:
#   0 if at least one supported proxy was found, 1 otherwise
#######################################
subscription_parse() {
    local infile="$1"
    local outfile="$2"

    local body_file decoded_file encoded total kept count_file
    SUBSCRIPTION_PARSED_KIND=""
    SUBSCRIPTION_XHTTP_SKIPPED=0
    body_file="$(mktemp)"

    case "$(tr -d ' \t\r\n' < "$infile" | head -c 1)" in
    "{" | "[")
        if _subscription_parse_singbox "$infile" "$outfile"; then
            SUBSCRIPTION_PARSED_KIND="singbox"
            rm -f "$body_file"
            return 0
        fi
        if ! _subscription_parse_xray "$infile" "$body_file"; then
            log "Subscription: the response is JSON without proxies of a sing-box or Xray configuration" "warn"
            rm -f "$body_file"
            return 1
        fi
        SUBSCRIPTION_PARSED_KIND="xray"
        ;;
    *)
        _subscription_normalize < "$infile" > "$body_file"

        if ! grep -qE '^[a-z0-9]+://' "$body_file"; then
            encoded="$(tr -d ' \t\r\n' < "$infile" | tr '_-' '/+')"
            case $((${#encoded} % 4)) in
            2) encoded="$encoded==" ;;
            3) encoded="$encoded=" ;;
            esac

            decoded_file="$(mktemp)"
            if ! printf '%s' "$encoded" | base64 -d > "$decoded_file" 2> /dev/null; then
                log "Subscription: the response is neither a list of links nor a sing-box configuration" "warn"
                rm -f "$body_file" "$decoded_file"
                return 1
            fi
            _subscription_normalize < "$decoded_file" > "$body_file"
            rm -f "$decoded_file"
        fi
        SUBSCRIPTION_PARSED_KIND="links"
        ;;
    esac

    local decode_link=0 xhttp_ok=0
    sing_box_has_feature "tools.decode-link" && decode_link=1
    sing_box_supports_xhttp && xhttp_ok=1
    count_file="$(mktemp)"

    awk -v decode_link="$decode_link" -v xhttp_ok="$xhttp_ok" -v count_file="$count_file" '
        # The last occurrence of a repeated parameter wins, as in url_get_query_param
        function param(link, name,    value) {
            value = ""
            while (match(link, "[?&]" name "=[^&?#]*")) {
                value = substr(link, RSTART + length(name) + 2, RLENGTH - length(name) - 2)
                link = substr(link, RSTART + RLENGTH)
            }
            return value
        }
        {
            link = $0
            sub(/#.*/, "", link)
            # Userinfo is everything before the first "@", as in url_get_userinfo: a shadowsocks password
            # or its base64 may contain "/"
            if (link !~ "^(vless|ss|trojan|socks4|socks4a|socks5|hysteria2|hy2)://([^@]+@)?[^:/?#[]+:[0-9]+") next
            type = param(link, "type")
            # xhttp is decoded by sing-box itself (podkop-engine) or built by podkop (sing-box-extended)
            if (link ~ "^(vless|trojan)://" && type ~ "^(xhttp|splithttp)$") {
                if (xhttp_ok) { print } else { xhttp_skipped++ }
                next
            }
            if (type != "" && type !~ "^(tcp|raw|ws|grpc)$") next
            security = param(link, "security")
            if (security != "" && security !~ "^(none|tls|reality)$") next
            # Parameters that podkop does not pass to sing-box or sing-box does not support
            flow = param(link, "flow")
            if (flow != "" && flow != "xtls-rprx-vision") next
            encryption = param(link, "encryption")
            if (encryption != "" && encryption != "none") next
            header_type = param(link, "headerType")
            if (header_type != "" && header_type != "none") next
            if (param(link, "plugin") != "") next
            print
        }
        END { print xhttp_skipped + 0 > count_file }
    ' "$body_file" > "$outfile"

    SUBSCRIPTION_XHTTP_SKIPPED="$(cat "$count_file")"
    total="$(grep -c . "$body_file")"
    kept="$(grep -c . "$outfile")"
    rm -f "$body_file" "$count_file"

    if [ "$kept" -lt "$total" ]; then
        log "Subscription: skipped $((total - kept)) of $total links (unsupported scheme, transport or format)" "debug"
    fi

    [ "$kept" -gt 0 ]
}

#######################################
# Atomically save parsed subscription links to the cache file. The file is rewritten only when its content changes,
# to avoid needless flash writes.
# Arguments:
#   parsed_file: path to the parsed links
#   cache_file: path to the cache file
# Returns:
#   0 on success, 1 otherwise
#######################################
subscription_store_cache() {
    local parsed_file="$1"
    local cache_file="$2"

    if [ -f "$cache_file" ] &&
        [ "$(md5sum < "$parsed_file" | cut -c1-32)" = "$(md5sum < "$cache_file" | cut -c1-32)" ]; then
        return 0
    fi

    local cache_folder tmp_file
    cache_folder="$(dirname "$cache_file")"
    tmp_file="$cache_folder/.tmp.$$"

    mkdir -p "$cache_folder" || return 1
    if cp "$parsed_file" "$tmp_file" && chmod 600 "$tmp_file" && mv "$tmp_file" "$cache_file"; then
        return 0
    fi

    rm -f "$tmp_file"
    return 1
}


# Downloads a subscription as the given client and parses it. Returns 0 on success, 2 if the response has no
# supported proxies, the exit code of curl if the download failed.
_subscription_download_as() {
    local url="$1"
    local parsed_file="$2"
    local bootstrap_dns_server="$3"
    local attempts="$4"
    local user_agent="$5"
    local hwid="$6"

    local body_file rc
    body_file="$(mktemp)"

    subscription_fetch "$url" "$body_file" "$bootstrap_dns_server" "$attempts" "$user_agent" "$hwid"
    rc=$?
    if [ "$rc" -eq 0 ]; then
        subscription_parse "$body_file" "$parsed_file" || rc=2
    fi

    rm -f "$body_file"
    return $rc
}

# Prints the identity of every one-line JSON outbound: type, server, port, credentials and transport
_subscription_json_keys() {
    jq -r '[.type, .server, (.server_port | tostring), (.uuid // .password // ""), (.transport.type // "tcp")]
        | join("|")' "$1" 2> /dev/null
}

# Prints the identity of every link in the same form as _subscription_json_keys, a tab and the link
_subscription_link_keys() {
    awk '
        function param(link, name,    value) {
            value = ""
            while (match(link, "[?&]" name "=[^&?#]*")) {
                value = substr(link, RSTART + length(name) + 2, RLENGTH - length(name) - 2)
                link = substr(link, RSTART + RLENGTH)
            }
            return value
        }
        {
            link = $0
            sub(/#.*/, "", link)
            scheme = link
            sub(/:.*/, "", scheme)
            rest = link
            sub(/^[^:]*:[/][/]/, "", rest)
            secret = ""
            if (index(rest, "@")) {
                secret = rest
                sub(/@.*/, "", secret)
                sub(/^[^@]*@/, "", rest)
            }
            gsub(/%3A/, ":", secret)
            sub(/[/?].*/, "", rest)
            port = rest
            sub(/^.*:/, "", port)
            host = rest
            sub(/:[0-9]+$/, "", host)
            type = param(link, "type")
            if (type == "" || type == "raw") type = "tcp"
            if (type == "splithttp") type = "xhttp"
            if (scheme == "ss") { scheme = "shadowsocks"; sub(/^[^:]*:/, "", secret) }
            if (scheme == "hy2") scheme = "hysteria2"
            printf "%s|%s|%s|%s|%s\t%s\n", scheme, host, port, secret, type, $0
        }
    ' "$1"
}

#######################################
# Add the links that are not in the sing-box configuration of the same subscription to it. Panels give Xray clients
# the servers that need Xray (xhttp) and sing-box clients the other ones, so each format has servers the other lacks.
# Arguments:
#   singbox_file: path to the one-line JSON outbounds
#   links_file: path to the links
#   outfile: path to save the result to
#######################################
_subscription_merge() {
    local singbox_file="$1"
    local links_file="$2"
    local outfile="$3"

    local keys_file
    keys_file="$(mktemp)"
    _subscription_json_keys "$singbox_file" > "$keys_file"

    if [ ! -s "$keys_file" ]; then
        cp "$links_file" "$outfile"
        rm -f "$keys_file"
        return 0
    fi

    cp "$singbox_file" "$outfile"
    _subscription_link_keys "$links_file" |
        awk -F '\t' 'NR == FNR { seen[$0] = 1; next } !($1 in seen) { sub(/^[^\t]*\t/, ""); print }' \
            "$keys_file" - >> "$outfile"

    rm -f "$keys_file"
}

# The panel returned Xray JSON: ask for the sing-box format as well and merge the two
_subscription_download_merged() {
    local url="$1"
    local parsed_file="$2"
    local bootstrap_dns_server="$3"
    local hwid="$4"

    local singbox_file xhttp_skipped agent
    xhttp_skipped="$SUBSCRIPTION_XHTTP_SKIPPED"
    singbox_file="$(mktemp)"

    for agent in "$SUBSCRIPTION_USER_AGENT_SINGBOX" "$SUBSCRIPTION_USER_AGENT_HIDDIFY"; do
        if _subscription_download_as "$url" "$singbox_file" "$bootstrap_dns_server" 1 "$agent" "$hwid" &&
            [ "$SUBSCRIPTION_PARSED_KIND" = "singbox" ]; then
            local merged_file
            merged_file="$(mktemp)"
            _subscription_merge "$singbox_file" "$parsed_file" "$merged_file"
            cp "$merged_file" "$parsed_file"
            rm -f "$merged_file"
            break
        fi
    done

    SUBSCRIPTION_PARSED_KIND="xray"
    SUBSCRIPTION_XHTTP_SKIPPED="$xhttp_skipped"
    rm -f "$singbox_file"
}

#######################################
# Download a subscription and parse it. Panels choose the format of the response by the User-Agent and give an
# unknown client something podkop cannot read (a JSON for Xray, a web page) or reject it. Then the subscription is
# requested again as clients that get a sing-box configuration.
# Arguments:
#   url: subscription URL
#   parsed_file: path to save the supported proxies to (see subscription_parse)
#   bootstrap_dns_server: IPv4 address of the DNS server used to resolve the host
#   attempts: number of download attempts
#   user_agent: User-Agent to use instead of the built-in ones (optional)
#   hwid: HWID to send to the server (optional, see subscription_get_hwid)
# Returns:
#   0 if at least one supported proxy was found, 1 otherwise
#######################################
subscription_download() {
    local url="$1"
    local parsed_file="$2"
    local bootstrap_dns_server="$3"
    local attempts="$4"
    local user_agent="$5"
    local hwid="$6"

    local rc
    if [ -n "$user_agent" ]; then
        _subscription_download_as "$url" "$parsed_file" "$bootstrap_dns_server" "$attempts" "$user_agent" "$hwid"
        return $?
    fi

    _subscription_download_as "$url" "$parsed_file" "$bootstrap_dns_server" "$attempts" "$SUBSCRIPTION_USER_AGENT" \
        "$hwid"
    rc=$?
    if [ "$rc" -eq 0 ] && [ "$SUBSCRIPTION_PARSED_KIND" = "xray" ]; then
        _subscription_download_merged "$url" "$parsed_file" "$bootstrap_dns_server" "$hwid"
        return 0
    fi
    # 22: the server answered with an HTTP error, e.g. it rejects unknown clients
    if [ "$rc" -ne 2 ] && [ "$rc" -ne 22 ]; then
        [ "$rc" -eq 0 ]
        return
    fi

    log "Subscription: requesting it again as a sing-box client" "debug"
    _subscription_download_as "$url" "$parsed_file" "$bootstrap_dns_server" 1 "$SUBSCRIPTION_USER_AGENT_SINGBOX" \
        "$hwid" && return 0
    _subscription_download_as "$url" "$parsed_file" "$bootstrap_dns_server" 1 "$SUBSCRIPTION_USER_AGENT_HIDDIFY" \
        "$hwid"
}
