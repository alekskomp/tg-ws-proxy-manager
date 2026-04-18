#!/bin/sh
set -euo pipefail

GREEN="\033[1;32m"
YELLOW="\033[1;33m"
MAGENTA="\033[1;35m"
CYAN="\033[1;36m"
RED="\033[1;31m"
BLUE="\033[0;34m"
BOLD="\033[1m"
DIM="\033[38;5;244m"
NC="\033[0m"

CURL_OPTS="-fsSL --connect-timeout 10"

# Определяем LAN ip
LAN_IP=$(uci get network.lan.ipaddr 2> /dev/null | cut -d/ -f1)

# Указываем ip для DC telegram
DC_IP_2="149.154.167.220"
DC_IP_4="149.154.167.220"

# Домены Cloudflare proxy
CF_DOMAINS_URL="https://raw.githubusercontent.com/Flowseal/tg-ws-proxy/main/.github/cfproxy-domains.txt"

# Параметры TG WS Proxy [Rust]
REPO_RS="valnesfjord/tg-ws-proxy-rs"
BIN_NAME_RS="tg-ws-proxy-rs"
BIN_PATH_RS="/usr/bin/${BIN_NAME_RS}"
INIT_PATH_RS="/etc/init.d/${BIN_NAME_RS}"
TMP_ARCHIVE_RS="/tmp/${BIN_NAME_RS}.tar.gz"
TMP_DIR_RS="/tmp/${BIN_NAME_RS}"
PROXY_PORT_RS="2443"
LISTEN_IP_RS="0.0.0.0"
BASE_CMD_RS="${BIN_PATH_RS} -q --host ${LISTEN_IP_RS} --port ${PROXY_PORT_RS} --dc-ip 2:${DC_IP_2} --dc-ip 4:${DC_IP_4} --secret"

# Параметры TG WS Proxy [Go]
REPO_GO="d0mhate/-tg-ws-proxy-Manager-go"
BIN_NAME_GO="tg-ws-proxy-go"
BIN_PATH_GO="/usr/bin/${BIN_NAME_GO}"
INIT_PATH_GO="/etc/init.d/${BIN_NAME_GO}"
TMP_BIN_GO="/tmp/${BIN_NAME_GO}"
PROXY_PORT_GO="1080"
LISTEN_IP_GO="0.0.0.0"
BASE_CMD_GO="${BIN_PATH_GO} --host ${LISTEN_IP_GO} --port ${PROXY_PORT_GO}"

# Создаем команду tpm
if [ ! -x "/usr/bin/tpm" ] || ! grep -q "tg-ws-proxy-manager" /usr/bin/tpm 2> /dev/null; then
    echo "sh <(wget --timeout= 10 -q -O - https://raw.githubusercontent.com/alekskomp/tg-ws-proxy-manager/refs/heads/main/tg-ws-proxy-manager.sh)" > /usr/bin/tpm || true
    chmod +x /usr/bin/tpm || true
fi

# Пауза
PAUSE() {
    echo
    read -r -p "Нажми Enter..." dummy
}

# Определяем пакетный менеджер
if command -v opkg > /dev/null 2>&1; then
    PKG="opkg"
    UPDATE="opkg update"
    INSTALL="opkg install"
    ARCH="$(opkg print-architecture | awk '{print $2}' | tail -n1)"
    #ARCH="$(uname -m)"
else
    PKG="apk"
    UPDATE="apk update"
    INSTALL="apk add"
    ARCH="$(apk --print-arch 2> /dev/null)"
    #ARCH="$(uname -m)"
fi

gen_secret() {
    head -c16 /dev/urandom | hexdump -e '16/1 "%02x"'
}

# Скачиваем Cloudflare домены Flowseal
cf_decode_domains() {
    local content decoded_list domain decoded

    content=$(curl ${CURL_OPTS} "${CF_DOMAINS_URL}" 2> /dev/null)

    if [ -z "${content}" ]; then
        echo -e "Ошибка: не удалось скачать список доменов\n" >&2
        PAUSE
        return
    fi

    # Декодируем в обратном порядке
    decoded_list=$(printf '%s\n' "${content}" | sed '1!G;h;$!d' | while IFS= read -r line; do
    #decoded_list=$(printf '%s\n' "${content}" | while IFS= read -r line; do # Прямой порядок
        domain=$(echo "$line" | tr -d '\r' | xargs)
        [ -z "${domain}" ] && continue
        case "${domain}" in \#*) continue ;; esac

        decoded=$(cf_decode_single_domain "${domain}")
        echo -n "${decoded},"
    done | sed 's/,$//')

    echo "${decoded_list}"
}

