# Turns the Xray JSON that a panel returns for Xray clients into proxy links, one per line, with the name of the
# server as the fragment. The links are then handled like the links of any other subscription.
#
# The input is a configuration or an array of configurations. A configuration has one proxy outbound (named by
# "remarks") or several of them (named by their tags). The same server can be in several configurations: only the
# first one is kept, and configurations with a single server go first because they have the readable names.
#
# Only functions without regular expressions are used: jq of OpenWrt is built without them.

def param($key; $value):
  if $value == null or $value == "" then empty
  else [$key, ($value | tostring)]
  end;

def network:
  ((.streamSettings.network // "tcp") | ascii_downcase) as $n
  | if $n == "raw" then "tcp" elif $n == "splithttp" then "xhttp" else $n end;

# The settings of the TLS or REALITY layer
def tls_settings:
  .streamSettings.realitySettings // .streamSettings.tlsSettings // {};

def alpn_list:
  if type == "array" then join(",") else (. // "") end;

# The XHTTP options of Xray are in "extra", but some panels write them next to the path
def xhttp_settings:
  .streamSettings.xhttpSettings // .streamSettings.splithttpSettings // {};

def xhttp_extra:
  xhttp_settings
  | (del(.path, .host, .mode, .extra) + (.extra // {}))
  | with_entries(select(.value != null));

# The parameters of the link that depend on the transport
def transport_params:
  network as $net
  | if $net == "ws" then
      (.streamSettings.wsSettings // {}) as $w
      | [param("path"; $w.path), param("host"; ($w.host // $w.headers.Host // $w.headers.host))]
    elif $net == "grpc" then
      [param("serviceName"; .streamSettings.grpcSettings.serviceName)]
    elif $net == "xhttp" then
      xhttp_settings as $x
      | xhttp_extra as $extra
      | [
          param("path"; $x.path),
          param("host"; $x.host),
          param("mode"; $x.mode),
          param("extra"; (if ($extra | length) > 0 then ($extra | tojson) else null end))
        ]
    elif $net == "tcp" then
      ((.streamSettings.tcpSettings // .streamSettings.rawSettings // {}).header.type // "none") as $h
      | [param("headerType"; (if $h == "none" then null else $h end))]
    else
      []
    end;

def query($pairs):
  $pairs | map(select(. != null) | (.[0] + "=" + (.[1] | @uri))) | join("&");

# The link without the fragment, null if the outbound has no address, port or credentials
def link:
  . as $o
  | (if $o.protocol == "shadowsocks" or $o.protocol == "trojan"
     then ($o.settings.servers[0] // $o.settings)
     else ($o.settings.vnext[0] // $o.settings)
     end) as $s
  | ($s.users[0] // $s) as $u
  | tls_settings as $t
  | ($o.streamSettings.security // "none") as $security
  | ($s.address) as $address
  | ($s.port) as $port
  | (if $o.protocol == "vless" then $u.id
     elif $o.protocol == "trojan" then ($u.password // $s.password)
     else null
     end) as $secret
  | if $address == null or $port == null then null
    elif $o.protocol == "shadowsocks" then
      if ($s.method == null or $s.password == null) then null
      else "ss://" + (($s.method + ":" + $s.password) | @uri) + "@" + $address + ":" + ($port | tostring)
      end
    elif $secret == null then null
    else
      ($o.protocol + "://" + ($secret | @uri) + "@" + $address + ":" + ($port | tostring) + "?"
       + query([
           (if $o.protocol == "vless" then param("encryption"; ($u.encryption // "none")) else empty end),
           (if $o.protocol == "vless" then param("flow"; $u.flow) else empty end),
           param("type"; ($o | network)),
           param("security"; $security),
           param("sni"; $t.serverName),
           param("fp"; $t.fingerprint),
           param("alpn"; ($t.alpn | alpn_list)),
           param("pbk"; $t.publicKey),
           param("sid"; $t.shortId),
           param("spx"; $t.spiderX),
           param("allowInsecure"; (if $t.allowInsecure == true then 1 else null end)),
           ($o | transport_params[])
         ]))
    end;

[
  (if type == "array" then .[] else . end)
  | objects
  | . as $cfg
  | [.outbounds[]? | select(.protocol | IN("vless", "trojan", "shadowsocks"))] as $proxies
  | $proxies[]
  | {
      multi: (($proxies | length) > 1),
      name: (if ($proxies | length) == 1 and ($cfg.remarks // "") != "" then $cfg.remarks else (.tag // $cfg.remarks // "") end),
      link: link
    }
  | select(.link != null)
]
| (map(select(.multi | not)) + map(select(.multi)))
| reduce .[] as $e ({seen: {}, out: []};
    if .seen[$e.link] then .
    else .seen[$e.link] = true | .out += [$e.link + (if $e.name != "" then "#" + ($e.name | @uri) else "" end)]
    end)
| .out[]
