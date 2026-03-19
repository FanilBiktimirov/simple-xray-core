#!/usr/bin/env bash
set -euo pipefail

echo "Будет установлен VLESS + REALITY + XHTTP + Xray API"
sleep 3

XRAY_DIR="/usr/local/etc/xray"
XRAY_CONFIG="$XRAY_DIR/config.json"
XRAY_KEYS="$XRAY_DIR/.keys"

XRAY_PORT="${XRAY_PORT:-443}"
API_PORT="${API_PORT:-10085}"
API_LISTEN="${API_LISTEN:-127.0.0.1}"
REALITY_TARGET="${REALITY_TARGET:-github.com:443}"
REALITY_SERVER_NAME_1="${REALITY_SERVER_NAME_1:-github.com}"
REALITY_SERVER_NAME_2="${REALITY_SERVER_NAME_2:-www.github.com}"
XHTTP_PATH="${XHTTP_PATH:-/}"

install_packages() {
  apt update
  apt install -y curl jq qrencode openssl ca-certificates
}

enable_bbr() {
  if sysctl net.ipv4.tcp_congestion_control 2>/dev/null | grep -q "bbr"; then
    echo "bbr уже включен"
    return
  fi

  grep -q "^net.core.default_qdisc=fq$" /etc/sysctl.conf || echo "net.core.default_qdisc=fq" >> /etc/sysctl.conf
  grep -q "^net.ipv4.tcp_congestion_control=bbr$" /etc/sysctl.conf || echo "net.ipv4.tcp_congestion_control=bbr" >> /etc/sysctl.conf
  sysctl -p
  echo "bbr включен"
}

install_xray() {
  bash -c "$(curl -4 -L https://github.com/XTLS/Xray-install/raw/main/install-release.sh)" @ install
}

generate_keys() {
  mkdir -p "$XRAY_DIR"
  rm -f "$XRAY_KEYS"
  touch "$XRAY_KEYS"

  local shortsid uuid
  shortsid="$(openssl rand -hex 8)"
  uuid="$(xray uuid)"

  {
    echo "shortsid: $shortsid"
    echo "uuid: $uuid"
    xray x25519
  } >> "$XRAY_KEYS"
}

load_keys() {
  UUID_VALUE="$(awk -F': ' '/^uuid:/ {print $2}' "$XRAY_KEYS")"
  PRIVATE_KEY="$(awk -F': ' '/^PrivateKey:/ {print $2}' "$XRAY_KEYS")"
  PUBLIC_KEY="$(awk -F': ' '/^PublicKey:/ {print $2}' "$XRAY_KEYS")"
  SHORT_ID="$(awk -F': ' '/^shortsid:/ {print $2}' "$XRAY_KEYS")"

  if [[ -z "${UUID_VALUE:-}" || -z "${PRIVATE_KEY:-}" || -z "${PUBLIC_KEY:-}" || -z "${SHORT_ID:-}" ]]; then
    echo "Не удалось получить ключи Xray"
    exit 1
  fi
}