cf_decode_single_domain() {
    local encoded="$1"
    local p char ord new len shift_val
    local decoded=""
    local n=0
    local i=1

    case "${encoded}" in
        *.com) ;;
        *) echo "${encoded}"; return ;;
    esac

    p="${encoded%.com}"
    len=${#p}

    while [ $i -le $len ]; do
        char=$(echo "$p" | cut -c "$i")
        case "$char" in
            [a-zA-Z]) n=$((n + 1)) ;;
        esac
        i=$((i + 1))
    done

    i=1
    while [ $i -le $len ]; do
        char=$(echo "$p" | cut -c "$i")
        case "$char" in
            [a-z])
                ord=$(printf '%d' "'$char")
                shift_val=$((ord - 97 - n))
                new=$(( (shift_val % 26 + 26) % 26 + 97 ))
                decoded="${decoded}$(printf "\\$(printf '%03o' "$new")")"
                ;;
            [A-Z])
                ord=$(printf '%d' "'$char")
                shift_val=$((ord - 65 - n))
                new=$(( (shift_val % 26 + 26) % 26 + 65 ))
                decoded="${decoded}$(printf "\\$(printf '%03o' "$new")")"
                ;;
            *)
                decoded="${decoded}${char}"
                ;;
        esac
        i=$((i + 1))
    done

    echo "${decoded}.co.uk"
}

# Получаем secret из init файла
get_current_secret() {
    local version="$1"
    local init_path

    case "${version}" in
        rs)
            init_path="${INIT_PATH_RS}"
            [ -f "${init_path}" ] && sed -n 's/.*--secret[[:space:]]*\([0-9a-fA-F]\{32\}\).*/\1/p' ${init_path} || true
            ;;
        go)
            init_path="${INIT_PATH_GO}"
            [ -f "${init_path}" ] && sed -n 's/.*--secret[[:space:]]*\([0-9a-fA-F]\{34\}\).*/\1/p' ${init_path} || true
            ;;
        *)
            echo -e "${RED}Ошибка: неизвестная версия ${version}${NC}"
            PAUSE
            return 1
            ;;
    esac
}

# Получаем домены Cloudflare из init файла
get_cf_domain() {
    local version="$1"
    local init_path

    case "${version}" in
        rs)
            init_path="${INIT_PATH_RS}"
            ;;
        go)
            init_path="${INIT_PATH_GO}"
            ;;
        *)
            echo -e "${RED}Ошибка: неизвестная версия ${version}${NC}"
            PAUSE
            return 1
            ;;
    esac

    if [ -f "${init_path}" ]; then
        sed -n 's/.*--cf-domain[[:space:]]*\([^ ]*\).*/\1/p' ${init_path} || true
    fi
}

# Получаем приоритет Cloudflare из init файла
get_cf_priority() {
    local version="$1"
    local init_path

    case "${version}" in
        rs)
            init_path="${INIT_PATH_RS}"
            [ -f "${init_path}" ] && grep -q -- "--cf-priority" ${init_path} 2> /dev/null && echo "1" || echo "0"
            ;;
        go)
            init_path="${INIT_PATH_GO}"
            [ -f "${init_path}" ] && grep -q -- "--cf-proxy-first" ${init_path} 2> /dev/null && echo "1" || echo "0"
            ;;
        *)
            echo -e "${RED}Ошибка: неизвестная версия ${version}${NC}"
            PAUSE
            return 1
            ;;
    esac
}

