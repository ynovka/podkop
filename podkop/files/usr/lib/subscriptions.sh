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

#######################################
# Download a subscription URL. The host is resolved via the bootstrap DNS server, because the router's own DNS
# points to sing-box, which is not running yet while podkop starts.
# Arguments:
#   url: subscription URL
#   outfile: path to save the response body to
#   bootstrap_dns_server: IPv4 address of the DNS server used to resolve the host
#   attempts: number of download attempts (default: 1)
# Returns:
#   0 on success, 1 otherwise
#######################################
subscription_fetch() {
    local url="$1"
    local outfile="$2"
    local bootstrap_dns_server="$3"
    local attempts="${4:-1}"

    local host port ip attempt rc
    host="$(subscription_url_get_host "$url")"
    port="$(subscription_url_get_port "$url")"
    url="${url%%#*}"

    attempt=1
    while [ "$attempt" -le "$attempts" ]; do
        ip=""
        if ! is_ipv4 "$host" && [ -n "$bootstrap_dns_server" ]; then
            ip="$(dig +short +time=2 +tries=1 @"$bootstrap_dns_server" A "$host" 2> /dev/null |
                grep -E '^[0-9]+(\.[0-9]+){3}$' | head -n1)"
        fi

        if [ -n "$ip" ]; then
            curl -fsL --proto =https --proto-redir =https --max-filesize 5M --connect-timeout 5 -m 15 \
                -A "$SUBSCRIPTION_USER_AGENT" --resolve "$host:$port:$ip" -o "$outfile" "$url" 2> /dev/null
        else
            curl -fsL --proto =https --proto-redir =https --max-filesize 5M --connect-timeout 5 -m 15 \
                -A "$SUBSCRIPTION_USER_AGENT" -o "$outfile" "$url" 2> /dev/null
        fi
        rc=$?
        [ "$rc" -eq 0 ] && return 0

        log "Attempt $attempt/$attempts to download subscription from $host failed (curl exit code $rc)" "warn"
        attempt=$((attempt + 1))
        [ "$attempt" -le "$attempts" ] && sleep 5
    done

    return 1
}

# Removes CR characters, surrounding whitespace and empty lines
_subscription_normalize() {
    tr -d '\r' | sed 's/^[[:space:]]*//; s/[[:space:]]*$//' | grep -v '^$'
}

#######################################
# Parse a subscription response body (plain or base64-encoded list of links) and keep only the links that podkop
# can turn into sing-box outbounds.
# Arguments:
#   infile: path to the response body
#   outfile: path to save the supported links to, one per line
# Returns:
#   0 if at least one supported link was found, 1 otherwise
#######################################
subscription_parse() {
    local infile="$1"
    local outfile="$2"

    local body_file decoded_file encoded total kept
    body_file="$(mktemp)"
    _subscription_normalize < "$infile" > "$body_file"

    if ! grep -qE '^[a-z0-9]+://' "$body_file"; then
        encoded="$(tr -d ' \t\r\n' < "$infile" | tr '_-' '/+')"
        case $((${#encoded} % 4)) in
        2) encoded="$encoded==" ;;
        3) encoded="$encoded=" ;;
        esac

        decoded_file="$(mktemp)"
        if ! printf '%s' "$encoded" | base64 -d > "$decoded_file" 2> /dev/null; then
            rm -f "$body_file" "$decoded_file"
            return 1
        fi
        _subscription_normalize < "$decoded_file" > "$body_file"
        rm -f "$decoded_file"
    fi

    local decode_link=0
    sing_box_has_feature "tools.decode-link" && decode_link=1

    awk -v decode_link="$decode_link" '
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
            # sing-box decodes xhttp links itself, with all their parameters
            if (decode_link && link ~ "^(vless|trojan)://" && type ~ "^(xhttp|splithttp)$") { print; next }
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
    ' "$body_file" > "$outfile"

    total="$(grep -c . "$body_file")"
    kept="$(grep -c . "$outfile")"
    rm -f "$body_file"

    if [ "$kept" -lt "$total" ]; then
        log "Subscription: skipped $((total - kept)) of $total links (unsupported scheme, transport or format)" "warn"
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
