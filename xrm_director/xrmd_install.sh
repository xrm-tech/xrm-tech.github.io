#!/bin/bash

# ======= Переменные для конфигурации =======
VERSION="1.0"
LOG_FILE="/var/log/xrmd_install.log"
DOCKER_MIN_VERSION="24.0.0"
DOCKER_COMPOSE_MIN_VERSION="v2.26.1"
REQUIRED_CPU_CORES=4
REQUIRED_RAM_GB=16
REQUIRED_DISK_GB=50
MAX_MAP_COUNT=262144
INSTALL_DIR="/opt/xrm-director"
DOCKER_COMPOSE_YML="${INSTALL_DIR}/docker/docker-compose.yml"
DOCKER_COMPOSE_GPU_YML="${INSTALL_DIR}/docker/docker-compose-gpu.yml"
DOCKER_ENV="${INSTALL_DIR}/docker/.env"
RAGFLOW_SLIM_IMAGE="infiniflow/ragflow:v0.17.2-slim"
RAGFLOW_FULL_IMAGE="infiniflow/ragflow:v0.17.2"

# ======= Настройка обработки ошибок и выхода =======
set -o pipefail
trap 'echo "Скрипт прерван. Выход..."; exit 1' SIGINT SIGTERM

# ======= Функции для логирования и проверок =======
# Функция для логирования
log_message() {
    local level="$1"
    local message="$2"
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] [${level}] ${message}"
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] [${level}] ${message}" >> "$LOG_FILE"
}

# Проверка запуска от имени root
check_root() {
    if [ "$EUID" -ne 0 ]; then
        echo "Ошибка: Скрипт должен быть запущен с правами администратора (sudo)"
        exit 1
    fi
}

# Инициализация логирования
init_logging() {
    mkdir -p "$(dirname "$LOG_FILE")"
    touch "$LOG_FILE"
    log_message "INFO" "Запуск скрипта установки XRM Director v$VERSION"
}