# Определяем архитектуру
get_arch() {
    local version="$1"

    if [ "${version}" = "rs" ]; then
        case "${ARCH}" in
            aarch64*)
                echo "tg-ws-proxy-aarch64-unknown-linux-musl.tar.gz"
            ;;
            x86_64)
                echo "tg-ws-proxy-x86_64-unknown-linux-musl.tar.gz"
            ;;
            arm*)
                echo "tg-ws-proxy-armv7-unknown-linux-musleabihf.tar.gz"
            ;;
            mipsel*)
                echo "tg-ws-proxy-mipsel-unknown-linux-musl.tar.gz"
            ;;
            mips*)
                echo "tg-ws-proxy-mips-unknown-linux-musl.tar.gz"
            ;;
            *)
                echo -e "\n${RED}Архитектура не поддерживается: ${NC}${ARCH}"
                PAUSE
                return 1
            ;;
        esac
    elif [ "${version}" = "go" ]; then
        case ${ARCH} in
            aarch64*)
                echo "tg-ws-proxy-openwrt-aarch64"
            ;;
            arm*)
                echo "tg-ws-proxy-openwrt-armv7"
            ;;
            mipsel_24kc|mipsel*)
                echo "tg-ws-proxy-openwrt-mipsel_24kc"
            ;;
            mips_24kc|mips*)
                echo "tg-ws-proxy-openwrt-mips_24kc"
            ;;
            x86_64)
                echo "tg-ws-proxy-openwrt-x86_64"
            ;;
            *)
                echo "tg-ws-proxy-openwrt"
            ;;
        esac
    else
        echo -e "${RED}Ошибка: неизвестная версия ${version}${NC}"
        PAUSE
        return 1
    fi
}

# Создаем init скрипт
create_init_script() {
    local init_path="$1"
    local command_line="$2"

    cat << EOF > "${init_path}"
#!/bin/sh /etc/rc.common

START=99
USE_PROCD=1

start_service() {
    procd_open_instance
    procd_set_param command ${command_line}
    procd_set_param respawn
    procd_close_instance
}
EOF

    chmod +x "${init_path}"
}

