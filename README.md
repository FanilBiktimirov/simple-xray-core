# simple-xray-core

Скрипт для быстрой установки `Xray-core` с `VLESS + REALITY + XHTTP` на Ubuntu/Debian сервер.

## Установка на сервер

Запустите от `root`:

```bash
wget -qO- https://raw.githubusercontent.com/FanilBiktimirov/simple-xray-core/master/install-xray.sh | bash
```

Если `wget` не установлен:

```bash
curl -fsSL https://raw.githubusercontent.com/FanilBiktimirov/simple-xray-core/master/install-xray.sh | bash
```

## Что делает скрипт

- устанавливает зависимости `qrencode`, `curl`, `jq`, `openssl`
- включает `bbr`
- устанавливает `Xray-core`
- создает конфиг `/usr/local/etc/xray/config.json`
- генерирует ключи и основную ссылку подключения
- добавляет служебные команды для управления пользователями

## Команды после установки

- `mainuser` - показать ссылку и QR-код основного пользователя
- `newuser` - добавить нового пользователя
- `rmuser` - удалить пользователя
- `sharelink` - получить ссылку для выбранного пользователя
- `userlist` - показать список пользователей

Подсказки после установки также сохраняются в файл `~/help`.

## Полное удаление

Для удаления `Xray-core` и файлов, созданных этим скриптом, выполните:

```bash
rm -f /usr/local/etc/xray/config.json
rm -f /usr/local/etc/xray/.keys
rm -f /usr/local/bin/userlist
rm -f /usr/local/bin/mainuser
rm -f /usr/local/bin/newuser
rm -f /usr/local/bin/rmuser
rm -f /usr/local/bin/sharelink
```
