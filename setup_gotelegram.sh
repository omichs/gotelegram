#!/bin/bash
set -euo pipefail

# --- КОНФИГУРАЦИЯ ---
BINARY_PATH="/usr/local/bin/gotelegram"
MTG_IMAGE="nineseconds/mtg:2"
CONTAINER_NAME="mtproto-proxy"

# --- ЦВЕТА ---
RED='\033[0;31m'
GREEN='\033[0;32m'
CYAN='\033[0;36m'
YELLOW='\033[1;33m'
MAGENTA='\033[0;35m'
BLUE='\033[0;34m'
NC='\033[0m'

# --- УТИЛИТЫ ---
log_info()    { echo -e "${CYAN}[INFO]${NC} $*"; }
log_ok()      { echo -e "${GREEN}[ OK ]${NC} $*"; }
log_warn()    { echo -e "${YELLOW}[WARN]${NC} $*"; }
log_err()     { echo -e "${RED}[ERR ]${NC} $*" >&2; }
die()         { log_err "$*"; exit 1; }

# --- СИСТЕМНЫЕ ПРОВЕРКИ ---
check_root() {
    [[ "$EUID" -eq 0 ]] || die "Запустите скрипт через sudo!"
}

detect_pkg_manager() {
    if command -v apt-get &>/dev/null; then
        PKG_MGR="apt-get"
        PKG_INSTALL="apt-get install -y"
        PKG_UPDATE="apt-get update -qq"
    elif command -v dnf &>/dev/null; then
        PKG_MGR="dnf"
        PKG_INSTALL="dnf install -y"
        PKG_UPDATE="dnf check-update -q || true"
    elif command -v yum &>/dev/null; then
        PKG_MGR="yum"
        PKG_INSTALL="yum install -y"
        PKG_UPDATE="true"
    else
        die "Не удалось определить пакетный менеджер (поддерживаются apt/dnf/yum)."
    fi
    log_info "Пакетный менеджер: $PKG_MGR"
}

install_docker() {
    if command -v docker &>/dev/null; then
        log_ok "Docker уже установлен ($(docker --version | awk '{print $3}' | tr -d ','))."
        return
    fi
    log_info "Установка Docker..."
    # Загружаем скрипт во временный файл и проверяем перед запуском
    local tmp_script
    tmp_script=$(mktemp /tmp/docker-install-XXXXXX.sh)
    trap "rm -f $tmp_script" RETURN
    curl -fsSL --max-time 60 https://get.docker.com -o "$tmp_script" \
        || die "Не удалось загрузить скрипт установки Docker."
    bash "$tmp_script" || die "Ошибка установки Docker."
    systemctl enable --now docker || die "Не удалось запустить сервис Docker."
    log_ok "Docker установлен."
}

install_qrencode() {
    if command -v qrencode &>/dev/null; then
        log_ok "qrencode уже установлен."
        return
    fi
    log_info "Установка qrencode..."
    $PKG_UPDATE
    $PKG_INSTALL qrencode || die "Не удалось установить qrencode."
    log_ok "qrencode установлен."
}

install_self() {
    local self_path
    self_path=$(realpath "$0")
    if [[ "$self_path" != "$BINARY_PATH" ]]; then
        cp "$self_path" "$BINARY_PATH"
        chmod +x "$BINARY_PATH"
        log_ok "Команда 'gotelegram' доступна глобально."
    fi
}

install_deps() {
    detect_pkg_manager
    install_docker
    install_qrencode
    install_self
}

# --- СЕТЬ ---
get_ip() {
    local ip=""
    local sources=(
        "https://api.ipify.org"
        "https://icanhazip.com"
        "https://ifconfig.me"
    )
    for src in "${sources[@]}"; do
        ip=$(curl -s -4 --max-time 5 "$src" 2>/dev/null | grep -Eo '([0-9]{1,3}\.){3}[0-9]{1,3}' | head -n1)
        [[ -n "$ip" ]] && echo "$ip" && return
    done
    log_warn "Не удалось определить внешний IP." >&2
    echo "0.0.0.0"
}