# Настройка Cloudflare proxy
configure_cloudflare() {
    local version="$1"
    local display_name bin_name init_path base_cmd cf_flag priority_flag cf_domain secret mtproto_mode mtproto_flag
    local cf_priority="0"
    local default_cf_domains="$(cf_decode_domains)"
    local current_cf_domain="$(get_cf_domain "${version}")"
    local current_prority="$(get_cf_priority "${version}")"

    case "${version}" in
        rs)
            display_name="[Rust]"
            bin_name="${BIN_NAME_RS}"
            init_path="${INIT_PATH_RS}"
            base_cmd="${BASE_CMD_RS}"
            cf_flag="--cf-domain"
            priority_flag="--cf-priority"
            mtproto_mode="${MTPROTO_RS}"
            ;;
        go)
            display_name="[Go]"
            bin_name="${BIN_NAME_GO}"
            init_path="${INIT_PATH_GO}"
            base_cmd="${BASE_CMD_GO}"
            cf_flag="--cf-proxy --cf-domain"
            priority_flag="--cf-proxy-first"
            mtproto_mode="${MTPROTO_GO}"
            mtproto_flag="--mode mtproto"
            ;;
        *)
            echo -e "${RED}Ошибка: неизвестная версия ${version}${NC}"
            PAUSE
            return 1
            ;;
    esac

    local full_cmd="${base_cmd}"

    show_header

    echo -e "\n${MAGENTA}Настройка Cloudflare Proxy ${CYAN}${display_name}${NC}\n"

    if [ -n "${current_cf_domain}" ]; then
        echo -e "${YELLOW}Cтатус:${NC} ${GREEN}Включен${NC}"
        echo -e "${YELLOW}Домены:${NC} ${current_cf_domain}"
        echo -e "${YELLOW}Приоритет Cloudflare:${NC} $( [ "${current_prority}" = "1" ] && echo "${GREEN}Включен${NC}" || echo "${RED}Выключен${NC}" )"
    else
        echo -e "${YELLOW}Cтатус:${NC} ${RED}Отключен${NC}"
    fi

    echo -e "\n${CYAN}1)${NC}${BOLD} Включить с доменами по умолчанию${NC}"
    echo -e "${CYAN}2)${NC}${BOLD} Включить со своими доменами${NC}"
    if [ -n "${current_cf_domain}" ]; then
        echo -e "${CYAN}3)${NC}${BOLD} $( [ "${current_prority}" = "1" ] && echo "Выключить" || echo "Включить" ) приоритет Cloudflare${NC}"
        echo -e "${CYAN}4)${YELLOW} Выключить Cloudflare Proxy${NC}"
    fi
    echo -e "\n${CYAN}Enter) Отмена${NC}\n"
    echo -en "${YELLOW}Выбери действие: ${NC}"
    read -r choice

    case ${choice} in
        1)
            if [ -n "${default_cf_domains}" ]; then
                if [ -z "${current_cf_domain}" ] && [ "${current_prority}" = "0" ]; then
                    cf_priority="1"
                else
                    cf_priority="${current_prority}"
                fi
                cf_domain="${default_cf_domains}"
                echo -e "\n${GREEN}Выбраны домены по умолчанию${NC}"
            else
                echo -e "\n${RED}Не удалось скачать домены по умолчанию${NC}"
                PAUSE
                return
            fi
            ;;
        2)
            echo -en "\n${YELLOW}Введи домены через запятую: ${NC}"
            read -r input
            input=$(echo "${input}" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')

            if [ -z "${input}" ]; then
                echo -e "\n${RED}Домен не введен${NC}"
                PAUSE
                return
            fi

            if [ -z "${current_cf_domain}" ] && [ "${current_prority}" = "0" ]; then
                cf_priority="1"
            else
                cf_priority="${current_prority}"
            fi

            cf_domain="${input}"
            echo -e "\n${GREEN}Домены сохранены${NC}"
            ;;
        3)
            if [ -z "${current_cf_domain}" ]; then
                echo -e "\n${RED}Сначала включи Cloudflare Proxy (пункт 1 или 2)${NC}"
                PAUSE
                return
            fi

            if [ "${current_prority}" = "1" ]; then
                cf_priority="0"
            else
                cf_priority="1"
            fi

            cf_domain="${current_cf_domain}"
            echo -e "\n${GREEN}Приоритет Cloudflare $( [ "${cf_priority}" = "1" ] && echo "включен" || echo "выключен" )${NC}"
            ;;
        4)
            cf_domain=""
            cf_priority="0"
            echo -e "\n${GREEN}Cloudflare Proxy отключен${NC}"
            ;;
        *)
            return
            ;;
    esac

    if [ "${mtproto_mode}" = "1" ]; then
        secret="$(get_current_secret "${version}")"

        if [ "${version}" = "go" ]; then
            [ -n "${secret}" ] && full_cmd="${full_cmd} ${mtproto_flag} --secret ${secret}"
        else
            full_cmd="${full_cmd} ${secret}"
        fi
    fi

    if [ -n "${cf_domain}" ]; then
        full_cmd="${full_cmd} ${cf_flag} ${cf_domain}"
        [ "${cf_priority}" = "1" ] && full_cmd="${full_cmd} ${priority_flag}"
    fi

    create_init_script "${init_path}" "${full_cmd}"

    "${init_path}" restart > /dev/null 2>&1
    sleep 1

    if pidof "${bin_name}" > /dev/null 2>&1; then
        echo -e "\n${GREEN}Настройки Cloudflare успешно применены и сервис перезапущен${NC}"
    else
        echo -e "\n${RED}Не удалось запустить сервис после применения настроек${NC}"
    fi

    PAUSE
    return
}

