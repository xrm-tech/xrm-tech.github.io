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
INSTALL_DIR="/opt/xrm-director/docker"
# Обновляем пути к файлам для директории docker
DOCKER_DIR="${INSTALL_DIR}"
DOCKER_COMPOSE_YML="${DOCKER_DIR}/docker-compose.yml"
DOCKER_COMPOSE_GPU_YML="${DOCKER_DIR}/docker-compose-gpu.yml"
DOCKER_ENV="${DOCKER_DIR}/.env"
RAGFLOW_SLIM_IMAGE="infiniflow/ragflow:v0.17.2-slim"
RAGFLOW_FULL_IMAGE="infiniflow/ragflow:v0.17.2"
OLLAMA_LLM_MODEL="akdengi/saiga-gemma2"

# ======= Настройка обработки ошибок и выхода =======
set -o pipefail
trap 'echo "Скрипт прерван. Выход..."; exit 1' SIGINT SIGTERM

# ======= Функции для логирования и проверок =======
# Функция для логирования
log_message() {
    local level="$1"
    local message="$2"
    # Только запись в лог-файл без вывода на экран
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
        if (( 10#${ver2[i]} < 10#${ver1[i]} )); then
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
    show_return_to_menu_message
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
    show_return_to_menu_message
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
    
    echo "===================================================="
    show_return_to_menu_message
}

# Функция для диагностики проблем с контейнером
diagnose_container_issues() {
    local container_name="$1"
    echo "Диагностика контейнера $container_name..."
    
    # Проверка статуса контейнера
    local container_status=$(docker inspect --format '{{.State.Status}}' "$container_name" 2>/dev/null)
    echo "Статус контейнера: $container_status"
    
    # Проверка логов контейнера, даже если он не запустился полностью
    echo "Логи контейнера:"
    docker logs "$container_name" 2>&1 || echo "Не удалось получить логи контейнера"
    
    # Проверка доступных ресурсов
    echo "Свободная память:"
    free -h
    
    echo "Свободное место на диске:"
    df -h /
    
    # Проверка прав доступа и владельца директорий
    if docker inspect --format '{{range .Mounts}}{{.Source}}{{"\n"}}{{end}}' "$container_name" 2>/dev/null | grep -q .; then
        echo "Проверка томов контейнера:"
        for vol in $(docker inspect --format '{{range .Mounts}}{{.Source}}{{"\n"}}{{end}}' "$container_name"); do
            if [ -e "$vol" ]; then
                echo "Том $vol: $(ls -ld "$vol")"
            else
                echo "Том $vol не существует"
            fi
        done
    fi

    # Рекомендации по решению
    echo "Рекомендации по устранению проблемы:"
    echo "1. Убедитесь, что у системы достаточно ресурсов (RAM, CPU)"
    echo "2. Проверьте права доступа к томам и файлам контейнера"
    echo "3. Проверьте все зависимости контейнера"
    echo "4. Убедитесь, что порты не заняты другими сервисами"
}

# Функция для установки XRM Director
install_xrm_director() {
    log_message "INFO" "Установка XRM Director..."

    echo "====== Установка XRM Director ======"

    # Проверяем, установлен ли уже XRM Director
    if docker ps -a | grep -q "ragflow"; then
        log_message "WARNING" "Обнаружена существующая установка XRM Director"
        echo "ВНИМАНИЕ: XRM Director уже установлен. Обнаружены контейнеры ragflow."
        echo "Хотите продолжить и переустановить XRM Director? (д/н)"
        read -r reinstall_choice
        if [[ ! "$reinstall_choice" =~ ^[Дд]$ ]]; then
            echo "Установка отменена пользователем."
            return 0
        fi
        echo "Продолжаем установку..."
    fi

    # Создание директории для установки
    mkdir -p "$INSTALL_DIR"
    cd "$INSTALL_DIR"
    
    # Удаляем существующие файлы, если они есть
    echo "Очистка директории установки..."
    rm -rf "$INSTALL_DIR"/*
    
    # Скачивание архива с файлами XRM Director
    echo "Скачивание архива с файлами XRM Director..."
    if ! curl -sSf https://files.x-rm.ru/xrm_director/docker/docker.tar.gz -o "$INSTALL_DIR/docker.tar.gz"; then
        log_message "ERROR" "Не удалось скачать архив с файлами XRM Director"
        echo "Ошибка: Не удалось скачать архив с файлами XRM Director"
        return 1
    fi
    log_message "INFO" "Архив успешно скачан: $INSTALL_DIR/docker.tar.gz"
    
    # Распаковка архива
    echo "Распаковка архива..."
    mkdir -p "$DOCKER_DIR"
    if ! tar -xzf docker.tar.gz --strip-components=0; then
        log_message "ERROR" "Не удалось распаковать архив"
        echo "Ошибка: Не удалось распаковать архив"
        return 1
    fi
    
    # Вывод списка распакованных файлов
    echo "Распакованные файлы:"
    ls -la "$INSTALL_DIR"
    
    # Удаление архива
    rm -f "$INSTALL_DIR/docker.tar.gz"
    log_message "INFO" "Архив успешно распакован в $INSTALL_DIR"
    
    # Проверка наличия обязательных файлов
    if [ ! -f ".env" ] || [ ! -f "docker-compose.yml" ] || [ ! -f "docker-compose-gpu.yml" ]; then
        log_message "ERROR" "Обязательные файлы не найдены после распаковки архива"
        echo "Ошибка: Обязательные файлы (.env, docker-compose.yml, docker-compose-gpu.yml) не найдены"
        echo "Содержимое директории $INSTALL_DIR:"
        ls -la "$INSTALL_DIR"
        return 1
    fi
    
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
    while true; do
        echo "Выберите версию RAGFlow:"
        echo "0. Вернуться в главное меню"
        echo "1. Slim (v0.17.2-slim) - облегченная версия"
        echo "2. Full (v0.17.2) - полная версия"
        read -r version_choice
        
        # Проверяем выбор
        if [[ "$version_choice" == "0" ]]; then
            echo "Возврат в главное меню..."
            return 0
        elif [[ "$version_choice" =~ ^[1-2]$ ]]; then
            break
        else
            echo "Ошибка: Необходимо выбрать вариант 0, 1 или 2. Повторите ввод."
        fi
    done
    
    # Настройка файла .env
    if [ "$version_choice" -eq 1 ]; then
        # Убедимся, что Slim версия раскомментирована, а Full закомментирована
        sed -i '/RAGFLOW_IMAGE=infiniflow\/ragflow:v0.17.2-slim/ s/^# *//' .env
        sed -i '/RAGFLOW_IMAGE=infiniflow\/ragflow:v0.17.2$/ s/^[^#]/#&/' .env
        log_message "INFO" "Выбрана версия Slim (v0.17.2-slim)"
        echo "Выбрана версия Slim (v0.17.2-slim)"
    elif [ "$version_choice" -eq 2 ]; then
        # Убедимся, что Full версия раскомментирована, а Slim закомментирована
        sed -i '/RAGFLOW_IMAGE=infiniflow\/ragflow:v0.17.2-slim/ s/^[^#]/#&/' .env
        sed -i '/RAGFLOW_IMAGE=infiniflow\/ragflow:v0.17.2$/ s/^# *//' .env
        log_message "INFO" "Выбрана версия Full (v0.17.2)"
        echo "Выбрана версия Full (v0.17.2)"
    else
        log_message "ERROR" "Неверный выбор версии"
        echo "Неверный выбор версии. Установка отменена."
        return 1
    fi
    
    # Выбор режима работы (CPU или GPU)
    while true; do
        echo "Выберите режим работы:"
        echo "0. Вернуться в главное меню"
        echo "1. CPU - использовать процессор для обработки задач"
        echo "2. GPU - использовать графический процессор (требуется NVIDIA)"
        read -r gpu_choice
        
        # Проверяем выбор
        if [[ "$gpu_choice" == "0" ]]; then
            echo "Возврат в главное меню..."
            return 0
        elif [[ "$gpu_choice" =~ ^[1-2]$ ]]; then
            break
        else
            echo "Ошибка: Необходимо выбрать вариант 0, 1 или 2. Повторите ввод."
        fi
    done
    
    # Запуск контейнеров
        
    if [ "$gpu_choice" -eq 2 ]; then
        log_message "INFO" "Установка XRM Director с GPU"
        echo "Установка XRM Director (GPU)..."
        
        if ! docker compose -f docker-compose-gpu.yml up -d; then
            log_message "ERROR" "Не удалось запустить XRM Director с GPU"
            echo "Ошибка: Не удалось запустить XRM Director с GPU"
            return 1
        fi
    else
        log_message "INFO" "Установка XRM Director (CPU)"
        echo "Установка XRM Director с CPU..."
        
        if ! docker compose -f docker-compose.yml up -d; then
            log_message "ERROR" "Не удалось запустить XRM Director с CPU"
            echo "Ошибка: Не удалось запустить XRM Director с CPU"
            return 1
        fi
    fi
    
    # Проверка запуска контейнера ragflow-server
    echo "Проверка запуска контейнера ragflow-server..."
    sleep 5
    
    # Проверка, что контейнер действительно запущен, а не только создан
    local container_status=$(docker inspect --format '{{.State.Status}}' ragflow-server 2>/dev/null)
    if [ "$container_status" != "running" ]; then
        log_message "ERROR" "Контейнер ragflow-server не запустился (статус: $container_status)"
        echo "ОШИБКА: Контейнер ragflow-server не запустился. Текущий статус: $container_status"
        echo "Выполняем диагностику..."
        diagnose_container_issues "ragflow-server"
        
        echo "Пробуем исправить проблему..."
        # Попытка исправить права доступа на директории
        docker_user_id=$(docker inspect --format '{{.Config.User}}' ragflow-server)
        if [ -z "$docker_user_id" ]; then
            docker_user_id="root"
        fi
        echo "Контейнер работает от пользователя: $docker_user_id"
        
        # Обновление прав доступа для всех томов
        for vol in $(docker inspect --format '{{range .Mounts}}{{.Source}}{{"\n"}}{{end}}' ragflow-server); do
            if [ -e "$vol" ]; then
                echo "Обновление прав для тома $vol"
                chmod -R 777 "$vol" || echo "Не удалось обновить права для $vol"
            fi
        done
        
        # Перезапуск контейнера
        echo "Перезапуск контейнера ragflow-server..."
        docker restart ragflow-server
        sleep 5
        
        # Повторная проверка статуса
        container_status=$(docker inspect --format '{{.State.Status}}' ragflow-server 2>/dev/null)
        if [ "$container_status" != "running" ]; then
            log_message "ERROR" "Контейнер ragflow-server все еще не запущен после исправлений"
            echo "ОШИБКА: Контейнер ragflow-server все еще не запущен после исправлений."
            echo "Пожалуйста, проверьте логи Docker для дополнительной информации:"
            echo "docker logs ragflow-server"
            return 1
        else
            log_message "INFO" "Контейнер ragflow-server успешно запущен после исправлений"
            echo "Контейнер ragflow-server успешно запущен после исправлений!"
        fi
    fi
    
    # Ожидание полной инициализации ragflow-server (макс. 180 секунд)
    echo "Ожидание запуска сервера (это может занять некоторое время)..."
    local server_started=false
    for i in {1..36}; do
        if docker logs ragflow-server 2>&1 | grep -q "* Running on all addresses (0.0.0.0)"; then
            echo -e "\nСервер ragflow-server успешно запущен!"
            server_started=true
            break
        fi
        echo -n "."
        sleep 5
    done
    
    if [ "$server_started" = false ]; then
        echo -e "\nПревышено время ожидания запуска сервера (180 секунд)."
        echo "Проверьте логи контейнера: docker logs -f ragflow-server"
        echo "Система может работать некорректно до полного запуска сервера."
        echo "Нажмите Enter для продолжения..."
        read -r
    fi
    
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
    echo "Установка модели $OLLAMA_LLM_MODEL в Ollama..."
    sleep 5
    if ! docker exec ollama ollama run $OLLAMA_LLM_MODEL; then
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
    echo "Ollama API доступен по адресу: http://$server_ip:11434"
    echo "===================================================="
    
    # Дополнительная пауза, чтобы пользователь мог прочитать результат установки
    echo "Нажмите Enter, чтобы вернуться в главное меню..."
    read -r
}

# Функция для перезапуска XRM Director
restart_xrm_director() {
    log_message "INFO" "Перезапуск XRM Director..."
    
    echo "====== Перезапуск XRM Director ======"
    
    # Проверка наличия контейнеров
    if ! docker ps -a | grep -q -E 'ragflow|ollama'; then
        log_message "WARNING" "Контейнеры XRM Director не найдены"
        echo "Контейнеры XRM Director не найдены"
        show_return_to_menu_message
        return 1
    fi
    
    # Получение и перезапуск всех контейнеров с именем, содержащим "ragflow"
    local ragflow_containers=$(docker ps -a --format '{{.Names}}' | grep "ragflow")
    if [ -n "$ragflow_containers" ]; then
        echo "Перезапуск контейнеров ragflow..."
        for container in $ragflow_containers; do
            echo "Перезапуск контейнера $container..."
            if ! docker restart "$container"; then
                log_message "ERROR" "Не удалось перезапустить контейнер $container"
                echo "Ошибка: не удалось перезапустить контейнер $container"
                diagnose_container_issues "$container"
            else
                log_message "INFO" "Контейнер $container успешно перезапущен"
                echo "Контейнер $container успешно перезапущен"
                
                # Проверка статуса после перезапуска
                sleep 3
                local container_status=$(docker inspect --format '{{.State.Status}}' "$container" 2>/dev/null)
                if [ "$container_status" != "running" ]; then
                    log_message "ERROR" "Контейнер $container не запустился после перезапуска"
                    echo "ОШИБКА: Контейнер $container не запустился после перезапуска."
                    diagnose_container_issues "$container"
                fi
            fi
        done
    else
        echo "Контейнеры ragflow не обнаружены"
    fi
    
    # Перезапуск контейнера Ollama, если он существует
    if docker ps -a --format '{{.Names}}' | grep -q "ollama"; then
        echo "Перезапуск контейнера Ollama..."
        if ! docker restart ollama; then
            log_message "ERROR" "Не удалось перезапустить контейнер Ollama"
            echo "Ошибка: не удалось перезапустить контейнер Ollama"
        else
            log_message "INFO" "Контейнер Ollama успешно перезапущен"
            echo "Контейнер Ollama успешно перезапущен"
        fi
    else
        echo "Контейнер Ollama не обнаружен"
    fi
    
    log_message "INFO" "XRM Director успешно перезапущен"
    echo "XRM Director успешно перезапущен"
    
    echo "===================================================="
    show_return_to_menu_message
}

# Функция для удаления XRM Director
remove_xrm_director() {
    log_message "INFO" "Удаление XRM Director..."
    
    echo "====== Удаление XRM Director ======"
    
    # Проверяем наличие контейнеров ragflow
    if ! docker ps -a | grep -q "ragflow"; then
        log_message "WARNING" "Контейнеры XRM Director не найдены"
        echo "Контейнеры XRM Director не найдены."
        
        # Проверка наличия директории установки для удаления
        if [ -d "$INSTALL_DIR" ]; then
            echo "Найдена директория установки. Хотите удалить её? (д/н)"
            read -r remove_dir
            if [[ "$remove_dir" =~ ^[Дд]$ ]]; then
                rm -rf "$INSTALL_DIR"
                log_message "INFO" "Директория установки $INSTALL_DIR удалена"
                echo "Директория установки $INSTALL_DIR удалена"
            fi
        fi
        
        show_return_to_menu_message
        return 1
    fi
    
    # Запрос подтверждения на удаление
    echo "ВНИМАНИЕ! Это действие удалит все контейнеры XRM Director, тома и файлы."
    echo "Хотите продолжить удаление? (д/н)"
    read -r confirm
    
    if [[ ! "$confirm" =~ ^[Дд]$ ]]; then
        echo "Удаление отменено пользователем."
        return 0
    fi
    
    # Получение списка контейнеров с ragflow в имени
    local containers=$(docker ps -a --format '{{.Names}}' | grep "ragflow")
    
    # Сбор информации о томах, подключенных к контейнерам с ragflow
    local volumes_to_remove=()
    
    echo "Получение списка томов, подключенных к контейнерам XRM Director..."
    for container in $containers; do
        echo "Контейнер: $container"
        
        # Получение списка томов для контейнера
        local container_volumes=$(docker inspect "$container" --format='{{range .Mounts}}{{.Name}}{{"\n"}}{{end}}' | grep -v "^$")
        
        if [ -n "$container_volumes" ]; then
            echo "Тома, подключенные к контейнеру $container:"
            echo "$container_volumes"
            
            # Добавляем тома в общий список для удаления
            for vol in $container_volumes; do
                volumes_to_remove+=("$vol")
            done
        fi
    done
    
    # Остановка контейнеров с ragflow
    echo "Остановка контейнеров XRM Director..."
    docker stop $(docker ps -a --format '{{.Names}}' | grep "ragflow") 2>/dev/null
    
    # Удаление контейнеров с ragflow
    echo "Удаление контейнеров XRM Director..."
    docker rm $(docker ps -a --format '{{.Names}}' | grep "ragflow") 2>/dev/null
    
    # Остановка и удаление контейнера Ollama, если он существует
    if docker ps -a --format '{{.Names}}' | grep -q "ollama"; then
        echo "Остановка и удаление контейнера Ollama..."
        docker stop ollama 2>/dev/null
        docker rm ollama 2>/dev/null
    fi
    
    # Удаление томов
    if [ ${#volumes_to_remove[@]} -gt 0 ]; then
        echo "Удаление томов, связанных с XRM Director..."
        for vol in "${volumes_to_remove[@]}"; do
            echo "Удаление тома: $vol"
            docker volume rm "$vol" 2>/dev/null
        done
    fi
    
    # Удаление директории установки
    if [ -d "$INSTALL_DIR" ]; then
        echo "Удаление директории установки..."
        rm -rf "$INSTALL_DIR"
        log_message "INFO" "Директория установки $INSTALL_DIR удалена"
    fi
    
    log_message "INFO" "XRM Director успешно удален"
    echo "===================================================="
    echo "XRM Director и все связанные с ним компоненты успешно удалены!"
    echo "===================================================="
    show_return_to_menu_message
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
    echo -е "\nПоследние логи ragflow-server:"
    if ! docker logs --tail 10 ragflow-server 2>/dev/null; then
        echo "Контейнер ragflow-server не запущен или не найден"
    fi
    
    # Проверка логов ollama
    echo -е "\nПоследние логи ollama:"
    if ! docker logs --tail 10 ollama 2>/dev/null; then
        echo "Контейнер ollama не запущен или не найден"
    fi
    
    # Отображение IP-адреса и портов
    echo -е "\nИнформация о доступе:"
    local server_ip=$(hostname -I | awk '{print $1}')
    echo "XRM Director доступен по адресу: http://$server_ip"
    echo "Ollama API доступен по адресу: http://$server_ip:11434"
    
    # Проверка использования ресурсов
    echo -е "\nИспользование ресурсов контейнерами:"
    docker stats --no-stream ragflow-server ollama 2>/dev/null || echo "Не удалось получить статистику контейнеров"
    
    # Проверка статуса контейнеров c подробной информацией
    echo "Подробный статус контейнеров:"
    docker ps -a | grep -E 'ragflow|ollama' || echo "Контейнеры XRM Director не найдены"
    
    echo -e "\nСтатус контейнера ragflow-server:"
    if docker ps -a --format '{{.Names}}' | grep -q "ragflow-server"; then
        container_status=$(docker inspect --format '{{.State.Status}}' ragflow-server)
        echo "Статус: $container_status"
        
        if [ "$container_status" != "running" ]; then
            echo "ВНИМАНИЕ: Контейнер ragflow-server не запущен!"
            diagnose_container_issues "ragflow-server"
        fi
    else
        echo "Контейнер ragflow-server не найден"
    fi
    
    echo "===================================================="
    show_return_to_menu_message
}

# Функция для отображения сообщения о возврате в главное меню
show_return_to_menu_message() {
    echo -e "\n===================================================="
    echo "Нажмите Enter для возврата в главное меню..."
    read -r
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
    echo "6. Удалить XRM Director"
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
            ;;
        2)
            check_docker_info
            ;;
        3)
            install_docker
            ;;
        4)
            install_xrm_director
            ;;
        5)
            restart_xrm_director
            ;;
        6)
            remove_xrm_director
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