is_port_free() {
    local port=$1
    if ss -tlnp 2>/dev/null | grep -q ":${port} "; then
        return 1  # занят
    fi
    return 0  # свободен
}

# --- ДАННЫЕ КОНТЕЙНЕРА ---
# Хранит secret и port в label-ах контейнера для надёжного парсинга
get_container_secret() {
    docker inspect "$CONTAINER_NAME" \
        --format='{{index .Config.Labels "mtg.secret"}}' 2>/dev/null
}

get_container_port() {
    docker inspect "$CONTAINER_NAME" \
        --format='{{index .Config.Labels "mtg.port"}}' 2>/dev/null
}

# --- ПАНЕЛЬ ДАННЫХ ---
show_config() {
    if ! docker ps --format '{{.Names}}' 2>/dev/null | grep -q "^${CONTAINER_NAME}$"; then
        log_warn "Контейнер '${CONTAINER_NAME}' не запущен."
        return 1
    fi

    local secret port ip link
    secret=$(get_container_secret)
    port=$(get_container_port)
    ip=$(get_ip)

    if [[ -z "$secret" || -z "$port" ]]; then
        log_err "Не удалось получить параметры контейнера. Переустановите прокси."
        return 1
    fi

    link="tg://proxy?server=${ip}&port=${port}&secret=${secret}"

    echo -e "\n${GREEN}╔══════════════════════════════════════╗${NC}"
    echo -e "${GREEN}║        ДАННЫЕ ПОДКЛЮЧЕНИЯ            ║${NC}"
    echo -e "${GREEN}╚══════════════════════════════════════╝${NC}"
    echo -e "  IP      : ${BLUE}${ip}${NC}"
    echo -e "  Port    : ${YELLOW}${port}${NC}"
    echo -e "  Secret  : ${YELLOW}${secret}${NC}"
    echo -e "  Ссылка  : ${BLUE}${link}${NC}"
    echo ""
    log_info "QR-код для мобильного подключения:"
    qrencode -t ANSIUTF8 "$link"
}

# --- УСТАНОВКА / ОБНОВЛЕНИЕ ---
menu_install() {
    clear
    echo -e "${CYAN}╔══════════════════════════════════════╗${NC}"
    echo -e "${CYAN}║   Выбор домена для маскировки (TLS)  ║${NC}"
    echo -e "${CYAN}╚══════════════════════════════════════╝${NC}"

    local domains=(
        "google.com"        "wikipedia.org"
        "habr.com"          "github.com"
        "coursera.org"      "udemy.com"
        "medium.com"        "stackoverflow.com"
        "bbc.com"           "cnn.com"
        "reuters.com"       "nytimes.com"
        "lenta.ru"          "rbc.ru"
        "ria.ru"            "kommersant.ru"
        "stepik.org"        "duolingo.com"
        "khanacademy.org"   "ted.com"
    )

    local i
    for i in "${!domains[@]}"; do
        printf "  ${YELLOW}%2d)${NC} %-22s" "$((i+1))" "${domains[$i]}"
        (( (i+1) % 2 == 0 )) && echo ""
    done
    echo ""

    local d_idx domain
    while true; do
        read -rp "Ваш выбор [1-${#domains[@]}]: " d_idx
        if [[ "$d_idx" =~ ^[0-9]+$ ]] && (( d_idx >= 1 && d_idx <= ${#domains[@]} )); then
            domain="${domains[$((d_idx-1))]}"
            break
        fi
        log_warn "Введите число от 1 до ${#domains[@]}."
    done
    log_ok "Домен маскировки: ${domain}"

    echo -e "\n${CYAN}--- Выберите порт ---${NC}"
    echo -e "  1) 443   (рекомендуется)"
    echo -e "  2) 8443"
    echo -e "  3) Свой порт"

    local p_choice port
    read -rp "Выбор [1-3]: " p_choice
    case $p_choice in
        2) port=8443 ;;
        3)
            while true; do
                read -rp "Введите порт (1-65535): " port
                if [[ "$port" =~ ^[0-9]+$ ]] && (( port >= 1 && port <= 65535 )); then
                    break
                fi
                log_warn "Некорректный порт."
            done
            ;;
        *) port=443 ;;
    esac

    # Проверка занятости порта (только если не наш контейнер уже его занимает)
    docker stop "$CONTAINER_NAME" &>/dev/null || true
    docker rm   "$CONTAINER_NAME" &>/dev/null || true

    if ! is_port_free "$port"; then
        die "Порт ${port} уже занят другим процессом. Выберите другой порт."
    fi

    log_info "Обновление образа ${MTG_IMAGE}..."
    docker pull "$MTG_IMAGE" || log_warn "Не удалось обновить образ, используется кэш."

    log_info "Генерация secret для домена '${domain}'..."
    local secret
    secret=$(docker run --rm "$MTG_IMAGE" generate-secret --hex "$domain") \
        || die "Ошибка генерации secret."

    log_info "Запуск контейнера на порту ${port}..."
    docker run -d \
        --name "$CONTAINER_NAME" \
        --restart always \
        -p "${port}:${port}" \
        --label "mtg.secret=${secret}" \
        --label "mtg.port=${port}" \
        "$MTG_IMAGE" \
        simple-run \
            -n 1.1.1.1 \
            -i prefer-ipv4 \
            "0.0.0.0:${port}" \
            "$secret" \
        > /dev/null \
        || die "Не удалось запустить контейнер."

    log_ok "Прокси запущен!"
    echo ""
    show_config
    echo ""
    read -rp "Нажмите Enter для возврата в меню..."
}