write_config() {
  cat > "$XRAY_CONFIG" <<EOF
{
  "log": {
    "loglevel": "warning"
  },
  "api": {
    "tag": "api",
    "services": [
      "HandlerService",
      "StatsService",
      "LoggerService"
    ]
  },
  "routing": {
    "domainStrategy": "IPIfNonMatch",
    "rules": [
      {
        "type": "field",
        "inboundTag": ["api"],
        "outboundTag": "api"
      },
      {
        "type": "field",
        "domain": [
          "geosite:category-ads-all"
        ],
        "outboundTag": "block"
      },
      {
        "type": "field",
        "ip": [
          "geoip:cn"
        ],
        "outboundTag": "block"
      }
    ]
  },
  "inbounds": [
    {
      "listen": "$API_LISTEN",
      "port": $API_PORT,
      "protocol": "dokodemo-door",
      "settings": {
        "address": "127.0.0.1"
      },
      "tag": "api"
    },
    {
      "listen": "0.0.0.0",
      "port": $XRAY_PORT,
      "protocol": "vless",
      "settings": {
        "clients": [
          {
            "email": "main",
            "id": "$UUID_VALUE",
            "flow": ""
          }
        ],
        "decryption": "none"
      },
      "streamSettings": {
        "network": "xhttp",
        "xhttpSettings": {
          "path": "$XHTTP_PATH"
        },
        "security": "reality",
        "realitySettings": {
          "show": false,
          "target": "$REALITY_TARGET",
          "serverNames": [
            "$REALITY_SERVER_NAME_1",
            "$REALITY_SERVER_NAME_2"
          ],
          "privateKey": "$PRIVATE_KEY",
          "minClientVer": "",
          "maxClientVer": "",
          "maxTimeDiff": 0,
          "shortIds": [
            "$SHORT_ID"
          ]
        }
      },
      "sniffing": {
        "enabled": true,
        "destOverride": [
          "http",
          "tls",
          "quic"
        ]
      }
    }
  ],
  "outbounds": [
    {
      "protocol": "freedom",
      "tag": "direct"
    },
    {
      "protocol": "freedom",
      "tag": "api"
    },
    {
      "protocol": "blackhole",
      "tag": "block"
    }
  ],
  "policy": {
    "levels": {
      "0": {
        "handshake": 3,
        "connIdle": 180
      }
    }
  }
}
EOF
}

validate_and_restart() {
  xray -test -config "$XRAY_CONFIG"
  systemctl enable xray
  systemctl restart xray
  systemctl --no-pager --full status xray | sed -n '1,20p'
}

