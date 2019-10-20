#!/bin/bash

# currently only supports Google Compute Engine

function generate_port
{
  while :; do
    local port=$(shuf -i 30000-60000 -n 1)
    ss -lau | grep $port > /dev/null
    if [[ $? == 1 ]] ; then
        echo "$port"
        break 2;
    fi
  done
}

if [ "$EUID" -ne 0 ]; then
    echo "you must run this as root"
    exit 1
fi

if [[ -e /etc/debian_version ]]; then
    source /etc/os-release
    OS=$ID # debian-based
else
    echo "currently only debian-based system is supported, sorry"
    exit 1
fi

WG_INTERFACE="$(ip -4 route ls | grep default | grep -Po '(?<=dev )(\S+)' | head -1)"

WG_CONFIG_NAME="wg0"

WG_IPV4_ADDR="192.71.0.1/16"

WG_LOCAL_PORT=$(generate_port)

CLIENT_IPV4_ADDR="192.71.0.0/24"
CLIENT_WG_IPV4="192.71.0.2"

DNS="1.1.1.1, 1.0.0.1"

# currently only support Google Compute Engine because we rely on this secure way to fetch machine's public IP
PUBLIC_IP=$(curl -H "Metadata-Flavor: Google" http://metadata/computeMetadata/v1/instance/network-interfaces/0/access-configs/0/external-ip)

ENDPOINT="$PUBLIC_IP:$WG_LOCAL_PORT"

DEBIAN_FRONTEND=noninteractive add-apt-repository ppa:wireguard/wireguard -y
apt-get update
apt-get install -y "linux-headers-$(uname -r)" wireguard iptables qrencode

# Make sure the directory exists (this does not seem the be the case on fedora)
mkdir /etc/wireguard > /dev/null 2>&1

# Generate key pair for the server
PRIVATE_KEY=$(wg genkey)
PUBLIC_KEY=$(echo "$PRIVATE_KEY" | wg pubkey)

# Generate key pair for the client
CLIENT_PRIVATE_KEY=$(wg genkey)
CLIENT_PUBLIC_KEY=$(echo "$CLIENT_PRIVATE_KEY" | wg pubkey)

# Add server interface
echo "[Interface]
Address = $WG_IPV4_ADDR
ListenPort = $WG_LOCAL_PORT
PrivateKey = $PRIVATE_KEY
SaveConfig = true
MTU = 1360
PostUp = iptables -A FORWARD -i %i -j ACCEPT; iptables -A FORWARD -o %i -j ACCEPT; iptables -t nat -A POSTROUTING -o $WG_INTERFACE -j MASQUERADE
PostDown = iptables -D FORWARD -i %i -j ACCEPT; iptables -D FORWARD -o %i -j ACCEPT; iptables -t nat -D POSTROUTING -o $WG_INTERFACE -j MASQUERADE" > "/etc/wireguard/$WG_CONFIG_NAME.conf"

# Add the client as a peer to the server
echo "[Peer]
PublicKey = $CLIENT_PUBLIC_KEY
AllowedIPs = $CLIENT_IPV4_ADDR" >> "/etc/wireguard/$WG_CONFIG_NAME.conf"

# Create client file with interface
echo "[Interface]
PrivateKey = $CLIENT_PRIVATE_KEY
Address = $CLIENT_IPV4_ADDR
DNS = $DNS" > "$HOME/$WG_CONFIG_NAME-client.conf"

# Add the server as a peer to the client
echo "[Peer]
PublicKey = $PUBLIC_KEY
Endpoint = $ENDPOINT
AllowedIPs = 0.0.0.0/0
PersistentKeepalive = 16" >> "$HOME/$WG_CONFIG_NAME-client.conf"

chmod 600 -R /etc/wireguard/

# Enable routing on the server
echo "net.ipv4.ip_forward = 1
net.ipv6.conf.all.forwarding = 1" > /etc/sysctl.d/wg.conf

sysctl --system

systemctl start "wg-quick@$WG_CONFIG_NAME"
systemctl enable "wg-quick@$WG_CONFIG_NAME"

echo "here is the QR-code for you client (e.g. iPhone)"
qrencode -t ansiutf8 < "$HOME/$WG_CONFIG_NAME-client.conf"