# --- УДАЛЕНИЕ ---
menu_remove() {
    if ! docker ps -a --format '{{.Names}}' 2>/dev/null | grep -q "^${CONTAINER_NAME}$"; then
        log_warn "Контейнер '${CONTAINER_NAME}' не найден."
        read -rp "Нажмите Enter..."
        return
    fi
    read -rp "Удалить прокси? Это остановит и удалит контейнер. [y/N]: " confirm
    if [[ "${confirm,,}" == "y" ]]; then
        docker stop "$CONTAINER_NAME" &>/dev/null && \
        docker rm   "$CONTAINER_NAME" &>/dev/null && \
        log_ok "Контейнер удалён." || log_err "Ошибка при удалении."
    else
        log_info "Отменено."
    fi
    read -rp "Нажмите Enter..."
}

# --- ГЛАВНОЕ МЕНЮ ---
main_menu() {
    while true; do
        clear
        echo -e "${MAGENTA}╔══════════════════════════════════════╗${NC}"
        echo -e "${MAGENTA}║      GoTelegram MTProxy Manager      ║${NC}"
        echo -e "${MAGENTA}╚══════════════════════════════════════╝${NC}"

        # Статус контейнера
        if docker ps --format '{{.Names}}' 2>/dev/null | grep -q "^${CONTAINER_NAME}$"; then
            echo -e "  Статус: ${GREEN}● Запущен${NC}"
        else
            echo -e "  Статус: ${RED}○ Остановлен${NC}"
        fi

        echo ""
        echo -e "  1) ${GREEN}Установить / Обновить прокси${NC}"
        echo -e "  2) Показать данные подключения"
        echo -e "  3) ${RED}Удалить прокси${NC}"
        echo -e "  0) Выход"
        echo ""
        read -rp "Пункт: " m_idx
        case $m_idx in
            1) menu_install ;;
            2) clear; show_config; echo ""; read -rp "Нажмите Enter..." ;;
            3) menu_remove ;;
            0) log_ok "До свидания."; exit 0 ;;
            *) log_warn "Неверный ввод." ; sleep 1 ;;
        esac
    done
}

# --- ТОЧКА ВХОДА ---
check_root
install_deps
main_menu