# Установка или обновление TG WS proxy
install_or_update_tgws() {
    local version="$1"
    local is_update="${2:-0}"
    local display_name repo bin_name bin_path init_path base_cmd cf_flag priority_flag mtproto_mode mtproto_flag tmp_archive tmp_dir tmp_bin cf_domain
    local secret=""
    local cf_priority="0"
    local default_cf_domains="$(cf_decode_domains)"
    local arch_file="$(get_arch "${version}")"

    local releases_json
    local release_list
    local latest_stable=""
    local i=1
    local input_release
    local selected_tag

    local tag1 tag2 tag3 tag4 tag5 tag6 tag7 tag8 tag9 tag10

    case "$version" in
        rs)
            display_name="[Rust]"
            repo="${REPO_RS}"
            bin_name="${BIN_NAME_RS}"
            bin_path="${BIN_PATH_RS}"
            init_path="${INIT_PATH_RS}"
            tmp_archive="${TMP_ARCHIVE_RS}"
            tmp_dir="${TMP_DIR_RS}"
            base_cmd="${BASE_CMD_RS}"
            mtproto_mode="${MTPROTO_RS}"
            cf_flag="--cf-domain"
            priority_flag="--cf-priority"
            ;;
        go)
            display_name="[Go]"
            repo="${REPO_GO}"
            bin_name="${BIN_NAME_GO}"
            bin_path="${BIN_PATH_GO}"
            init_path="${INIT_PATH_GO}"
            tmp_bin="${TMP_BIN_GO}"
            base_cmd="${BASE_CMD_GO}"
            mtproto_mode="${MTPROTO_GO}"
            mtproto_flag="--mode mtproto"
            cf_flag="--cf-proxy --cf-domain"
            priority_flag="--cf-proxy-first"
            ;;
        *)
            echo -e "${RED}Ошибка: неизвестная версия '${version}'${NC}"
            PAUSE
            return 1
            ;;
    esac

    #local latest_tag="$(get_latest_tag "${repo}")"
    local full_cmd="${base_cmd}"

    clear
    show_header

    if [ "${is_update}" = "1" ]; then
        echo -e " \n${MAGENTA}Обновление TG WS Proxy ${CYAN}${display_name}${NC}"
    else
        echo -e " \n${MAGENTA}Установка TG WS Proxy ${CYAN}${display_name}${NC}"
    fi

    releases_json=$(curl ${CURL_OPTS} "https://api.github.com/repos/${repo}/releases?per_page=10" 2>/dev/null) || {
        echo -e "${RED}Не удалось получить список релизов с GitHub${NC}"
        PAUSE
        return
    }

    release_list=$(echo "$releases_json" | grep -o '"tag_name": "[^"]*"' | cut -d'"' -f4 | sort -Vr)

    if [ -z "$release_list" ]; then
        echo -e "${RED}Не удалось получить список релизов${NC}"
        PAUSE
        return
    fi

    latest_stable=$(echo "$release_list" | head -n1)

    echo -e " \n${CYAN}Доступные релизы:${NC}\n"

    i=1
    unset tag1 tag2 tag3 tag4 tag5 tag6 tag7 tag8 tag9 tag10 2> /dev/null || true

    #printf " ${DIM}%2s)${NC} ${MAGENTA}%-20s${NC} %s\n" "№" "Тег версии" "Статус"

    for tag in $release_list; do
        [ -z "$tag" ] && continue
        #status="${GREEN}stable${NC}"
        printf " ${CYAN}%2d)${NC} ${BOLD}%-20s${NC} %b\n" "$i" "$tag" #"$status"
        eval "tag${i}=\"${tag}\""
        i=$((i + 1))
        [ $i -gt 10 ] && break
    done

    echo -e " \n${DIM}Введи номер или нажми Enter для последней версии${NC}\n"

    echo -ne "${CYAN}Версия${NC} ${BOLD}[${latest_stable}]${NC}: "
    read -r input_release

    if [ -z "$input_release" ]; then
        selected_tag="$latest_stable"
    elif echo "$input_release" | grep -q '^[0-9]\+$'; then
        eval "selected_tag=\"\${tag${input_release}:-${latest_stable}}\""
    else
        selected_tag="$input_release"
    fi

    if [ -z "${selected_tag}" ]; then
        echo -e "\n${RED}Не удалось получить последнюю версию${NC}"
        PAUSE
        return
    fi

    local download_url="https://github.com/${repo}/releases/download/${selected_tag}/${arch_file}"

    echo -e "\n${CYAN}Скачиваем${NC} ${BOLD}${arch_file} [${selected_tag}]${NC}"

    if [ "${version}" = "rs" ]; then
        curl ${CURL_OPTS} -o "${tmp_archive}" "${download_url}" || {
            echo -e "\n${RED}Ошибка скачивания${NC}"
            PAUSE
            return
        }

        rm -rf "${tmp_dir}"
        mkdir -p "${tmp_dir}"
        tar -xzf "${tmp_archive}" -C "${tmp_dir}" || {
            echo -e "\n${RED}Ошибка распаковки${NC}"
            PAUSE
            return
        }

        mv "${tmp_dir}"/tg-ws-proxy* "${bin_path}" 2> /dev/null || true

        if [ ! -f "${bin_path}" ]; then
            echo "Ошибка установки бинарника"
            PAUSE
            return
        fi

        rm -rf "${tmp_dir}" "${tmp_archive}"
    else
        rm -f "${tmp_bin}"
        curl ${CURL_OPTS} -o "${tmp_bin}" "${download_url}" || {
            echo -e "\n${RED}Ошибка скачивания${NC}"
            PAUSE
            return
        }
        chmod +x "${tmp_bin}"
        mv "${tmp_bin}" "${bin_path}" 2> /dev/null || true
    fi

    chmod +x "${bin_path}" || true

    if [ "${is_update}" = "1" ]; then
        if [ "${mtproto_mode}" = "1" ]; then
            secret="$(get_current_secret "${version}")"
            if [ -z "${secret}" ]; then
                [ "${version}" = "go" ] && secret="dd$(gen_secret)" || secret="$(gen_secret)"
            fi
        fi
        cf_domain="$(get_cf_domain "${version}")"
        cf_priority="$(get_cf_priority "${version}")"
    else
        if [ "${version}" = "go" ]; then
            echo -e "\n${CYAN}1)${NC}${BOLD} Установить в режиме SOCKS5${NC}"
            echo -e "${CYAN}2)${NC}${BOLD} Установить в режиме MTProto${NC}"
            echo -e "\n${CYAN}Enter)${BOLD} Отмена${NC}\n"
            echo -en "${YELLOW}Выбери действие: ${NC}"
            read -r go_mode_select

            case "${go_mode_select}" in
                1)
                    secret=""
                    ;;
                2)
                    secret="dd$(gen_secret)"
                    ;;
                *)
                    PAUSE
                    return
                    ;;
            esac
        else
            secret="$(gen_secret)"
        fi

        # Включаем Cloudflare proxy по умолчанию при установке если домены доступны
        if [ -n "${default_cf_domains}" ]; then
            cf_domain="${default_cf_domains}"
            cf_priority="1"
        else
            cf_domain=""
            cf_priority="0"
        fi
    fi

    if [ "${version}" = "go" ]; then
        [ -n "${secret}" ] && full_cmd="${full_cmd} ${mtproto_flag} --secret ${secret}" || true
    else
        full_cmd="${full_cmd} ${secret}"
    fi

    if [ -n "${cf_domain}" ]; then
        full_cmd="${full_cmd} ${cf_flag} ${cf_domain}"
        [ "${cf_priority}" = "1" ] && full_cmd="${full_cmd} ${priority_flag}"
    fi

    create_init_script "${init_path}" "${full_cmd}"

    "${init_path}" enable > /dev/null 2>&1 || true
    "${init_path}" restart > /dev/null 2>&1 || true
    sleep 1

    if pidof "${bin_name}" > /dev/null 2>&1; then
        local status_msg=$([ "${is_update}" = "1" ] && echo "обновлён" || echo "запущен")
        echo -e "\n${GREEN}Сервис TG WS Proxy ${CYAN}${display_name}${NC} ${GREEN}успешно ${status_msg}${NC}"
    else
        echo -e "\n${RED}Не удалось запустить сервис${NC}"    
    fi

    PAUSE
    return
}