install_userlist() {
  cat > /usr/local/bin/userlist <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

CONFIG="/usr/local/etc/xray/config.json"
emails=($(jq -r '.inbounds[] | select(.protocol=="vless") | .settings.clients[].email' "$CONFIG"))

if [[ ${#emails[@]} -eq 0 ]]; then
  echo "Список клиентов пуст"
  exit 1
fi

echo "Список клиентов:"
for i in "${!emails[@]}"; do
  echo "$((i+1)). ${emails[$i]}"
done
EOF
  chmod +x /usr/local/bin/userlist
}

install_mainuser() {
  cat > /usr/local/bin/mainuser <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

CONFIG="/usr/local/etc/xray/config.json"
KEYS="/usr/local/etc/xray/.keys"

protocol="$(jq -r '.inbounds[] | select(.protocol=="vless") | .protocol' "$CONFIG" | head -n1)"
port="$(jq -r '.inbounds[] | select(.protocol=="vless") | .port' "$CONFIG" | head -n1)"
uuid="$(awk -F': ' '/^uuid:/ {print $2}' "$KEYS")"
pbk="$(awk -F': ' '/^PublicKey:/ {print $2}' "$KEYS")"
sid="$(awk -F': ' '/^shortsid:/ {print $2}' "$KEYS")"
sni="$(jq -r '.inbounds[] | select(.protocol=="vless") | .streamSettings.realitySettings.serverNames[0]' "$CONFIG" | head -n1)"
path="$(jq -r '.inbounds[] | select(.protocol=="vless") | .streamSettings.xhttpSettings.path' "$CONFIG" | head -n1)"
ip="$(timeout 5 curl -4 -s icanhazip.com || true)"

if [[ -z "$ip" ]]; then
  echo "Не удалось определить публичный IP"
  exit 1
fi

encoded_path="%2F"
link="$protocol://$uuid@$ip:$port?security=reality&path=$encoded_path&host=&mode=auto&sni=$sni&fp=firefox&pbk=$pbk&sid=$sid&spx=$encoded_path&type=xhttp&encryption=none#vless-main"

echo
echo "Ссылка для подключения:"
echo "$link"
echo
echo "QR-код:"
printf '%s' "$link" | qrencode -t ansiutf8
EOF
  chmod +x /usr/local/bin/mainuser
}

install_newuser() {
  cat > /usr/local/bin/newuser <<'EOF'
#!/usr/bin/env bash


›



if [[ -z "$email" || "$email" == *" "* ]]; then
  echo "Имя пользователя не может быть пустым или содержать пробелы"
  exit 1
fi

exists="$(jq --arg email "$email" -r '.inbounds[] | select(.protocol=="vless") | .settings.clients[] | select(.email == $email) | .email' "$CONFIG" || true)"
if [[ -n "$exists" ]]; then
  echo "Пользователь с таким именем уже существует"
  exit 1
fi

uuid="$(xray uuid)"
tmp="$(mktemp)"

jq --arg email "$email" --arg uuid "$uuid" '
  (.inbounds[] | select(.protocol=="vless") | .settings.clients) += [{"email": $email, "id": $uuid, "flow": ""}]
' "$CONFIG" > "$tmp"

mv "$tmp" "$CONFIG"
xray -test -config "$CONFIG"
systemctl restart xray

port="$(jq -r '.inbounds[] | select(.protocol=="vless") | .port' "$CONFIG" | head -n1)"
protocol="$(jq -r '.inbounds[] | select(.protocol=="vless") | .protocol' "$CONFIG" | head -n1)"
pbk="$(awk -F': ' '/^PublicKey:/ {print $2}' "$KEYS")"
sid="$(awk -F': ' '/^shortsid:/ {print $2}' "$KEYS")"
sni="$(jq -r '.inbounds[] | select(.protocol=="vless") | .streamSettings.realitySettings.serverNames[0]' "$CONFIG" | head -n1)"
ip="$(timeout 5 curl -4 -s icanhazip.com || true)"

if [[ -z "$ip" ]]; then
  echo "Пользователь создан, но не удалось определить публичный IP"
  exit 0
fi

encoded_path="%2F"
link="$protocol://$uuid@$ip:$port?security=reality&path=$encoded_path&host=&mode=auto&sni=$sni&fp=firefox&pbk=$pbk&sid=$sid&spx=$encoded_path&type=xhttp&encryption=none#$email"

echo
echo "Ссылка для подключения:"
echo "$link"
echo
echo "QR-код:"
printf '%s' "$link" | qrencode -t ansiutf8
EOF
  chmod +x /usr/local/bin/newuser
}

install_rmuser() {
  cat > /usr/local/bin/rmuser <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

CONFIG="/usr/local/etc/xray/config.json"
emails=($(jq -r '.inbounds[] | select(.protocol=="vless") | .settings.clients[].email' "$CONFIG"))

if [[ ${#emails[@]} -eq 0 ]]; then
  echo "Нет клиентов для удаления"
  exit 1
fi

echo "Список клиентов:"
for i in "${!emails[@]}"; do
  echo "$((i+1)). ${emails[$i]}"
done

read -r -p "Введите номер клиента для удаления: " choice

if ! [[ "$choice" =~ ^[0-9]+$ ]] || (( choice < 1 || choice > ${#emails[@]} )); then
  echo "Ошибка: номер должен быть от 1 до ${#emails[@]}"
  exit 1
fi

selected_email="${emails[$((choice - 1))]}"
tmp="$(mktemp)"

jq --arg email "$selected_email" '
  (.inbounds[] | select(.protocol=="vless") | .settings.clients) |= map(select(.email != $email))
' "$CONFIG" > "$tmp"

mv "$tmp" "$CONFIG"
xray -test -config "$CONFIG"
systemctl restart xray

echo "Клиент $selected_email удалён"
EOF
  chmod +x /usr/local/bin/rmuser
}

install_sharelink() {
  cat > /usr/local/bin/sharelink <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

CONFIG="/usr/local/etc/xray/config.json"
KEYS="/usr/local/etc/xray/.keys"

emails=($(jq -r '.inbounds[] | select(.protocol=="vless") | .settings.clients[].email' "$CONFIG"))

if [[ ${#emails[@]} -eq 0 ]]; then
  echo "Список клиентов пуст"
  exit 1
fi

for i in "${!emails[@]}"; do
  echo "$((i + 1)). ${emails[$i]}"
done

read -r -p "Выберите клиента: " client

if ! [[ "$client" =~ ^[0-9]+$ ]] || (( client < 1 || client > ${#emails[@]} )); then
  echo "Ошибка: номер должен быть от 1 до ${#emails[@]}"
  exit 1
fi

selected_email="${emails[$((client - 1))]}"
uuid="$(jq --arg email "$selected_email" -r '.inbounds[] | select(.protocol=="vless") | .settings.clients[] | select(.email == $email) | .id' "$CONFIG")"
protocol="$(jq -r '.inbounds[] | select(.protocol=="vless") | .protocol' "$CONFIG" | head -n1)"
port="$(jq -r '.inbounds[] | select(.protocol=="vless") | .port' "$CONFIG" | head -n1)"
pbk="$(awk -F': ' '/^PublicKey:/ {print $2}' "$KEYS")"
sid="$(awk -F': ' '/^shortsid:/ {print $2}' "$KEYS")"
sni="$(jq -r '.inbounds[] | select(.protocol=="vless") | .streamSettings.realitySettings.serverNames[0]' "$CONFIG" | head -n1)"
ip="$(timeout 5 curl -4 -s icanhazip.com || true)"

if [[ -z "$ip" ]]; then
  echo "Не удалось определить публичный IP"
  exit 1
fi

encoded_path="%2F"
link="$protocol://$uuid@$ip:$port?security=reality&path=$encoded_path&host=&mode=auto&sni=$sni&fp=firefox&pbk=$pbk&sid=$sid&spx=$encoded_path&type=xhttp&encryption=none#$selected_email"

echo
echo "Ссылка для подключения:"
echo "$link"
echo
echo "QR-код:"
printf '%s' "$link" | qrencode -t ansiutf8
EOF
  chmod +x /usr/local/bin/sharelink
}

install_help() {
  cat > "$HOME/help" <<EOF

Команды для управления пользователями Xray:

    mainuser   - ссылка основного пользователя
    newuser    - создать нового пользователя
    rmuser     - удалить пользователя
    sharelink  - показать ссылку пользователя
    userlist   - список клиентов

Файл конфигурации:

    $XRAY_CONFIG

Файл с ключами:

    $XRAY_KEYS

Перезапуск Xray:

    systemctl restart xray

Проверка Xray:

    xray -test -config $XRAY_CONFIG

Параметры API:

    listen: $API_LISTEN
    port:   $API_PORT

EOF
}

print_api_notes() {
  echo
  echo "Xray-core успешно установлен"
  echo
  echo "Xray API:"
  echo "  listen: $API_LISTEN"
  echo "  port:   $API_PORT"
  echo
  echo "Проверка прослушивания API:"
  echo "  ss -ltnp | grep $API_PORT"
  echo

  if [[ "$API_LISTEN" == "127.0.0.1" ]]; then
    echo "API доступен только локально."
    echo "Если бот находится на другом сервере, запускай так:"
    echo "  API_LISTEN=0.0.0.0 bash install-xray.sh"
    echo "И открой firewall только для IP бота."
  else
    echo "API слушает внешний интерфейс."
    echo "Открой порт $API_PORT только для IP машины с ботом."
  fi
}

main() {
  install_packages
  enable_bbr
  install_xray
  generate_keys
  load_keys
  write_config
  validate_and_restart
  install_userlist
  install_mainuser
  install_newuser
  install_rmuser
  install_sharelink
  install_help
  print_api_notes
  mainuser
}

main "$@"
