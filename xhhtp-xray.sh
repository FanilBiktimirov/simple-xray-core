#!/bin/bash
echo "Будет установлен VLESS с транспортом XHTTP"
sleep 3
apt update
apt install qrencode curl jq -y

# Включаем bbr
bbr=$(sysctl -a | grep net.ipv4.tcp_congestion_control)
if [ "$bbr" = "net.ipv4.tcp_congestion_control = bbr" ]; then
echo "bbr уже включен"
else
echo "net.core.default_qdisc=fq" >> /etc/sysctl.conf
echo "net.ipv4.tcp_congestion_control=bbr" >> /etc/sysctl.conf
sysctl -p
echo "bbr включен"
fi

# Устанавливаем ядро Xray
bash -c "$(curl -4 -L https://github.com/XTLS/Xray-install/raw/main/install-release.sh)" @ install
[ -f /usr/local/etc/xray/.keys ] && rm /usr/local/etc/xray/.keys
touch /usr/local/etc/xray/.keys
echo "shortsid: $(openssl rand -hex 8)" >> /usr/local/etc/xray/.keys
echo "uuid: $(xray uuid)" >> /usr/local/etc/xray/.keys
xray x25519 >> /usr/local/etc/xray/.keys

export uuid=$(awk -F': ' '/uuid/ {print $2}' /usr/local/etc/xray/.keys)
export privatkey=$(awk -F': ' '/PrivateKey/ {print $2}' /usr/local/etc/xray/.keys)
export shortsid=$(awk -F': ' '/shortsid/ {print $2}' /usr/local/etc/xray/.keys)
export api_listen="127.0.0.1"
export api_port="10085"