# Сравнение версий
check_version() {
    # Удаляем префикс "v" из версий если он присутствует
    local v1=$(echo "$1" | sed 's/^v//')
    local v2=$(echo "$2" | sed 's/^v//')
    
    # Проверка на некорректные значения
    if [[ ! "$v1" =~ ^[0-9]+(\.[0-9]+)*$ ]]; then
        log_message "ERROR" "Некорректная версия: $1"
        return 1
    fi
    
    if [[ ! "$v2" =~ ^[0-9]+(\.[0-9]+)*$ ]]; then
        log_message "ERROR" "Некорректная версия: $2"
        return 1
    fi
    
    if [[ "$v1" == "$v2" ]]; then
        return 0
    fi
    
    local IFS=.
    local i ver1=($v1) ver2=($v2)
    
    # Заполнить нулями, чтобы обе версии имели одинаковое количество элементов
    for ((i=${#ver1[@]}; i<${#ver2[@]}; i++)); do
        ver1[i]=0
    done
    for ((i=${#ver2[@]}; i<${#ver1[@]}; i++)); do
        ver2[i]=0
    done
    
    # Поэлементное сравнение
    for ((i=0; i<${#ver1[@]}; i++)); do
        if [[ -z ${ver1[i]} ]]; then
            ver1[i]=0
        fi
        if [[ -z ${ver2[i]} ]]; then
            ver2[i]=0
        fi
        if (( 10#${ver1[i]} > 10#${ver2[i]} )); then
            return 0
        fi
        if (( 10#${ver1[i]} < 10#${ver2[i]} )); then
            return 1
        fi
    done
    return 0
}

# ======= Функции для пунктов меню =======
# Проверка системных требований
check_system_requirements() {
    log_message "INFO" "Проверка системных требований..."
    
    # Проверка CPU
    local cpu_cores=$(grep -c ^processor /proc/cpuinfo)
    log_message "INFO" "Ядра ЦП: $cpu_cores (требуется: $REQUIRED_CPU_CORES)"
    
    # Проверка RAM
    local ram_gb=$(free -g | awk '/^Mem:/{print $2}')
    log_message "INFO" "Оперативная память: $ram_gb ГБ (требуется: $REQUIRED_RAM_GB ГБ)"
    
    # Проверка места на диске
    local disk_gb=$(df -BG / | awk 'NR==2 {print $4}' | sed 's/G//')
    log_message "INFO" "Свободное место на диске: $disk_gb ГБ (требуется: $REQUIRED_DISK_GB ГБ)"
    
    # Отображение результатов проверки
    echo "====== Результаты проверки системных требований ======"
    echo "1. ЦП: $cpu_cores ядер (минимум: $REQUIRED_CPU_CORES) - $([ "$cpu_cores" -ge "$REQUIRED_CPU_CORES" ] && echo "OK" || echo "НЕ СООТВЕТСТВУЕТ")"
    echo "2. Оперативная память: $ram_gb ГБ (минимум: $REQUIRED_RAM_GB ГБ) - $([ "$ram_gb" -ge "$REQUIRED_RAM_GB" ] && echo "OK" || echo "НЕ СООТВЕТСТВУЕТ")"
    echo "3. Диск: $disk_gb ГБ свободно (минимум: $REQUIRED_DISK_GB ГБ) - $([ "$disk_gb" -ge "$REQUIRED_DISK_GB" ] && echo "OK" || echo "НЕ СООТВЕТСТВУЕТ")"
    
    # Проверка Docker, если установлен
    if command -v docker &>/dev/null; then
        local docker_version=$(docker --version | awk '{print $3}' | sed 's/,//')
        echo "4. Docker: $docker_version (минимум: $DOCKER_MIN_VERSION) - $(check_version "$docker_version" "$DOCKER_MIN_VERSION" && echo "OK" || echo "НЕ СООТВЕТСТВУЕТ")"
    else
        echo "4. Docker: Не установлен"
    fi
    
    # Проверка Docker Compose, если установлен
    if docker compose version &>/dev/null; then
        # Упрощенное получение версии Docker Compose
        local compose_version=$(docker compose version | grep -o "[0-9]\+\.[0-9]\+\.[0-9]\+")
        
        echo "5. Docker Compose: $compose_version (минимум: $DOCKER_COMPOSE_MIN_VERSION) - $(check_version "$compose_version" "$DOCKER_COMPOSE_MIN_VERSION" && echo "OK" || echo "НЕ СООТВЕТСТВУЕТ")"
    else
        echo "5. Docker Compose: Не установлен"
    fi
    echo "===================================================="
}

# Функция для проверки установленных Docker и Docker Compose
check_docker_info() {
    log_message "INFO" "Проверка установленных Docker и Docker Compose..."
    
    echo "====== Информация о Docker и Docker Compose ======"
    
    # Проверка Docker
    if command -v docker &>/dev/null; then
        local docker_version=$(docker --version | awk '{print $3}' | sed 's/,//')
        echo "Docker версия: $docker_version"
        echo ""
        echo "Дополнительная информация о Docker:"
        docker info 2>/dev/null | grep -E "Server Version|Containers|Images|Operating System"
        
        # Проверка на соответствие минимальной версии
        if ! check_version "$docker_version" "$DOCKER_MIN_VERSION"; then
            echo "ВНИМАНИЕ: Установленная версия Docker ($docker_version) ниже рекомендуемой ($DOCKER_MIN_VERSION)"
            echo "Рекомендуется обновить Docker до версии $DOCKER_MIN_VERSION или выше"
            echo "Хотите продолжить установку Docker/Docker Compose? (д/н)"
            read -r answer
            if [[ "$answer" =~ ^[Дд]$ ]]; then
                install_docker
            fi
        fi
    else
        echo "Docker не установлен"
        echo "Хотите установить Docker/Docker Compose? (д/н)"
        read -r answer
        if [[ "$answer" =~ ^[Дд]$ ]]; then
            install_docker
        fi
    fi
    
    echo ""
    
    # Проверка Docker Compose
    if docker compose version &>/dev/null; then
        # Упрощенное получение версии Docker Compose
        local compose_version=$(docker compose version | grep -o "[0-9]\+\.[0-9]\+\.[0-9]\+")
        
        echo "Docker Compose версия: $compose_version (plugin)"
        
        # Проверка на соответствие минимальной версии
        if ! check_version "$compose_version" "$DOCKER_COMPOSE_MIN_VERSION"; then
            echo "ВНИМАНИЕ: Установленная версия Docker Compose ($compose_version) ниже рекомендуемой ($DOCKER_COMPOSE_MIN_VERSION)"
        fi
    else
        echo "Docker Compose не установлен"
        echo "Хотите установить Docker Compose? (д/н)"
        read -r answer
        if [[ "$answer" =~ ^[Дд]$ ]]; then
            install_docker
        fi
    fi
    echo "===================================================="
}

# Функция для установки Docker и Docker Compose
install_docker() {
    log_message "INFO" "Установка Docker и Docker Compose..."
    
    echo "Установка Docker и Docker Compose на RedOS..."
    
    # Установка Docker и Docker Compose
    if ! dnf install -y docker-ce docker-ce-cli docker-compose; then
        log_message "ERROR" "Не удалось установить Docker и Docker Compose"
        echo "Ошибка: Не удалось установить Docker и Docker Compose"
        return 1
    fi
    
    # Запуск и активация службы Docker
    if ! systemctl enable docker --now; then
        log_message "ERROR" "Не удалось запустить и активировать службу Docker"
        echo "Ошибка: Не удалось запустить и активировать службу Docker"
        return 1
    fi
    
    # Проверка статуса службы Docker
    echo "Проверка статуса службы Docker..."
    if ! systemctl status docker | grep -q "active (running)"; then
        log_message "ERROR" "Служба Docker не запущена"
        echo "Ошибка: Служба Docker не запущена"
        return 1
    fi
    
    # Вывод информации о Docker
    echo "Информация о Docker:"
    docker info
    
    # Добавление пользователя в группу docker
    echo "Укажите имя пользователя, который будет работать с Docker:"
    read -r username
    
    if id "$username" &>/dev/null; then
        if ! usermod -aG docker "$username"; then
            log_message "ERROR" "Не удалось добавить пользователя $username в группу docker"
            echo "Ошибка: Не удалось добавить пользователя $username в группу docker"
        else
            log_message "INFO" "Пользователь $username успешно добавлен в группу docker"
            echo "Пользователь $username успешно добавлен в группу docker"
            echo "ВАЖНО: Для применения изменений необходимо выйти из системы и войти снова"
        fi
    else
        log_message "ERROR" "Пользователь $username не существует"
        echo "Ошибка: Пользователь $username не существует"
    fi
    
    log_message "INFO" "Docker и Docker Compose успешно установлены"
    echo "Docker и Docker Compose успешно установлены"
}

# Функция для установки XRM Director
install_xrm_director() {
    log_message "INFO" "Установка XRM Director..."
    
    echo "====== Установка XRM Director ======"
    
    # Проверка и настройка vm.max_map_count
    local current_map_count=$(cat /proc/sys/vm/max_map_count)
    log_message "INFO" "Текущее значение vm.max_map_count: $current_map_count"
    echo "Текущее значение vm.max_map_count: $current_map_count"
    
    if [ "$current_map_count" -lt "$MAX_MAP_COUNT" ]; then
        log_message "INFO" "Установка vm.max_map_count в $MAX_MAP_COUNT"
        echo "Установка vm.max_map_count в $MAX_MAP_COUNT"
        
        # Временное изменение
        if ! sysctl -w vm.max_map_count=$MAX_MAP_COUNT; then
            log_message "ERROR" "Не удалось установить vm.max_map_count"
            echo "Ошибка: Не удалось установить vm.max_map_count"
            return 1
        fi
        
        # Постоянное изменение
        if ! grep -q "vm.max_map_count" /etc/sysctl.conf; then
            echo "vm.max_map_count = $MAX_MAP_COUNT" >> /etc/sysctl.conf
        else
            sed -i "s/vm.max_map_count.*/vm.max_map_count = $MAX_MAP_COUNT/" /etc/sysctl.conf
        fi
    fi
    
    # Выбор версии RAGFlow
    echo "Выберите версию RAGFlow:"
    echo "1. Slim (v0.17.2-slim) - облегченная версия"
    echo "2. Full (v0.17.2) - полная версия"
    read -r version_choice
    
    # Выбор режима работы (CPU или GPU)
    echo "Выберите режим работы:"
    echo "1. CPU - использовать процессор для обработки задач"
    echo "2. GPU - использовать графический процессор (требуется NVIDIA)"
    read -r gpu_choice
    
    # Создание директории для установки
    mkdir -p "${INSTALL_DIR}/docker"
    
    # Создание файла .env
    cat > "$DOCKER_ENV" <<EOF
# Файл конфигурации для XRM Director
RAGFLOW_IMAGE=$([ "$version_choice" -eq 1 ] && echo "$RAGFLOW_SLIM_IMAGE" || echo "$RAGFLOW_FULL_IMAGE")
EOF
    
    log_message "INFO" "Создан файл конфигурации: $DOCKER_ENV"
    echo "Создан файл конфигурации: $DOCKER_ENV"
    
    # Создание файла docker-compose.yml
    cat > "$DOCKER_COMPOSE_YML" <<EOF
version: '3'
services:
  ragflow-server:
    image: \${RAGFLOW_IMAGE}
    container_name: ragflow-server
    restart: always
    ports:
      - "80:80"
    environment:
      - TZ=Asia/Shanghai
EOF

    log_message "INFO" "Создан файл docker-compose.yml: $DOCKER_COMPOSE_YML"
    echo "Создан файл docker-compose.yml: $DOCKER_COMPOSE_YML"
    
    # Создание файла docker-compose-gpu.yml если выбран GPU режим
    if [ "$gpu_choice" -eq 2 ]; then
        cat > "$DOCKER_COMPOSE_GPU_YML" <<EOF
version: '3'
services:
  ragflow-server:
    image: \${RAGFLOW_IMAGE}
    container_name: ragflow-server
    restart: always
    ports:
      - "80:80"
    environment:
      - TZ=Asia/Shanghai
    deploy:
      resources:
        reservations:
          devices:
            - driver: nvidia
              count: 1
              capabilities: [gpu]
EOF
        log_message "INFO" "Создан файл docker-compose-gpu.yml: $DOCKER_COMPOSE_GPU_YML"
        echo "Создан файл docker-compose-gpu.yml: $DOCKER_COMPOSE_GPU_YML"
    fi
    
    # Запуск контейнеров
    echo "Запуск XRM Director..."
    cd "$INSTALL_DIR"
    
    if [ "$gpu_choice" -eq 2 ]; then
        log_message "INFO" "Запуск XRM Director с GPU"
        echo "Запуск XRM Director с GPU..."
        if ! docker compose -f docker-compose-gpu.yml up -d; then
            log_message "ERROR" "Не удалось запустить XRM Director с GPU"
            echo "Ошибка: Не удалось запустить XRM Director с GPU"
            return 1
        fi
    else
        log_message "INFO" "Запуск XRM Director с CPU"
        echo "Запуск XRM Director с CPU..."
        if ! docker compose -f docker-compose.yml up -d; then
            log_message "ERROR" "Не удалось запустить XRM Director с CPU"
            echo "Ошибка: Не удалось запустить XRM Director с CPU"
            return 1
        fi
    fi
    
    # Проверка запуска контейнера
    echo "Проверка запуска контейнера ragflow-server..."
    sleep 5
    
    # Ожидание запуска ragflow-server (макс. 60 секунд)
    echo "Ожидание запуска сервера (это может занять некоторое время)..."
    for i in {1..12}; do
        if docker logs ragflow-server 2>&1 | grep -q "Running on all addresses (0.0.0.0)"; then
            echo "Сервер успешно запущен!"
            break
        fi
        if [ "$i" -eq 12 ]; then
            echo "Превышено время ожидания запуска сервера. Проверьте логи: docker logs -f ragflow-server"
        fi
        echo -n "."
        sleep 5
    done
    
    # Установка Ollama
    echo "Установка Ollama..."
    if ! docker run -d --name ollama -p 11434:11434 ollama/ollama; then
        log_message "ERROR" "Не удалось запустить контейнер Ollama"
        echo "Ошибка: Не удалось запустить контейнер Ollama"
        return 1
    fi
    
    # Проверка доступности порта Ollama
    echo "Проверка доступности порта Ollama..."
    sleep 5
    if ! ss -tunlp | grep -q "11434" && ! netstat -tuln | grep -q "11434"; then
        log_message "ERROR" "Порт Ollama (11434) не доступен"
        echo "Ошибка: Порт Ollama (11434) не доступен"
    else
        log_message "INFO" "Порт Ollama (11434) доступен"
        echo "Порт Ollama (11434) доступен"
    fi
    
    # Установка модели в Ollama
    echo "Установка модели akdengi/saiga-gemma2 в Ollama..."
    sleep 5
    if ! docker exec ollama ollama run akdengi/saiga-gemma2; then
        log_message "ERROR" "Не удалось установить модель в Ollama"
        echo "Ошибка: Не удалось установить модель в Ollama"
        return 1
    fi
    
    # Определение IP-адреса сервера
    local server_ip=$(hostname -I | awk '{print $1}')
    
    log_message "INFO" "XRM Director успешно установлен"
    echo "===================================================="
    echo "XRM Director успешно установлен!"
    echo "Доступ к веб-интерфейсу: http://$server_ip"
    echo "===================================================="
}

# Функция для перезапуска XRM Director
restart_xrm_director() {
    log_message "INFO" "Перезапуск XRM Director..."
    
    echo "====== Перезапуск XRM Director ======"
    
    # Проверка наличия директории установки
    if [ ! -d "$INSTALL_DIR" ]; then
        log_message "ERROR" "Директория установки XRM Director не найдена"
        echo "Ошибка: XRM Director не установлен или директория установки не найдена"
        return 1
    fi
    
    # Перезапуск контейнеров
    cd "$INSTALL_DIR"
    
    # Определение используемого docker-compose файла
    local compose_file="docker-compose.yml"
    if [ -f "$DOCKER_COMPOSE_GPU_YML" ] && docker compose -f "$DOCKER_COMPOSE_GPU_YML" ps | grep -q "ragflow-server"; then
        compose_file="docker-compose-gpu.yml"
    fi
    
    echo "Перезапуск XRM Director с использованием $compose_file..."
    if ! docker compose -f "$compose_file" restart; then
        log_message "ERROR" "Не удалось перезапустить XRM Director"
        echo "Ошибка: Не удалось перезапустить XRM Director"
        return 1
    fi
    
    # Перезапуск контейнера Ollama
    echo "Перезапуск контейнера Ollama..."
    if ! docker restart ollama; then
        log_message "ERROR" "Не удалось перезапустить контейнер Ollama"
        echo "Ошибка: Не удалось перезапустить контейнер Ollama"
    fi
    
    log_message "INFO" "XRM Director успешно перезапущен"
    echo "XRM Director успешно перезапущен"
}

# Функция для вывода статуса XRM Director
xrm_director_status() {
    log_message "INFO" "Проверка статуса XRM Director..."
    
    echo "====== Статус XRM Director ======"
    
    # Проверка статуса контейнеров
    echo "Статус контейнеров:"
    if ! docker ps -a | grep -E 'ragflow-server|ollama'; then
        echo "Контейнеры XRM Director не найдены"
    fi
    
    # Проверка логов ragflow-server
    echo -e "\nПоследние логи ragflow-server:"
    if ! docker logs --tail 10 ragflow-server 2>/dev/null; then
        echo "Контейнер ragflow-server не запущен или не найден"
    fi
    
    # Проверка логов ollama
    echo -e "\nПоследние логи ollama:"
    if ! docker logs --tail 10 ollama 2>/dev/null; then
        echo "Контейнер ollama не запущен или не найден"
    fi
    
    # Отображение IP-адреса и портов
    echo -e "\nИнформация о доступе:"
    local server_ip=$(hostname -I | awk '{print $1}')
    echo "XRM Director доступен по адресу: http://$server_ip"
    echo "Ollama API доступен по адресу: http://$server_ip:11434"
    
    # Проверка использования ресурсов
    echo -e "\nИспользование ресурсов контейнерами:"
    docker stats --no-stream ragflow-server ollama 2>/dev/null || echo "Не удалось получить статистику контейнеров"
}

# Функция вывода интерактивного меню
show_menu() {
    clear
    echo "=========================================="
    echo "          XRM Director версия $VERSION         "
    echo "=========================================="
    echo ""
    echo "Меню:"
    echo ""
    echo "1. Системные требования"
    echo "2. Информация об установленных Docker / Docker Compose"
    echo "3. Установить Docker / Docker Compose (RedOS)"
    echo "4. Установить XRM Director"
    echo "5. Перезапустить XRM Director"
    echo "6. XRM Director"
    echo "7. Выйти"
    echo ""
    echo -n "Выберите пункт меню: "
}

# ======= Основной код =======
# Проверка прав root
check_root

# Инициализация логирования
init_logging

# Основной цикл меню
while true; do
    show_menu
    read -r choice
    
    case $choice in
        1)
            check_system_requirements
            echo -e "\nНажмите Enter для продолжения..."
            read -r
            ;;
        2)
            check_docker_info
            echo -e "\nНажмите Enter для продолжения..."
            read -r
            ;;
        3)
            install_docker
            echo -e "\nНажмите Enter для продолжения..."
            read -r
            ;;
        4)
            install_xrm_director
            echo -е "\nНажмите Enter для продолжения..."
            read -r
            ;;
        5)
            restart_xrm_director
            echo -е "\nНажмите Enter для продолжения..."
            read -r
            ;;
        6)
            xrm_director_status
            echo -е "\nНажмите Enter для продолжения..."
            read -r
            ;;
        7)
            log_message "INFO" "Завершение работы скрипта"
            echo "Спасибо за использование скрипта установки XRM Director. До свидания!"
            exit 0
            ;;
        *)
            echo "Неверный выбор. Пожалуйста, выберите пункт меню от 1 до 7."
            sleep 2
            ;;
    esac
done