# Удаление TG WS proxy
delete_tg_ws() {
    local version="${1}"
    local bin_name bin_path init_path display_name

    case "${version}" in
        rs)
            bin_name="${BIN_NAME_RS}"
            bin_path="${BIN_PATH_RS}"
            init_path="${INIT_PATH_RS}"
            display_name="[Rust]"
            ;;
        go)
            bin_name="${BIN_NAME_GO}"
            bin_path="${BIN_PATH_GO}"
            init_path="${INIT_PATH_GO}"
            display_name="[Go]"
            ;;
        *)
            echo -e "${RED}Ошибка: неизвестная версия ${version}${NC}"
            PAUSE
            return 1
            ;;
    esac

    echo -e "\n${MAGENTA}Удаляем TG WS Proxy ${CYAN}${display_name}${NC}"

    if [ -x "${init_path}" ]; then
        "${init_path}" stop > /dev/null 2>&1 || true
        "${init_path}" disable > /dev/null 2>&1 || true
    fi

    killall -q "${bin_name}" || true
    rm -f "${bin_path}" "${init_path}" || true

    echo -e "\n${GREEN}TG WS Proxy ${display_name} ${GREEN}успешно удален${NC}"

    PAUSE
    return
}

show_proxy_status() {
    local version="$1"
    local bin_name bin_path init_path proxy_port display_name running cf_domain secret cf_pri

    case "${version}" in
        rs)
            bin_name="${BIN_NAME_RS}"
            bin_path="${BIN_PATH_RS}"
            init_path="${INIT_PATH_RS}"
            proxy_port="${PROXY_PORT_RS}"
            display_name="${CYAN}[Rust]${NC}"
            ;;
        go)
            bin_name="${BIN_NAME_GO}"
            bin_path="${BIN_PATH_GO}"
            init_path="${INIT_PATH_GO}"
            proxy_port="${PROXY_PORT_GO}"
            display_name="${CYAN}[Go]${NC}"
            ;;
        *)
            echo -e "${RED}Ошибка: неизвестная версия ${version}${NC}"
            return 1
            ;;
    esac

    if [ -f "${bin_path}" ] && [ -f "${init_path}" ]; then
        cf_domain="$(get_cf_domain "${version}")"
        cf_pri="$( [ "$(get_cf_priority "${version}")" = "1" ] && echo "${GREEN}Включен${NC}" || echo "${RED}Выключен${NC}" )"
        secret="$(get_current_secret "${version}")"

        if pgrep -f "${bin_name}" > /dev/null 2>&1; then
            running=1
        else
            running=0
        fi

        echo -e "\n${MAGENTA}TG WS Proxy ${display_name}${NC}: $( [ "${running}" = "1" ] && echo "${GREEN}Работает${NC}" || echo "${RED}Остановлен${NC}" )"
        echo -e "  ${YELLOW}Тип:${NC}  $( [ -n "${secret}" ] && echo "MTProto" || echo "SOCKS5" )"
        echo -e "  ${YELLOW}Хост:${NC} ${LAN_IP}"
        echo -e "  ${YELLOW}Порт:${NC} ${proxy_port}"

        if [ -n "${secret}" ]; then
            if [ "${version}" = "rs" ]; then
                echo -e "  ${YELLOW}Ключ:${NC} dd${secret}"
                echo -e "  ${YELLOW}Ссылка:${NC} ${BOLD}tg://proxy?server=${LAN_IP}&port=${proxy_port}&secret=dd${secret}${NC}"
            else
                echo -e "  ${YELLOW}Ключ:${NC} ${secret}"
                echo -e "  ${YELLOW}Ссылка:${NC} ${BOLD}tg://proxy?server=${LAN_IP}&port=${proxy_port}&secret=${secret}${NC}"
            fi
        else
            echo -e "  ${YELLOW}Ссылка:${NC} ${BOLD}tg://socks?server=${LAN_IP}&port=${proxy_port}${NC}"
        fi

        if [ -n "${cf_domain}" ]; then
            echo -e "  ${YELLOW}Cloudflare proxy: ${GREEN}Включен${NC}"
            echo -e "  ${YELLOW}Домены Cloudflare:${NC} ${cf_domain}"
            echo -e "  ${YELLOW}Приоритет Cloudflare:${NC} ${cf_pri}"
        fi

        if [ "${version}" = "rs" ]; then
            INSTALLED_RS="1"
            RUNNING_RS="${running}"
            [ -n "${secret}" ] && MTPROTO_RS="1" || MTPROTO_RS="0"
        elif [ "${version}" = "go" ]; then
            INSTALLED_GO="1"
            RUNNING_GO="${running}"
            [ -n "${secret}" ] && MTPROTO_GO="1" || MTPROTO_GO="0"
        fi
    else
        if [ "${version}" = "rs" ]; then
            INSTALLED_RS="0"
            MTPROTO_RS="0"
        elif [ "${version}" = "go" ]; then
            INSTALLED_GO="0"
            MTPROTO_GO="0"
        fi
    fi
}