# Создаем файл конфигурации Xray
touch /usr/local/etc/xray/config.json
cat << EOF > /usr/local/etc/xray/config.json
{
    "log": {
        "loglevel": "warning"
    },
    "api": {
        "tag": "api",
        "services": [
            "HandlerService",
            "LoggerService",
            "StatsService",
            "RoutingService"
        ]
    },
    "routing": {
        "domainStrategy": "IPIfNonMatch",
        "rules": [
            {
                "type": "field",
                "inboundTag": [
                    "api"
                ],
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
            "listen": "$api_listen",
            "port": $api_port,
            "protocol": "dokodemo-door",
            "settings": {
                "address": "$api_listen"
            },
            "tag": "api"
        },
        {
            "listen": "0.0.0.0",
            "port": 443,
            "protocol": "vless",
            "settings": {
                "clients": [
                    {
                        "email": "main",
                        "id": "$uuid",
                        "flow": ""
                    }
                ],
                "decryption": "none"
            },
            "streamSettings": {
                "network": "xhttp",
                "xhttpSettings": {
                    "path": "/"
                },
                "security": "reality",
                "realitySettings": {
                    "show": false,
                    "target": "github.com:443",
                    "serverNames": [
                        "github.com",
                        "www.github.com"
                    ],
                    "privateKey": "$privatkey",
                    "minClientVer": "",
                    "maxClientVer": "",
                    "maxTimeDiff": 0,
                    "shortIds": [
                        "$shortsid"
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
            "tag": "api"
        },
        {
            "protocol": "freedom",
            "tag": "direct"
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
        },
        "system": {
            "statsInboundUplink": true,
            "statsInboundDownlink": true,
            "statsOutboundUplink": true,
            "statsOutboundDownlink": true
        }
    }
}
EOF

# Исполняемый файл для списка клиентов
touch /usr/local/bin/userlist
cat << 'EOF' > /usr/local/bin/userlist
#!/bin/bash
emails=($(jq -r '.inbounds[1].settings.clients[].email' "/usr/local/etc/xray/config.json"))

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

# Исполняемый файл для ссылки основного пользователя
touch /usr/local/bin/mainuser
cat << 'EOF' > /usr/local/bin/mainuser
#!/bin/bash
protocol=$(jq -r '.inbounds[1].protocol' /usr/local/etc/xray/config.json)
port=$(jq -r '.inbounds[1].port' /usr/local/etc/xray/config.json)
uuid=$(awk -F': ' '/uuid/ {print $2}' /usr/local/etc/xray/.keys)
pbk=$(awk -F': ' '/Password/ {print $2}' /usr/local/etc/xray/.keys)
sid=$(awk -F': ' '/shortsid/ {print $2}' /usr/local/etc/xray/.keys)
sni=$(jq -r '.inbounds[1].streamSettings.realitySettings.serverNames[0]' /usr/local/etc/xray/config.json)
ip=$(timeout 3 curl -4 -s icanhazip.com)
link="$protocol://$uuid@$ip:$port?security=reality&path=%2F&host=&mode=auto&sni=$sni&fp=firefox&pbk=$pbk&sid=$sid&spx=%2F&type=xhttp&encryption=none#vless-$ip"
echo ""
echo "Ссылка для подключения:"
echo "$link"
echo ""
echo "QR-код:"
echo ${link} | qrencode -t ansiutf8
EOF
chmod +x /usr/local/bin/mainuser

# Исполняемый файл для создания новых клиентов
touch /usr/local/bin/newuser
cat << 'EOF' > /usr/local/bin/newuser
#!/bin/bash
read -p "Введите имя пользователя (email): " email

if [[ -z "$email" || "$email" == *" "* ]]; then
    echo "Имя пользователя не может быть пустым или содержать пробелы. Попробуйте снова."
    exit 1
fi

user_json=$(jq --arg email "$email" '.inbounds[1].settings.clients[] | select(.email == $email)' /usr/local/etc/xray/config.json)

if [[ -z "$user_json" ]]; then
uuid=$(xray uuid)
jq --arg email "$email" --arg uuid "$uuid" '.inbounds[1].settings.clients += [{"email": $email, "id": $uuid, "flow": ""}]' /usr/local/etc/xray/config.json > tmp.json && mv tmp.json /usr/local/etc/xray/config.json
systemctl restart xray
index=$(jq --arg email "$email" '.inbounds[1].settings.clients | to_entries[] | select(.value.email == $email) | .key' /usr/local/etc/xray/config.json)
protocol=$(jq -r '.inbounds[1].protocol' /usr/local/etc/xray/config.json)
port=$(jq -r '.inbounds[1].port' /usr/local/etc/xray/config.json)
uuid=$(jq --argjson index "$index" -r '.inbounds[1].settings.clients[$index].id' /usr/local/etc/xray/config.json)
pbk=$(awk -F': ' '/Password/ {print $2}' /usr/local/etc/xray/.keys)
sid=$(awk -F': ' '/shortsid/ {print $2}' /usr/local/etc/xray/.keys)
username=$(jq --argjson index "$index" -r '.inbounds[1].settings.clients[$index].email' /usr/local/etc/xray/config.json)
sni=$(jq -r '.inbounds[1].streamSettings.realitySettings.serverNames[0]' /usr/local/etc/xray/config.json)
ip=$(curl -4 -s icanhazip.com)
link="$protocol://$uuid@$ip:$port?security=reality&path=%2F&host=&mode=auto&sni=$sni&fp=firefox&pbk=$pbk&sid=$sid&spx=%2F&type=xhttp&encryption=none#$username"
echo ""
echo "Ссылка для подключения:"
echo "$link"
echo ""
echo "QR-код:"
echo ${link} | qrencode -t ansiutf8
else
echo "Пользователь с таким именем уже существует. Попробуйте снова."
fi
EOF
chmod +x /usr/local/bin/newuser

# Исполняемый файл для удаления клиентов
touch /usr/local/bin/rmuser
cat << 'EOF' > /usr/local/bin/rmuser
#!/bin/bash
emails=($(jq -r '.inbounds[1].settings.clients[].email' "/usr/local/etc/xray/config.json"))

if [[ ${#emails[@]} -eq 0 ]]; then
    echo "Нет клиентов для удаления."
    exit 1
fi

echo "Список клиентов:"
for i in "${!emails[@]}"; do
    echo "$((i+1)). ${emails[$i]}"
done

read -p "Введите номер клиента для удаления: " choice

if ! [[ "$choice" =~ ^[0-9]+$ ]] || (( choice < 1 || choice > ${#emails[@]} )); then
    echo "Ошибка: номер должен быть от 1 до ${#emails[@]}"
    exit 1
fi

selected_email="${emails[$((choice - 1))]}"

jq --arg email "$selected_email" \
   '(.inbounds[1].settings.clients) |= map(select(.email != $email))' \
   "/usr/local/etc/xray/config.json" > tmp && mv tmp "/usr/local/etc/xray/config.json"

systemctl restart xray

echo "Клиент $selected_email удален."
EOF
chmod +x /usr/local/bin/rmuser

# Исполняемый файл для вывода списка пользователей и создания ссылок
touch /usr/local/bin/sharelink
cat << 'EOF' > /usr/local/bin/sharelink
#!/bin/bash
emails=($(jq -r '.inbounds[1].settings.clients[].email' /usr/local/etc/xray/config.json))

for i in "${!emails[@]}"; do
   echo "$((i + 1)). ${emails[$i]}"
done

read -p "Выберите клиента: " client

if ! [[ "$client" =~ ^[0-9]+$ ]] || (( client < 1 || client > ${#emails[@]} )); then
    echo "Ошибка: номер должен быть от 1 до ${#emails[@]}"
    exit 1
fi

selected_email="${emails[$((client - 1))]}"

index=$(jq --arg email "$selected_email" '.inbounds[1].settings.clients | to_entries[] | select(.value.email == $email) | .key' /usr/local/etc/xray/config.json)
protocol=$(jq -r '.inbounds[1].protocol' /usr/local/etc/xray/config.json)
port=$(jq -r '.inbounds[1].port' /usr/local/etc/xray/config.json)
uuid=$(jq --argjson index "$index" -r '.inbounds[1].settings.clients[$index].id' /usr/local/etc/xray/config.json)
pbk=$(awk -F': ' '/Password/ {print $2}' /usr/local/etc/xray/.keys)
sid=$(awk -F': ' '/shortsid/ {print $2}' /usr/local/etc/xray/.keys)
username=$(jq --argjson index "$index" -r '.inbounds[1].settings.clients[$index].email' /usr/local/etc/xray/config.json)
sni=$(jq -r '.inbounds[1].streamSettings.realitySettings.serverNames[0]' /usr/local/etc/xray/config.json)
ip=$(curl -4 -s icanhazip.com)
link="$protocol://$uuid@$ip:$port?security=reality&path=%2F&host=&mode=auto&sni=$sni&fp=firefox&pbk=$pbk&sid=$sid&spx=%2F&type=xhttp&encryption=none#$username"
echo ""
echo "Ссылка для подключения:"
echo "$link"
echo ""
echo "QR-код:"
echo ${link} | qrencode -t ansiutf8
EOF
chmod +x /usr/local/bin/sharelink

systemctl restart xray

echo "Xray-core успешно установлен"
mainuser

# Создаем файл с подсказками
touch $HOME/help
cat << EOF > $HOME/help

Команды для управления пользователями Xray:

    mainuser - выводит ссылку для подключения основного пользователя
    newuser - создает нового пользователя
    rmuser - удаление пользователей
    sharelink - выводит список пользователей и позволяет создать для них ссылки для подключения
    userlist - выводит список клиентов


Файл конфигурации находится по адресу:

    /usr/local/etc/xray/config.json

Команда для перезагрузки ядра Xray:

    systemctl restart xray

Xray API слушает только локально:

    $api_listen:$api_port

В конфигурации включены сервисы:

    HandlerService
    LoggerService
    StatsService
    RoutingService

EOF
