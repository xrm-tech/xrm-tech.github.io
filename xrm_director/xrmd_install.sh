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
OLLAMA_LLM_MODEL_2="nomic-embed-text"

# Переменные для резервного копирования
BACKUP_DIR="/opt/xrm-director/backups"
PROJECT_NAME="ragflow"
DATE_FORMAT="$(date +%Y-%m-%d_%H-%M-%S)"

# ======= Настройки резервного копирования =======
INITIAL_BACKUP_URL="https://files.x-rm.ru/xrm_director/backup/initial_backup.tar.gz"
INITIAL_BACKUP_DIR="${BACKUP_DIR}/initial"
USER_BACKUP_DIR="${BACKUP_DIR}/user"
AUTO_RESTORE_INITIAL_BACKUP=1 # 0 - отключить, 1 - включить авторазвертывание initial backup

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
    
    # Создание директорий для резервных копий
    mkdir -p "${INITIAL_BACKUP_DIR}" "${USER_BACKUP_DIR}"
    
    # Скачивание initial backup только в директорию initial
    echo "Загрузка initial backup..."
    if ! wget --no-check-certificate -O "${INITIAL_BACKUP_DIR}/initial_backup.tar.gz" "${INITIAL_BACKUP_URL}" || [ ! -s "${INITIAL_BACKUP_DIR}/initial_backup.tar.gz" ]; then
        log_message "WARNING" "Не удалось загрузить initial backup"
        echo "Предупреждение: Initial backup не загружен"
        
        # Попытка загрузить напрямую по конкретному URL
        echo "Пробуем альтернативную загрузку initial backup..."
        if ! wget --no-check-certificate -O "${INITIAL_BACKUP_DIR}/initial_backup.tar.gz" "https://files.x-rm.ru/xrm_director/backup/initial_backup.tar.gz"; then
            log_message "WARNING" "Альтернативная загрузка initial backup тоже не удалась"
            echo "Предупреждение: Альтернативная загрузка initial backup тоже не удалась"
        else
            log_message "INFO" "Initial backup успешно загружен альтернативным способом"
            echo "Initial backup загружен в ${INITIAL_BACKUP_DIR}"
        fi
    else
        log_message "INFO" "Initial backup успешно загружен"
        echo "Initial backup загружен в ${INITIAL_BACKUP_DIR}"
    fi
    
    echo "Директории для бэкапов созданы:"
    echo "- ${INITIAL_BACKUP_DIR} (для системных бэкапов)"
    echo "- ${USER_BACKUP_DIR} (для пользовательских бэкапов)"
    
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
    
    # Автовосстановление initial backup
    if [ ${AUTO_RESTORE_INITIAL_BACKUP} -eq 1 ]; then
        echo "Проверка наличия initial backup..."
        if [ -f "${INITIAL_BACKUP_DIR}/initial_backup.tar.gz" ]; then
            echo "Развертывание начальной резервной копии..."
            
            # Создаем временную директорию для распаковки
            TEMP_RESTORE_DIR=$(mktemp -d)
            
            # Распаковываем архив
            tar -xzf "${INITIAL_BACKUP_DIR}/initial_backup.tar.gz" -C "${TEMP_RESTORE_DIR}"
            
            # Находим директорию с бэкапами (обычно имеет формат ragflow_DATE)
            BACKUP_FOLDER=$(find "${TEMP_RESTORE_DIR}" -type d -name "ragflow_*" | head -n 1)
            
            if [ -z "${BACKUP_FOLDER}" ]; then
                # Если папка не найдена, используем корневую директорию временной папки
                BACKUP_FOLDER="${TEMP_RESTORE_DIR}"
            fi
            
            echo "Найдена директория с бэкапами: ${BACKUP_FOLDER}"
            
            # Восстанавливаем каждый том
            for volume_backup in "${BACKUP_FOLDER}"/*.tar.gz; do
                if [ -f "${volume_backup}" ]; then
                    # Извлекаем корректное имя тома из имени файла (docker_esdata01.tar.gz -> docker_esdata01)
                    volume_name=$(basename "${volume_backup}" .tar.gz)
                    echo "Восстановление тома ${volume_name}..."
                    
                    # Создаем том если не существует
                    docker volume create "${volume_name}" >/dev/null 2>&1 || true
                    
                    # Восстанавливаем данные
                    docker run --rm -v "${volume_name}":/volume \
                        -v "${BACKUP_FOLDER}":/backup alpine \
                        sh -c "rm -rf /volume/* && tar -xzf /backup/$(basename "${volume_backup}") -C /volume"
                    
                    if [ $? -eq 0 ]; then
                        echo "✅ Том ${volume_name} успешно восстановлен"
                    else
                        echo "❌ Ошибка при восстановлении тома ${volume_name}"
                    fi
                fi
            done
            
            # Очистка временной директории
            rm -rf "${TEMP_RESTORE_DIR}"
            echo "Начальная резервная копия успешно развернута"
        else
            echo "Initial backup не найден, пропускаем авторазвертывание"
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
    
    # Установка моделей в Ollama
    echo "Установка моделей в Ollama..."
    sleep 5
    
    # Установка первой модели (LLM)
    echo "Установка модели $OLLAMA_LLM_MODEL в Ollama..."
    if ! docker exec ollama ollama run $OLLAMA_LLM_MODEL; then
        log_message "ERROR" "Не удалось установить модель $OLLAMA_LLM_MODEL в Ollama"
        echo "Ошибка: Не удалось установить модель $OLLAMA_LLM_MODEL в Ollama"
        return 1
    else
        log_message "INFO" "Модель $OLLAMA_LLM_MODEL успешно установлена в Ollama"
        echo "Модель $OLLAMA_LLM_MODEL успешно установлена в Ollama"
    fi
    
    # Установка второй модели (embedding)
    echo "Установка модели $OLLAMA_LLM_MODEL_2 (embedding) в Ollama..."
    if ! docker exec ollama ollama pull $OLLAMA_LLM_MODEL_2; then
        log_message "ERROR" "Не удалось установить модель $OLLAMA_LLM_MODEL_2 в Ollama"
        echo "Ошибка: Не удалось установить модель $OLLAMA_LLM_MODEL_2 в Ollama"
        return 1
    else
        log_message "INFO" "Модель $OLLAMA_LLM_MODEL_2 успешно установлена в Ollama"
        echo "Модель $OLLAMA_LLM_MODEL_2 успешно установлена в Ollama"
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
    echo "7. Резервное копирование / Восстановление"
    echo "8. Выйти"
    echo ""
    echo -n "Выберите пункт меню: "
}

# Функция для отображения цветного текста
print_color() {
    COLOR="$1"
    TEXT="$2"
    case $COLOR in
        "red") echo -e "\033[0;31m${TEXT}\033[0m" ;;
        "green") echo -e "\033[0;32m${TEXT}\033[0m" ;;
        "yellow") echo -e "\033[0;33m${TEXT}\033[0m" ;;
        "blue") echo -e "\033[0;34m${TEXT}\033[0m" ;;
        *) echo "$TEXT" ;;
    esac
}

# Проверка наличия Docker
check_docker() {
    if ! command -v docker &> /dev/null; then
        print_color "red" "❌ Docker не установлен. Установите Docker для продолжения."
        exit 1
    fi
}

# Список томов проекта
get_volumes() {
    echo "🔍 Определяем доступные тома..."
    VOLUMES=(
      "docker_esdata01"
      "docker_mysql_data"
      "docker_minio_data"
      "docker_redis_data"
    )
    
    # Проверяем наличие тома infinity_data
    if docker volume inspect docker_infinity_data &>/dev/null; then
        VOLUMES+=("docker_infinity_data")
    fi
    
    echo "📋 Найдено томов: ${#VOLUMES[@]}"
    for vol in "${VOLUMES[@]}"; do
        echo "  - $vol"
    done
}

# Остановка всех контейнеров
stop_containers() {
    print_color "yellow" "🛑 Останавливаем контейнеры..."
    cd "$INSTALL_DIR"
    docker compose -f docker-compose.yml down
}

# Запуск всех контейнеров
start_containers() {
    print_color "green" "▶️ Запускаем контейнеры..."
    cd "$INSTALL_DIR"
    docker compose -f docker-compose.yml up -d
}

# Создание резервной копии
create_backup() {
    # Убеждаемся, что директория для пользовательских бэкапов существует
    mkdir -p "${USER_BACKUP_DIR}"

    print_color "blue" "🚀 Начинаем резервное копирование томов ${PROJECT_NAME} (${DATE_FORMAT})"
    
    # Останавливаем контейнеры
    stop_containers
    
    # Получаем список томов
    get_volumes
    
    # Счетчик успешных архиваций
    SUCCESS_COUNT=0
    
    # Создаем директорию для текущего бэкапа в пользовательском каталоге
    BACKUP_SUBDIR="${USER_BACKUP_DIR}/${PROJECT_NAME}_${DATE_FORMAT}"
    mkdir -p "${BACKUP_SUBDIR}"
    
    # Архивируем каждый том
    for VOLUME in "${VOLUMES[@]}"; do
      # Проверяем существование тома через docker volume inspect
      if docker volume inspect ${VOLUME} &>/dev/null; then
        print_color "blue" "📁 Архивирую том ${VOLUME}..."
        
        # Используем docker контейнер для доступа к томам
        docker run --rm -v ${VOLUME}:/volume -v ${BACKUP_SUBDIR}:/backup alpine tar -czf /backup/${VOLUME}.tar.gz -C /volume ./
        
        # Проверяем успешность архивации
        if [ $? -eq 0 ]; then
          print_color "green" "✅ Том ${VOLUME} успешно архивирован"
          SUCCESS_COUNT=$((SUCCESS_COUNT + 1))
        else
          print_color "red" "❌ Ошибка при архивации тома ${VOLUME}"
        fi
      else
        print_color "yellow" "⚠️ Том ${VOLUME} не найден, пропускаем"
      fi
    done
    
    # Запускаем контейнеры снова
    start_containers

    # Создаем метаинформацию о бэкапе
    echo "Дата создания: $(date)" > "${BACKUP_SUBDIR}/backup_info.txt"
    echo "Версия Docker: $(docker --version)" >> "${BACKUP_SUBDIR}/backup_info.txt"
    echo "Контейнеры:" >> "${BACKUP_SUBDIR}/backup_info.txt"
    docker ps -a >> "${BACKUP_SUBDIR}/backup_info.txt"
    
    # Выводим информацию о созданных архивах
    print_color "blue" "📊 Информация о созданном бэкапе:"
    if [ $SUCCESS_COUNT -gt 0 ]; then
      ls -lh ${BACKUP_SUBDIR}/*.tar.gz 2>/dev/null
      print_color "green" "🎉 Успешно архивировано томов: ${SUCCESS_COUNT} из ${#VOLUMES[@]}"
      print_color "green" "📂 Бэкап сохранен в: ${BACKUP_SUBDIR}"
      
      # Создаем общий архив для удобства переноса
      tar -czf "${USER_BACKUP_DIR}/${PROJECT_NAME}_full_${DATE_FORMAT}.tar.gz" -C "${USER_BACKUP_DIR}" $(basename ${BACKUP_SUBDIR})
      print_color "green" "📦 Создан полный архив: ${USER_BACKUP_DIR}/${PROJECT_NAME}_full_${DATE_FORMAT}.tar.gz"
    else
      print_color "red" "⚠️ Не удалось создать ни одного архива"
      rm -rf "${BACKUP_SUBDIR}"
    fi
}

# Получение списка доступных бэкапов
list_backups() {
    # Проверяем и создаем директории, если не существуют
    mkdir -p "${USER_BACKUP_DIR}" "${INITIAL_BACKUP_DIR}"
    
    print_color "blue" "📋 Доступные пользовательские бэкапы:"
    
    # Ищем полные архивы пользовательских бэкапов
    FULL_BACKUPS=($(find "${USER_BACKUP_DIR}" -maxdepth 1 -name "${PROJECT_NAME}_full_*.tar.gz" 2>/dev/null | sort -r))
    
    if [ ${#FULL_BACKUPS[@]} -eq 0 ]; then
        print_color "yellow" "⚠️ Пользовательские полные архивы не найдены"
    else
        echo "Найдено ${#FULL_BACKUPS[@]} архивов:"
        for i in "${!FULL_BACKUPS[@]}"; do
            filename=$(basename "${FULL_BACKUPS[$i]}")
            size=$(du -h "${FULL_BACKUPS[$i]}" | cut -f1)
            date_created=$(date -r "${FULL_BACKUPS[$i]}" "+%Y-%m-%d %H:%M:%S")
            echo "[$i] ${filename} (${size}, создан: ${date_created})"
        done
    fi
    
    # Ищем директории с пользовательскими бэкапами
    DIR_BACKUPS=($(find "${USER_BACKUP_DIR}" -maxdepth 1 -type d -name "${PROJECT_NAME}_*" 2>/dev/null | sort -r))
    
    if [ ${#DIR_BACKUPS[@]} -gt 0 ]; then
        print_color "blue" "📂 Директории с отдельными пользовательскими бэкапами томов:"
        for i in "${!DIR_BACKUPS[@]}"; do
            if [ "${DIR_BACKUPS[$i]}" != "${USER_BACKUP_DIR}" ]; then
                dirname=$(basename "${DIR_BACKUPS[$i]}")
                echo "[$i] ${dirname}"
            fi
        done
    fi

    # Проверяем наличие initial backup
    echo ""
    print_color "blue" "📋 Системные бэкапы (initial):"
    if [ -f "${INITIAL_BACKUP_DIR}/initial_backup.tar.gz" ]; then
        size=$(du -h "${INITIAL_BACKUP_DIR}/initial_backup.tar.gz" | cut -f1)
        date_created=$(date -r "${INITIAL_BACKUP_DIR}/initial_backup.tar.gz" "+%Y-%m-%d %H:%M:%S")
        echo "[S] initial_backup.tar.gz (${size}, создан: ${date_created})"
    else
        print_color "yellow" "⚠️ Системный бэкап не найден"
    fi
}

# Восстановление из бэкапа
restore_backup() {
    print_color "blue" "🔄 Восстановление из бэкапа"
    
    # Показываем доступные бэкапы
    list_backups
    
    # Ищем полные пользовательские архивы
    FULL_BACKUPS=($(find "${USER_BACKUP_DIR}" -maxdepth 1 -name "${PROJECT_NAME}_full_*.tar.gz" 2>/dev/null | sort -r))

    # Проверяем, есть ли хоть один бэкап (пользовательский или системный)
    if [ ${#FULL_BACKUPS[@]} -eq 0 ] && [ ! -f "${INITIAL_BACKUP_DIR}/initial_backup.tar.gz" ]; then
        print_color "red" "❌ Нет доступных бэкапов для восстановления"
        return 1
    fi
    
    echo ""
    echo "Выберите источник восстановления:"
    echo "1. Пользовательский бэкап (введите номер из списка)"
    echo "S. Системный бэкап (initial)"
    echo "q. Отмена"
    read -p "Ваш выбор: " backup_choice
    
    if [ "$backup_choice" == "q" ]; then
        print_color "yellow" "❌ Восстановление отменено пользователем"
        return 0
    elif [ "$backup_choice" == "S" ] || [ "$backup_choice" == "s" ]; then
        # Восстанавливаем из системного бэкапа
        if [ ! -f "${INITIAL_BACKUP_DIR}/initial_backup.tar.gz" ]; then
            print_color "red" "❌ Системный бэкап не найден"
            return 1
        fi
        
        print_color "yellow" "⚠️ Внимание! Восстановление из системного бэкапа перезапишет текущие данные томов."
        read -p "Вы уверены? (y/n): " confirm
        
        if [ "$confirm" != "y" ]; then
            print_color "yellow" "❌ Восстановление отменено пользователем"
            return 0
        fi
        
        # Останавливаем контейнеры
        stop_containers
        
        # Создаем временную директорию для распаковки
        TEMP_DIR=$(mktemp -d)
        print_color "blue" "📂 Распаковываем системный архив во временную директорию: ${TEMP_DIR}"
        
        # Распаковываем архив
        tar -xzf "${INITIAL_BACKUP_DIR}/initial_backup.tar.gz" -C "${TEMP_DIR}"
        
        # Находим директорию с бэкапами (обычно имеет формат ragflow_DATE)
        BACKUP_FOLDER=$(find "${TEMP_DIR}" -type d -name "ragflow_*" | head -n 1)
        
        if [ -z "${BACKUP_FOLDER}" ]; then
            # Если папка не найдена, используем корневую директорию временной папки
            BACKUP_FOLDER="${TEMP_DIR}"
        fi
        
        print_color "blue" "📂 Найдена директория с бэкапами: ${BACKUP_FOLDER}"
        
        # Восстанавливаем тома из системного бэкапа
        SUCCESS_COUNT=0
        VOLUMES_TOTAL=0
        
        # Перебираем все tar.gz файлы в распакованной директории
        for archive in "${BACKUP_FOLDER}"/*.tar.gz; do
            if [ -f "$archive" ]; then
                VOLUMES_TOTAL=$((VOLUMES_TOTAL + 1))
                volume_name=$(basename "$archive" .tar.gz)
                print_color "blue" "🔄 Восстанавливаем том $volume_name..."
                
                # Проверяем существование тома
                if ! docker volume inspect "$volume_name" &>/dev/null; then
                    print_color "yellow" "⚠️ Том $volume_name не существует, создаем..."
                    docker volume create "$volume_name" > /dev/null
                fi
                
                # Восстанавливаем данные тома
                docker run --rm -v "$volume_name":/volume -v "${BACKUP_FOLDER}":/backup alpine sh -c "rm -rf /volume/* && tar -xzf /backup/$(basename $archive) -C /volume"
                
                if [ $? -eq 0 ]; then
                    print_color "green" "✅ Том $volume_name успешно восстановлен"
                    SUCCESS_COUNT=$((SUCCESS_COUNT + 1))
                else
                    print_color "red" "❌ Ошибка при восстановлении тома $volume_name"
                fi
            fi
        done
        
        # Удаляем временную директорию
        rm -rf "$TEMP_DIR"
        
        # Запускаем контейнеры
        start_containers
        
        if [ $SUCCESS_COUNT -gt 0 ]; then
            print_color "green" "🎉 Успешно восстановлено томов из системного бэкапа: $SUCCESS_COUNT из $VOLUMES_TOTAL"
        else
            print_color "red" "❌ Не удалось восстановить ни одного тома из системного бэкапа"
        fi
    
    else
        # Восстанавливаем из пользовательского бэкапа
        if [ ${#FULL_BACKUPS[@]} -eq 0 ]; then
            print_color "red" "❌ Нет доступных пользовательских бэкапов для восстановления"
            return 1
        fi
        
        # Проверяем корректность ввода
        if ! [[ "$backup_choice" =~ ^[0-9]+$ ]] || [ $backup_choice -ge ${#FULL_BACKUPS[@]} ]; then
            print_color "red" "❌ Некорректный номер бэкапа"
            return 1
        fi
        
        # Выбранный бэкап
        selected_backup="${FULL_BACKUPS[$backup_choice]}"
        backup_name=$(basename "$selected_backup" .tar.gz)
        
        print_color "yellow" "⚠️ Внимание! Восстановление из бэкапа перезапишет текущие данные томов."
        read -p "Вы уверены, что хотите восстановить данные из '$backup_name'? (y/n): " confirm
        
        if [ "$confirm" != "y" ]; then
            print_color "yellow" "❌ Восстановление отменено пользователем"
            return 0
        fi
        
        # Останавливаем контейнеры
        stop_containers
        
        # Создаем временную директорию для распаковки
        TEMP_DIR=$(mktemp -d)
        print_color "blue" "📂 Распаковываем архив во временную директорию: ${TEMP_DIR}"
        
        # Распаковываем полный архив
        tar -xzf "$selected_backup" -C "$TEMP_DIR"
        
        # Получаем имя распакованной директории
        UNPACKED_DIR=$(find "$TEMP_DIR" -maxdepth 1 -type d -name "${PROJECT_NAME}_*" | head -n 1)
        
        if [ -z "$UNPACKED_DIR" ]; then
            print_color "red" "❌ Ошибка при распаковке архива"
            start_containers
            rm -rf "$TEMP_DIR"
            return 1
        fi
        
        # Восстанавливаем тома
        SUCCESS_COUNT=0
        VOLUMES_TOTAL=0
        
        # Перебираем все tar.gz файлы в распакованной директории
        for archive in "$UNPACKED_DIR"/*.tar.gz; do
            if [ -f "$archive" ]; then
                VOLUMES_TOTAL=$((VOLUMES_TOTAL + 1))
                volume_name=$(basename "$archive" .tar.gz)
                print_color "blue" "🔄 Восстанавливаем том $volume_name..."
                
                # Проверяем существование тома
                if ! docker volume inspect "$volume_name" &>/dev/null; then
                    print_color "yellow" "⚠️ Том $volume_name не существует, создаем..."
                    docker volume create "$volume_name" > /dev/null
                fi
                
                # Восстанавливаем данные тома
                docker run --rm -v "$volume_name":/volume -v "$UNPACKED_DIR":/backup alpine sh -c "rm -rf /volume/* && tar -xzf /backup/$(basename $archive) -C /volume"
                
                if [ $? -eq 0 ]; then
                    print_color "green" "✅ Том $volume_name успешно восстановлен"
                    SUCCESS_COUNT=$((SUCCESS_COUNT + 1))
                else
                    print_color "red" "❌ Ошибка при восстановлении тома $volume_name"
                fi
            fi
        done
        
        # Удаляем временную директорию
        rm -rf "$TEMP_DIR"
        
        # Запускаем контейнеры
        start_containers
        
        if [ $SUCCESS_COUNT -gt 0 ]; then
            print_color "green" "🎉 Успешно восстановлено томов из пользовательского бэкапа: $SUCCESS_COUNT из $VOLUMES_TOTAL"
        else
            print_color "red" "❌ Не удалось восстановить ни одного тома из пользовательского бэкапа"
        fi
    fi
}

# Управление бэкапами (удаление старых)
manage_backups() {
    print_color "blue" "📊 Управление резервными копиями"
    
    # Проверяем и создаем директории, если не существуют
    mkdir -p "${USER_BACKUP_DIR}" "${INITIAL_BACKUP_DIR}"
    
    # Показываем доступные бэкапы
    list_backups
    
    # Ищем полные архивы
    FULL_BACKUPS=($(find "${USER_BACKUP_DIR}" -maxdepth 1 -name "${PROJECT_NAME}_full_*.tar.gz" 2>/dev/null | sort -r))
    
    echo ""
    echo "Выберите действие:"
    echo "1. Удалить выбранный пользовательский бэкап"
    echo "2. Оставить только последние N пользовательских бэкапов"
    echo "3. Удалить все пользовательские бэкапы"
    echo "4. Удалить системный (initial) бэкап"
    echo "5. Вернуться в главное меню"
    
    read -p "Введите номер действия: " action
    
    case $action in
        1)
            if [ ${#FULL_BACKUPS[@]} -eq 0 ]; then
                print_color "red" "❌ Нет доступных бэкапов для удаления"
                return
            fi
            
            read -p "Введите номер бэкапа для удаления: " backup_number
            if ! [[ "$backup_number" =~ ^[0-9]+$ ]] || [ $backup_number -ge ${#FULL_BACKUPS[@]} ]; then
                print_color "red" "❌ Некорректный номер бэкапа"
            else
                selected_backup="${FULL_BACKUPS[$backup_number]}"
                backup_name=$(basename "$selected_backup")
                
                read -p "Вы действительно хотите удалить '$backup_name'? (y/n): " confirm
                if [ "$confirm" == "y" ]; then
                    # Удаляем архив
                    rm -f "$selected_backup"
                    
                    # Удаляем соответствующую директорию
                    backup_dir_name=$(basename "$selected_backup" .tar.gz)
                    if [ -d "${USER_BACKUP_DIR}/${backup_dir_name}" ]; then
                        rm -rf "${USER_BACKUP_DIR}/${backup_dir_name}"
                    fi
                    
                    print_color "green" "✅ Бэкап '$backup_name' успешно удален"
                fi
            fi
            ;;
        2)
            read -p "Сколько последних бэкапов оставить? " keep_count
            if ! [[ "$keep_count" =~ ^[0-9]+$ ]] || [ $keep_count -le 0 ]; then
                print_color "red" "❌ Некорректное количество"
            else
                if [ ${#FULL_BACKUPS[@]} -le $keep_count ]; then
                    print_color "yellow" "ℹ️ Количество существующих бэкапов (${#FULL_BACKUPS[@]}) не превышает указанное значение ($keep_count)"
                else
                    to_delete=$((${#FULL_BACKUPS[@]} - keep_count))
                    read -p "Будет удалено $to_delete старых бэкапов. Продолжить? (y/n): " confirm
                    if [ "$confirm" == "y" ]; then
                        for ((i=keep_count; i<${#FULL_BACKUPS[@]}; i++)); do
                            backup_to_delete="${FULL_BACKUPS[$i]}"
                            backup_name=$(basename "$backup_to_delete")
                            
                            # Удаляем архив
                            rm -f "$backup_to_delete"
                            
                            # Удаляем соответствующую директорию
                            backup_dir_name=$(basename "$backup_to_delete" .tar.gz)
                            if [ -d "${USER_BACKUP_DIR}/${backup_dir_name}" ]; then
                                rm -rf "${USER_BACKUP_DIR}/${backup_dir_name}"
                            fi
                            
                            print_color "green" "✅ Бэкап '$backup_name' удален"
                        done
                        print_color "green" "✅ Удаление старых бэкапов завершено"
                    fi
                fi
            fi
            ;;
        3)
            read -p "Вы действительно хотите удалить ВСЕ пользовательские бэкапы? Это действие необратимо! (yes/n): " confirm
            if [ "$confirm" == "yes" ]; then
                rm -f "${USER_BACKUP_DIR}/${PROJECT_NAME}_full_"*.tar.gz
                rm -rf "${USER_BACKUP_DIR}/${PROJECT_NAME}_"*
                print_color "green" "✅ Все пользовательские бэкапы удалены"
            else
                print_color "yellow" "❌ Удаление отменено"
            fi
            ;;
        4)
            if [ -f "${INITIAL_BACKUP_DIR}/initial_backup.tar.gz" ]; then
                read -p "Вы действительно хотите удалить системный (initial) бэкап? (yes/n): " confirm
                if [ "$confirm" == "yes" ]; then
                    rm -f "${INITIAL_BACKUP_DIR}/initial_backup.tar.gz"
                    print_color "green" "✅ Системный бэкап удален"
                else
                    print_color "yellow" "❌ Удаление отменено"
                fi
            else
                print_color "yellow" "⚠️ Системный бэкап не найден"
            fi
            ;;
        5)
            return
            ;;
        *)
            print_color "red" "❌ Некорректный выбор"
            ;;
    esac
}

# Меню управления резервным копированием
backup_restore_menu() {
    clear
    echo "======================================================"
    print_color "blue" "     🛠️  Резервное копирование / Восстановление RagFlow 🛠️"
    echo "======================================================"
    echo ""
    echo "1. Создать резервную копию всех томов"
    echo "2. Просмотреть доступные резервные копии"
    echo "3. Восстановить из резервной копии"
    echo "4. Управление резервными копиями"
    echo "0. Вернуться в главное меню"
    echo ""
    read -p "Выберите действие: " choice
    
    case $choice in
        1)
            create_backup
            read -p "Нажмите Enter для продолжения..."
            ;;
        2)
            list_backups
            read -p "Нажмите Enter для продолжения..."
            ;;
        3)
            restore_backup
            read -p "Нажмите Enter для продолжения..."
            ;;
        4)
            manage_backups
            read -p "Нажмите Enter для продолжения..."
            ;;
        0)
            return
            ;;
        *)
            print_color "red" "❌ Некорректный выбор"
            read -p "Нажмите Enter для продолжения..."
            ;;
    esac
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
            backup_restore_menu
            ;;
        8)
            log_message "INFO" "Завершение работы скрипта"
            echo "Спасибо за использование скрипта установки XRM Director. До свидания!"
            exit 0
            ;;
        *)
            echo "Неверный выбор. Пожалуйста, выберите пункт меню от 1 до 8."
            sleep 2
            ;;
    esac
done