# Шапка меню
show_header() {
    clear
    echo -e "╔═════════════════════╗"
    echo -e "║ ${CYAN}TG WS Proxy Manager${NC} ║"
    echo -e "╚═════════════════════╝"
}

main() {
    if ! command -v curl > /dev/null 2>&1; then
        echo -e "${CYAN}Устанавливаем curl${NC}"
        ${UPDATE} > /dev/null 2>&1 && ${INSTALL} curl > /dev/null 2>&1 || {
            echo -e "\n${RED}Ошибка установки curl${NC}"
            PAUSE
            return 1
        }
    fi

    show_header

    show_proxy_status "rs"
    show_proxy_status "go"

    if [ "${INSTALLED_RS}" = "0" ] && [ "${INSTALLED_GO}" = "0" ]; then
        echo -e "\n  ${YELLOW}TG WS Proxy не установлен${NC}"
    fi

    echo -e "\n\n${CYAN}Управление версией [Rust]${NC}"
    echo -e "${CYAN}-----------------------------${NC}"
    echo -e "${CYAN}1)${NC}${BOLD} $( [ ${INSTALLED_RS} = "1" ] && echo "Обновить" || echo "Установить" ) TG WS Proxy${NC}"
    if [ "${INSTALLED_RS}" = "1" ]; then
        echo -e "${CYAN}2)${NC}${BOLD} Настроить Cloudflare Proxy${NC}"
        echo -e "${CYAN}3)${NC}${BOLD} $( [ "${RUNNING_RS}" = "1" ] && echo "Остановить" || echo "Запустить" ) TG WS Proxy${NC}"
        echo -e "${CYAN}4)${RED} Удалить TG WS Proxy${NC}"
    fi
    echo -e "\n${CYAN}Управление версией [Go]${NC}"
    echo -e "${CYAN}-----------------------------${NC}"
    echo -e "${CYAN}5)${NC}${BOLD} $( [ "${INSTALLED_GO}" = "1" ] && echo "Обновить" || echo "Установить" ) TG WS Proxy${NC}"
    if [ "${INSTALLED_GO}" = "1" ]; then
        echo -e "${CYAN}6)${NC}${BOLD} Настроить Cloudflare Proxy${NC}"
        echo -e "${CYAN}7)${NC}${BOLD} $( [ "${RUNNING_GO}" = "1" ] && echo "Остановить" || echo "Запустить" ) TG WS Proxy${NC}"
        echo -e "${CYAN}8)${RED} Удалить TG WS Proxy${NC}"
    fi
    echo -e "\n${CYAN}Enter)${BOLD} Выход${NC}\n"
    echo -en "${YELLOW}Выбери действие: ${NC}"
    read -r choice

    case ${choice} in
        1) 
            install_or_update_tgws "rs" ${INSTALLED_RS}
            ;;
        2)
            [ "${INSTALLED_RS}" = "1" ] && configure_cloudflare "rs"
            ;;
        3)
            if [ "${INSTALLED_RS}" = "1" ]; then
                [ "${RUNNING_RS}" = "1" ] && ${INIT_PATH_RS} stop > /dev/null 2>&1 || ${INIT_PATH_RS} start > /dev/null 2>&1
                echo -e "\n${GREEN}TG WS Proxy ${CYAN}[Rust]${NC} $( [ "${RUNNING_RS}" = "0" ] && echo "${GREEN}запущен${NC}" || echo "${GREEN}остановлен${NC}" )"
                PAUSE
                return
            fi
            ;;
        4)
            [ "${INSTALLED_RS}" = "1" ] && delete_tg_ws "rs"
            ;;
        5) 
            install_or_update_tgws "go" "${INSTALLED_GO}"
            ;;
        6)
            [ "${INSTALLED_GO}" = "1" ] && configure_cloudflare "go"
            ;;
        7)
            if [ "${INSTALLED_GO}" = "1" ]; then
                [ "${RUNNING_GO}" = "1" ] && ${INIT_PATH_GO} stop > /dev/null 2>&1 || ${INIT_PATH_GO} start > /dev/null 2>&1
                echo -e "\n${GREEN}TG WS Proxy ${CYAN}[Go]${NC} $( [ "${RUNNING_GO}" = "0" ] && echo "${GREEN}запущен${NC}" || echo "${GREEN}остановлен${NC}" )"
                PAUSE
                return
            fi
            ;;
        8)
            [ "${INSTALLED_GO}" = "1" ] && delete_tg_ws "go"
            ;;
        *)
            exit 0
            ;;
    esac
}

while true; do
    main
done
