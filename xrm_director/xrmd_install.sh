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
RAGFLOW_SLIM_IMAGE="infiniflow/ragflow:v0.19.1-slim"
RAGFLOW_FULL_IMAGE="infiniflow/ragflow:v0.19.1"
OLLAMA_LLM_MODEL="llama3.1:8b"
OLLAMA_LLM_MODEL_2="snowflake-arctic-embed:335m"

# Переменные для резервного копирования
BACKUP_DIR="/opt/xrm-director/backups"
PROJECT_NAME="ragflow"
DATE_FORMAT="$(date +%Y-%m-%d_%H-%M-%S)"

# ======= Настройки резервного копирования =======
INITIAL_BACKUP_URL="https://files.x-rm.ru/xrm_director/backup/initial_backup.tar.gz"
INITIAL_BACKUP_DIR="${BACKUP_DIR}/initial"
USER_BACKUP_DIR="${BACKUP_DIR}/user"
AUTO_RESTORE_INITIAL_BACKUP=1 # 0 - отключить, 1 - включить авторазвертывание initial backup

# ======= Переменные для командной строки =======
CLI_MODE=0
CLI_VERSION=""
CLI_PROCESSOR=""

# ======= Функции для работы с аргументами командной строки =======
show_help() {
    cat << EOF
XRM Director - Скрипт установки и управления
Версия: $VERSION

ИСПОЛЬЗОВАНИЕ:
    $0 [ОПЦИИ]
    $0 install <VERSION> <PROCESSOR>

ОПЦИИ:
    -h, --help          Показать эту справку
    -v, --version       Показать версию скрипта

КОМАНДЫ:
    install             Установить XRM Director
    
ПАРАМЕТРЫ УСТАНОВКИ:
    VERSION:
        slim            Облегченная версия (рекомендуется для CPU)
        full            Полная версия (требует больше ресурсов)
    
    PROCESSOR:
        cpu             Использовать CPU для обработки задач
        gpu             Использовать GPU для обработки задач (требует NVIDIA GPU)

ПРИМЕРЫ:
    $0                              # Запуск в интерактивном режиме (меню)
    $0 install slim cpu             # Установка облегченной версии с CPU
    $0 install full gpu             # Установка полной версии с GPU
    $0 install slim gpu             # Установка облегченной версии с GPU
    $0 install full cpu             # Установка полной версии с CPU

ОПИСАНИЕ:
    Без аргументов скрипт запускается в интерактивном режиме с меню.
    С аргументами выполняет автоматическую установку без взаимодействия с пользователем.
    
    Версии:
    - slim: Более быстрая установка, меньше места на диске, подходит для большинства задач
    - full: Расширенный функционал, больше возможностей, требует больше ресурсов
    
    Процессоры:
    - cpu: Универсальный вариант, работает на любой системе
    - gpu: Значительно быстрее для обработки больших объемов данных (требует NVIDIA GPU)

EOF
}

# Функция валидации аргументов
validate_cli_args() {
    local version="$1"
    local processor="$2"
    
    # Проверка версии
    if [[ "$version" != "slim" && "$version" != "full" ]]; then
        echo "❌ Ошибка: Неверная версия '$version'. Допустимые значения: slim, full"
        echo "Используйте '$0 --help' для получения справки."
        exit 1
    fi
    
    # Проверка процессора
    if [[ "$processor" != "cpu" && "$processor" != "gpu" ]]; then
        echo "❌ Ошибка: Неверный тип процессора '$processor'. Допустимые значения: cpu, gpu"
        echo "Используйте '$0 --help' для получения справки."
        exit 1
    fi
    
    # Дополнительная проверка для GPU
    if [[ "$processor" == "gpu" ]]; then
        if ! has_nvidia_gpu; then
            echo "❌ Ошибка: Выбран режим GPU, но NVIDIA GPU не обнаружена в системе"
            echo "Рекомендуется использовать: $0 install $version cpu"
            exit 1
        fi
    fi
    
    CLI_VERSION="$version"
    CLI_PROCESSOR="$processor"
    CLI_MODE=1
}

# Функция обработки аргументов командной строки
parse_cli_args() {
    while [[ $# -gt 0 ]]; do
        case $1 in
            -h|--help)
                show_help
                exit 0
                ;;
            -v|--version)
                echo "XRM Director Installer v$VERSION"
                exit 0
                ;;
            install)
                if [[ $# -lt 3 ]]; then
                    echo "❌ Ошибка: Недостаточно аргументов для команды 'install'"
                    echo "Использование: $0 install <version> <processor>"
                    echo "Используйте '$0 --help' для получения справки."
                    exit 1
                fi
                validate_cli_args "$2" "$3"
                return 0
                ;;
            *)
                echo "❌ Ошибка: Неизвестный аргумент '$1'"
                echo "Используйте '$0 --help' для получения справки."
                exit 1
                ;;
        esac
        shift
    done
}

# ======= Функции для диагностики и исправления проблем =======

# Функция для проверки логов контейнеров на наличие критических ошибок
check_container_logs_for_errors() {
    local container_name="$1"
    local error_patterns=()
    local found_errors=false
    
    echo "🔍 Проверка логов контейнера $container_name..."
    
    # Определяем паттерны ошибок для разных контейнеров
    case "$container_name" in
        "ragflow-mysql")
            error_patterns=(
                "Unable to open.*ib_redo.*error: 1504"
                "InnoDB.*Assertion failure"
                "mysqld got signal 6"
                "Failed to find the file"
                "Error.*encountered when writing to the redo log"
            )
            ;;
        "ragflow-minio")
            error_patterns=(
                "Storage resources are insufficient"
                "Insufficient number of drives online"
                "UUID.*do not match"
                "Write failed.*offline-disks"
                "inconsistent drive found"
            )
            ;;
        "ragflow-server")
            error_patterns=(
                "Failed to resolve.*es01"
                "Elasticsearch.*is unhealthy"
                "Connection error caused by.*NameResolutionError"
                "Exception.*Elasticsearch.*unhealthy"
            )
            ;;
        *)
            echo "⚠️ Неизвестный контейнер: $container_name"
            return 1
            ;;
    esac
    
    # Проверяем логи контейнера, если он существует
    if docker ps -a --format '{{.Names}}' | grep -q "^${container_name}$"; then
        local logs=$(docker logs "$container_name" --tail 100 2>&1)
        
        # Проверяем каждый паттерн ошибки
        for pattern in "${error_patterns[@]}"; do
            if echo "$logs" | grep -q "$pattern"; then
                echo "❌ Обнаружен паттерн ошибки в $container_name: $pattern"
                found_errors=true
            fi
        done
        
        if [ "$found_errors" = true ]; then
            echo "💥 Критические ошибки обнаружены в контейнере $container_name"
            return 0  # Ошибки найдены
        else
            echo "✅ Критических ошибок в $container_name не обнаружено"
            return 1  # Ошибок нет
        fi
    else
        echo "⚠️ Контейнер $container_name не найден"
        return 1
    fi
}

# Функция для комплексной проверки всех критических ошибок
check_and_fix_ragflow_errors() {
    echo "🔍 ====== КОМПЛЕКСНАЯ ПРОВЕРКА СИСТЕМЫ ======"
    echo "Проверка логов всех контейнеров на наличие критических ошибок..."
    
    local mysql_errors=false
    local minio_errors=false
    local server_errors=false
    local need_fix=false
    
    # Проверяем каждый контейнер
    if check_container_logs_for_errors "ragflow-mysql"; then
        mysql_errors=true
        need_fix=true
        echo "🚨 MySQL: Обнаружены проблемы с InnoDB redo-логами"
    fi
    
    if check_container_logs_for_errors "ragflow-minio"; then
        minio_errors=true
        need_fix=true
        echo "🚨 MinIO: Обнаружены проблемы с хранилищем"
    fi
    
    if check_container_logs_for_errors "ragflow-server"; then
        server_errors=true
        need_fix=true
        echo "🚨 RAGFlow Server: Обнаружены проблемы с движком документов"
    fi
    
    # Если ошибки найдены, запускаем автоматическое исправление
    if [ "$need_fix" = true ]; then
        echo ""
        echo "💡 ====== АВТОМАТИЧЕСКОЕ ИСПРАВЛЕНИЕ ОШИБОК ======"
        echo "Обнаружены критические ошибки в системе RAGFlow."
        echo "Запускаем автоматическое исправление..."
        echo ""
        
        # Создаем резервную копию перед исправлением
        local fix_backup_dir="/tmp/ragflow_autofix_backup_$(date +%Y%m%d_%H%M%S)"
        create_emergency_backup "$fix_backup_dir"
        
        # Исправляем ошибки в зависимости от типа
        if [ "$mysql_errors" = true ]; then
            fix_mysql_innodb_errors
        fi
        
        if [ "$minio_errors" = true ]; then
            fix_minio_storage_errors
        fi
        
        if [ "$server_errors" = true ]; then
            fix_ragflow_server_errors
        fi
        
        # Перезапускаем все контейнеры в правильном порядке
        restart_ragflow_containers_safely
        
        echo "✅ Автоматическое исправление завершено!"
        echo "📁 Резервная копия сохранена в: $fix_backup_dir"
        echo ""
        
        # Повторная проверка после исправления
        echo "🔍 Проверка системы после исправления..."
        sleep 30
        
        local final_check_passed=true
        if check_container_logs_for_errors "ragflow-mysql"; then
            echo "❌ MySQL: Проблемы остались после исправления"
            final_check_passed=false
        fi
        
        if check_container_logs_for_errors "ragflow-minio"; then
            echo "❌ MinIO: Проблемы остались после исправления"
            final_check_passed=false
        fi
        
        if check_container_logs_for_errors "ragflow-server"; then
            echo "❌ RAGFlow Server: Проблемы остались после исправления"
            final_check_passed=false
        fi
        
        if [ "$final_check_passed" = true ]; then
            echo "🎉 Все проблемы успешно исправлены!"
            return 0
        else
            echo "⚠️ Некоторые проблемы не удалось исправить автоматически"
            echo "Рекомендуется обратиться к администратору системы"
            return 1
        fi
    else
        echo "✅ Критических ошибок в системе не обнаружено"
        echo "Система RAGFlow работает корректно"
        return 0
    fi
}

# Функция для создания экстренной резервной копии
create_emergency_backup() {
    local backup_dir="$1"
    echo "📦 Создание экстренной резервной копии..."
    mkdir -p "$backup_dir"
    
    # Создание дампа MySQL если контейнер запущен
    if docker ps | grep -q ragflow-mysql; then
        echo "💾 Создание дампа базы данных MySQL..."
        docker exec ragflow-mysql mysqldump -uroot -pinfini_rag_flow --all-databases > "$backup_dir/mysql_backup.sql" 2>/dev/null || {
            echo "⚠️ Не удалось создать дамп базы данных"
        }
    fi
    
    # Резервная копия volumes
    echo "💾 Создание резервной копии volumes..."
    docker run --rm -v docker_mysql_data:/source -v "$backup_dir":/backup busybox tar czf /backup/mysql_data.tar.gz -C /source . 2>/dev/null || echo "⚠️ Не удалось создать резервную копию MySQL data"
    docker run --rm -v docker_minio_data:/source -v "$backup_dir":/backup busybox tar czf /backup/minio_data.tar.gz -C /source . 2>/dev/null || echo "⚠️ Не удалось создать резервную копию MinIO data"
    
    echo "✅ Экстренная резервная копия создана в: $backup_dir"
}

# Функция для исправления проблем MySQL InnoDB
fix_mysql_innodb_errors() {
    echo "🔧 Исправление проблем MySQL InnoDB..."
    
    # Останавливаем MySQL контейнер
    echo "⏹️ Остановка MySQL контейнера..."
    docker stop ragflow-mysql 2>/dev/null || true
    
    # Удаляем поврежденный volume
    echo "🗑️ Удаление поврежденного MySQL volume..."
    docker volume rm docker_mysql_data 2>/dev/null || true
    
    # Создаем новый volume
    echo "📦 Создание нового MySQL volume..."
    docker volume create docker_mysql_data
    
    echo "✅ MySQL InnoDB проблемы исправлены"
}

# Функция для исправления проблем MinIO storage
fix_minio_storage_errors() {
    echo "🔧 Исправление проблем MinIO storage..."
    
    # Останавливаем MinIO контейнер
    echo "⏹️ Остановка MinIO контейнера..."
    docker stop ragflow-minio 2>/dev/null || true
    
    # Удаляем поврежденный volume
    echo "🗑️ Удаление поврежденного MinIO volume..."
    docker volume rm docker_minio_data 2>/dev/null || true
    
    # Создаем новый volume
    echo "📦 Создание нового MinIO volume..."
    docker volume create docker_minio_data
    
    echo "✅ MinIO storage проблемы исправлены"
}

# Функция для исправления проблем RAGFlow Server
fix_ragflow_server_errors() {
    echo "🔧 Исправление проблем RAGFlow Server..."
    
    cd "$DOCKER_DIR" || return 1
    
    # Настройка движка документов
    echo "⚙️ Настройка движка документов..."
    
    # Проверяем доступное дисковое пространство для выбора движка
    local available_space=$(df / | awk 'NR==2 {print $4}')
    local required_space_es=20971520  # 20GB для Elasticsearch
    
    if [ "$available_space" -lt "$required_space_es" ]; then
        echo "⚠️ Недостаточно места для Elasticsearch, переключаемся на Infinity"
        export DOC_ENGINE=infinity
        export COMPOSE_PROFILES=infinity
    else
        echo "🔍 Используем Elasticsearch в качестве движка документов"
        export DOC_ENGINE=elasticsearch
        export COMPOSE_PROFILES=elasticsearch
    fi
    
    # Обновляем .env файл
    if grep -q "^DOC_ENGINE=" .env; then
        sed -i "s/^DOC_ENGINE=.*/DOC_ENGINE=$DOC_ENGINE/" .env
    else
        echo "DOC_ENGINE=$DOC_ENGINE" >> .env
    fi
    
    if grep -q "^COMPOSE_PROFILES=" .env; then
        sed -i "s/^COMPOSE_PROFILES=.*/COMPOSE_PROFILES=$DOC_ENGINE/" .env
    else
        echo "COMPOSE_PROFILES=$DOC_ENGINE" >> .env
    fi
    
    echo "✅ RAGFlow Server проблемы исправлены"
}

# Функция для безопасного перезапуска контейнеров RAGFlow
restart_ragflow_containers_safely() {
    echo "🔄 Безопасный перезапуск контейнеров RAGFlow..."
    
    cd "$DOCKER_DIR" || return 1
    
    # Полная остановка всех контейнеров
    echo "⏹️ Остановка всех контейнеров..."
    docker-compose down 2>/dev/null || true
    
    # Ждем полной остановки
    sleep 10
    
    # Запускаем контейнеры в правильном порядке
    echo "▶️ Запуск MySQL..."
    docker-compose up -d mysql
    
    # Ждем готовности MySQL
    echo "⏳ Ожидание готовности MySQL..."
    local timeout=60
    while [ $timeout -gt 0 ]; do
        if docker exec ragflow-mysql mysqladmin ping -uroot -pinfini_rag_flow --silent 2>/dev/null; then
            break
        fi
        sleep 2
        timeout=$((timeout-2))
    done
    
    if [ $timeout -le 0 ]; then
        echo "❌ MySQL не запустился в течение 60 секунд"
        return 1
    fi
    echo "✅ MySQL готов"
    
    # Запуск остальных сервисов
    echo "▶️ Запуск MinIO..."
    docker-compose up -d minio
    sleep 10
    
    echo "▶️ Запуск Redis..."
    docker-compose up -d redis
    sleep 5
    
    # Запуск движка документов
    if [ "$DOC_ENGINE" = "elasticsearch" ]; then
        echo "▶️ Запуск Elasticsearch..."
        docker-compose up -d es01
        
        echo "⏳ Ожидание готовности Elasticsearch..."
        timeout=120
        while [ $timeout -gt 0 ]; do
            if curl -s http://localhost:1200 >/dev/null 2>&1; then
                break
            fi
            sleep 5
            timeout=$((timeout-5))
        done
        
        if [ $timeout -le 0 ]; then
            echo "⚠️ Elasticsearch не отвечает, переключаемся на Infinity..."
            export DOC_ENGINE=infinity
            export COMPOSE_PROFILES=infinity
            sed -i "s/^DOC_ENGINE=.*/DOC_ENGINE=infinity/" .env
            sed -i "s/^COMPOSE_PROFILES=.*/COMPOSE_PROFILES=infinity/" .env
            docker-compose up -d infinity
        else
            echo "✅ Elasticsearch готов"
        fi
    elif [ "$DOC_ENGINE" = "infinity" ]; then
        echo "▶️ Запуск Infinity..."
        docker-compose up -d infinity
        sleep 10
    fi
    
    # Запуск основного приложения
    echo "▶️ Запуск RAGFlow server..."
    docker-compose up -d ragflow
    
    echo "✅ Все контейнеры перезапущены"
}

# ======= Универсальная функция подтверждения =======
# Поддерживает русские (д/н) и английские (y/n) варианты ответов
confirm_action() {
    local prompt="$1"
    local default_value="${2:-n}"  # По умолчанию "n" (нет)
    local response
    
    while true; do
        if [[ "$default_value" == "y" ]]; then
            read -p "$prompt (д/y - да, н/n - нет) [Д/Y]: " response
        else
            read -p "$prompt (д/y - да, н/n - нет) [Н/N]: " response
        fi
        
        # Если ответ пустой, используем значение по умолчанию
        if [[ -z "$response" ]]; then
            response="$default_value"
        fi
        
        # Преобразуем ответ в нижний регистр для упрощения проверки
        response=$(echo "$response" | tr '[:upper:]' '[:lower:]')
        
        # Проверяем ответ (принимаем только д/y для да и н/n для нет)
        case "$response" in
            д|y)
                return 0  # Подтверждение
                ;;
            н|n)
                return 1  # Отказ
                ;;
            *)
                echo "Пожалуйста, введите 'д' или 'y' для подтверждения, 'н' или 'n' для отказа"
                ;;
        esac
    done
}

# Функция установки XRM Director через CLI
install_xrm_director_cli() {
    log_message "INFO" "Начало установки XRM Director (CLI режим)"
    
    # Проверяем, установлен ли уже XRM Director
    if docker ps -a | grep -q "ragflow"; then
        log_message "WARNING" "Обнаружена существующая установка XRM Director"
        echo "ВНИМАНИЕ: XRM Director уже установлен. Обнаружены контейнеры ragflow."
        echo "Переустанавливаем XRM Director..."
    fi

    # Устанавливаем переменные на основе выбранных параметров
    local selected_version="v0.19.1"
    local edition_type="$CLI_VERSION"
    local ragflow_image
    
    if [[ "$CLI_VERSION" == "slim" ]]; then
        ragflow_image="$RAGFLOW_SLIM_IMAGE"
        echo "Выбрана облегченная версия v0.19.1-slim"
    else
        ragflow_image="$RAGFLOW_FULL_IMAGE"
        echo "Выбрана полная версия v0.19.1"
    fi

    log_message "INFO" "Выбрана версия: $selected_version ($edition_type)"

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
            echo "Проверка целостности загруженного файла..."
            if ! tar -tzf "${INITIAL_BACKUP_DIR}/initial_backup.tar.gz" &>/dev/null; then
                log_message "ERROR" "Целостность загруженного initial backup не удалась"
                echo "Ошибка: Целостность загруженного initial backup не удалась"
                return 1
            fi
        fi
    else
        log_message "INFO" "Initial backup успешно загружен"
        echo "Initial backup загружен в ${INITIAL_BACKUP_DIR}"
        echo "Проверка целостности загруженного файла..."
        if ! tar -tzf "${INITIAL_BACKUP_DIR}/initial_backup.tar.gz" &>/dev/null; then
            log_message "ERROR" "Целостность загруженного initial backup не удалась"
            echo "Ошибка: Целостность загруженного initial backup не удалась"
            return 1
        fi
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
    echo "Настройка vm.max_map_count..."
    
    if [ "$current_map_count" -lt "$MAX_MAP_COUNT" ]; then
        log_message "INFO" "Установка vm.max_map_count в $MAX_MAP_COUNT"
        
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

    # Обновляем версию в .env файле
    if ! update_env_version ".env" "$selected_version" "$edition_type"; then
        log_message "ERROR" "Не удалось обновить версию в .env файле"
        echo "Ошибка: Не удалось обновить версию в .env файле"
        return 1
    fi
    
    # Запуск контейнеров в зависимости от выбранного процессора
    if [[ "$CLI_PROCESSOR" == "gpu" ]]; then
        log_message "INFO" "Установка XRM Director с GPU"
        echo "Установка XRM Director с GPU..."
        
        if ! docker compose -f docker-compose-gpu.yml up -d; then
            log_message "ERROR" "Не удалось запустить XRM Director с GPU"
            echo "Ошибка: Не удалось запустить XRM Director с GPU"
            return 1
        fi
    else
        log_message "INFO" "Установка XRM Director с CPU"
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
    
    # Проверка состояния ragflow-server
    echo "Проверка состояния ragflow-server..."
    local container_status=$(docker inspect --format '{{.State.Status}}' ragflow-server 2>/dev/null)
    if [ "$container_status" = "running" ]; then
        echo "✅ Сервер ragflow-server запущен и работает (статус: $container_status)"
        echo "ℹ️  Ожидание полной инициализации пропущено - контейнер уже в рабочем состоянии"
    else
        echo "⚠️  Сервер ragflow-server в состоянии: $container_status"
        echo "Проверьте логи контейнера: docker logs ragflow-server"
    fi
    
    # ОТКЛЮЧЕННОЕ ОЖИДАНИЕ: Ранее здесь было ожидание сообщения "Running on all addresses" в логах (макс. 180 сек)
    # Это ожидание отключено, так как:
    # - Поиск по логам не всегда срабатывает корректно
    # - Если контейнер имеет статус "running", значит сервис уже функционирует
    # - Полная инициализация может происходить в фоновом режиме без влияния на работоспособность
    #
    # Закомментированный код ожидания:
    # echo "Ожидание запуска сервера (это может занять некоторое время)..."
    # local server_started=false
    # for i in {1..72}; do
    #     if docker logs ragflow-server 2>&1 | grep "Running on all addresses"; then
    #         echo -e "\nСервер ragflow-server успешно запущен!"
    #         server_started=true
    #         break
    #     fi
    #     echo -n "."
    #     sleep 5
    # done
    # 
    # if [ "$server_started" = false ]; then
    #     echo -e "\nПревышено время ожидания запуска сервера (180 секунд)."
    #     echo "Проверьте логи контейнера: docker logs -f ragflow-server"
    #     echo "Система может работать некорректно до полного запуска сервера."
    # fi
    
    # Установка Ollama
    echo "Установка Ollama..."
    
    # Проверяем и удаляем существующий контейнер Ollama
    if docker ps -a --format '{{.Names}}' | grep -q "^ollama$"; then
        echo "Найден существующий контейнер Ollama, удаляем..."
        docker stop ollama 2>/dev/null || true
        docker rm ollama 2>/dev/null || true
    fi
    
    # Запуск контейнера Ollama
    if ! docker run -d --name ollama -e OLLAMA_DEBUG=1 -p 11434:11434 ollama/ollama; then
        log_message "ERROR" "Не удалось запустить контейнер Ollama"
        echo "❌ Ошибка: Не удалось запустить контейнер Ollama"
        echo "Установка будет продолжена без Ollama..."
        log_message "WARNING" "Установка продолжена без Ollama"
    else
        log_message "INFO" "Контейнер Ollama успешно запущен"
        echo "✅ Контейнер Ollama успешно запущен"
        
        # Установка моделей в Ollama
        echo "Установка моделей в Ollama..."
        sleep 5
        
        # Установка первой модели (LLM)
        echo "Установка модели $OLLAMA_LLM_MODEL в Ollama..."
        if ! docker exec ollama ollama run $OLLAMA_LLM_MODEL; then
            log_message "ERROR" "Не удалось установить модель $OLLAMA_LLM_MODEL в Ollama"
            echo "Ошибка: Не удалось установить модель $OLLAMA_LLM_MODEL в Ollama"
        else
            log_message "INFO" "Модель $OLLAMA_LLM_MODEL успешно установлена в Ollama"
            echo "Модель $OLLAMA_LLM_MODEL успешно установлена в Ollama"
        fi
        
        # Установка второй модели (embedding)
        echo "Установка модели $OLLAMA_LLM_MODEL_2 (embedding) в Ollama..."
        if ! docker exec ollama ollama pull $OLLAMA_LLM_MODEL_2; then
            log_message "ERROR" "Не удалось установить модель $OLLAMA_LLM_MODEL_2 в Ollama"
            echo "Ошибка: Не удалось установить модель $OLLAMA_LLM_MODEL_2 в Ollama"
        else
            log_message "INFO" "Модель $OLLAMA_LLM_MODEL_2 успешно установлена в Ollama"
            echo "Модель $OLLAMA_LLM_MODEL_2 успешно установлена в Ollama"
        fi
    fi
    
    # Определение IP-адреса сервера
    local server_ip=$(hostname -I | awk '{print $1}')
    
    log_message "INFO" "XRM Director успешно установлен"
    echo "✅ XRM Director успешно установлен!"
    echo "🌐 Доступ к веб-интерфейсу: http://$server_ip"
    echo "📁 Установочная директория: $INSTALL_DIR/"
    echo "📋 Логи: $LOG_FILE"
    
    # Запускаем комплексную проверку и исправление возможных проблем
    echo ""
    echo "🔍 Выполняем проверку системы..."
    check_and_fix_ragflow_errors
    
    return 0
}

# Функция автоматической установки через CLI
cli_install() {
    echo "🚀 Автоматическая установка XRM Director"
    echo "📦 Версия: $CLI_VERSION"
    echo "⚙️  Процессор: $CLI_PROCESSOR"
    echo ""
    
    log_message "INFO" "Начало автоматической установки: версия=$CLI_VERSION, процессор=$CLI_PROCESSOR"
    
    # Проверка системных требований
    echo "🔍 Проверка системных требований..."
    if ! check_system_requirements_silent; then
        echo "❌ Системные требования не выполнены. Установка прервана."
        exit 1
    fi
    
    # Проверка Docker
    echo "🐳 Проверка Docker..."
    if ! check_docker_installed_silent; then
        echo "📦 Docker не установлен. Устанавливаем Docker..."
        if ! install_docker; then
            echo "❌ Ошибка установки Docker. Установка прервана."
            exit 1
        fi
    fi
    
    # Установка XRM Director
    echo "🎯 Установка XRM Director..."
    if ! install_xrm_director_cli; then
        echo "❌ Ошибка установки XRM Director"
        exit 1
    fi
    
    # Запускаем комплексную проверку и исправление возможных проблем
    echo ""
    echo "🔍 Выполняем финальную проверку системы..."
    check_and_fix_ragflow_errors
}

# Функция для установки XRM Director
install_xrm_director() {
    log_message "INFO" "Установка XRM Director..."

    echo "====== Установка XRM Director ======"

    # Проверяем, установлен ли уже XRM Director
    if docker ps -a | grep -q "ragflow"; then
        log_message "WARNING" "Обнаружена существующая установка XRM Director"
        echo "ВНИМАНИЕ: XRM Director уже установлен. Обнаружены контейнеры ragflow."
        if ! confirm_action "Хотите продолжить и переустановить XRM Director?"; then
            echo "Установка отменена пользователем."
            return 0
        fi
        echo "Продолжаем установку..."
    fi

    # Выбор редакции RAGFlow v0.19.1
    echo "Выбор редакции RAGFlow v0.19.1:"
    echo "0. Вернуться в главное меню"
    echo "1. Slim - облегченная версия (~2.62 GB, без встроенных моделей)"
    echo "2. Full - полная версия (~7.12 GB, со встроенными моделями)"
    echo ""
    read -p "Введите номер редакции (0-2): " edition_choice

    local selected_version="v0.19.1"
    local edition_type
    local ragflow_image

    case "$edition_choice" in
        0)
            echo "Возврат в главное меню..."
            return 0
            ;;
        1)
            edition_type="slim"
            ragflow_image="$RAGFLOW_SLIM_IMAGE"
            echo "Выбрана облегченная версия v0.19.1-slim"
            ;;
        2)
            edition_type="full"
            ragflow_image="$RAGFLOW_FULL_IMAGE"
            echo "Выбрана полная версия v0.19.1"
            ;;
        *)
            echo "Неверный выбор. Устанавливается полная версия по умолчанию."
            edition_type="full"
            ragflow_image="$RAGFLOW_FULL_IMAGE"
            ;;
    esac

    log_message "INFO" "Выбрана версия: $selected_version ($edition_type)"
    echo "Выбрана версия: $selected_version ($edition_type)"

    # Выбор процессора (CPU/GPU)
    echo ""
    echo "Выбор процессора для обработки:"
    echo "0. Вернуться в главное меню"
    echo "1. CPU - универсальный вариант (работает на любой системе)"
    echo "2. GPU - ускоренная обработка (требует NVIDIA GPU)"
    echo ""
    read -p "Введите номер процессора (0-2): " processor_choice

    local processor_type
    local use_gpu=false

    case "$processor_choice" in
        0)
            echo "Возврат в главное меню..."
            return 0
            ;;
        1)
            processor_type="cpu"
            use_gpu=false
            echo "Выбран CPU для обработки"
            ;;
        2)
            processor_type="gpu"
            use_gpu=true
            echo "Выбран GPU для обработки"
            
            # Проверка наличия NVIDIA GPU
            if ! has_nvidia_gpu; then
                echo "⚠️  ВНИМАНИЕ: NVIDIA GPU не обнаружена в системе!"
                echo "Рекомендуется использовать CPU вместо GPU."
                if ! confirm_action "Хотите продолжить с GPU несмотря на предупреждение?"; then
                    echo "Возврат к выбору процессора..."
                    processor_type="cpu"
                    use_gpu=false
                    echo "Переключено на CPU для обработки"
                fi
            fi
            ;;
        *)
            echo "Неверный выбор. Используется CPU по умолчанию."
            processor_type="cpu"
            use_gpu=false
            ;;
    esac

    log_message "INFO" "Выбран процессор: $processor_type"
    echo "Выбран процессор: $processor_type"

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
            echo "Проверка целостности загруженного файла..."
            if ! tar -tzf "${INITIAL_BACKUP_DIR}/initial_backup.tar.gz" &>/dev/null; then
                log_message "ERROR" "Целостность загруженного initial backup не удалась"
                echo "Ошибка: Целостность загруженного initial backup не удалась"
                return 1
            fi
        fi
    else
        log_message "INFO" "Initial backup успешно загружен"
        echo "Initial backup загружен в ${INITIAL_BACKUP_DIR}"
        echo "Проверка целостности загруженного файла..."
        if ! tar -tzf "${INITIAL_BACKUP_DIR}/initial_backup.tar.gz" &>/dev/null; then
            log_message "ERROR" "Целостность загруженного initial backup не удалась"
            echo "Ошибка: Целостность загруженного initial backup не удалась"
            return 1
        fi
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
    echo "Настройка vm.max_map_count..."
    
    if [ "$current_map_count" -lt "$MAX_MAP_COUNT" ]; then
        log_message "INFO" "Установка vm.max_map_count в $MAX_MAP_COUNT"
        
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

    # Обновляем версию в .env файле
    if ! update_env_version ".env" "$selected_version" "$edition_type"; then
        log_message "ERROR" "Не удалось обновить версию в .env файле"
        echo "Ошибка: Не удалось обновить версию в .env файле"
        return 1
    fi
    
    # Запуск контейнеров в зависимости от выбранного процессора
    if [[ "$use_gpu" == "true" ]]; then
        log_message "INFO" "Установка XRM Director с GPU"
        echo "Установка XRM Director с GPU..."
        
        if ! docker compose -f docker-compose-gpu.yml up -d; then
            log_message "ERROR" "Не удалось запустить XRM Director с GPU"
            echo "Ошибка: Не удалось запустить XRM Director с GPU"
            return 1
        fi
    else
        log_message "INFO" "Установка XRM Director с CPU"
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
    
    # Проверка состояния ragflow-server
    echo "Проверка состояния ragflow-server..."
    local container_status=$(docker inspect --format '{{.State.Status}}' ragflow-server 2>/dev/null)
    if [ "$container_status" = "running" ]; then
        echo "✅ Сервер ragflow-server запущен и работает (статус: $container_status)"
        echo "ℹ️  Ожидание полной инициализации пропущено - контейнер уже в рабочем состоянии"
    else
        echo "⚠️  Сервер ragflow-server в состоянии: $container_status"
        echo "Проверьте логи контейнера: docker logs ragflow-server"
    fi
    
    # ОТКЛЮЧЕННОЕ ОЖИДАНИЕ: Ранее здесь было ожидание сообщения "Running on all addresses" в логах (макс. 180 сек)
    # Это ожидание отключено, так как:
    # - Поиск по логам не всегда срабатывает корректно
    # - Если контейнер имеет статус "running", значит сервис уже функционирует
    # - Полная инициализация может происходить в фоновом режиме без влияния на работоспособность
    #
    # Закомментированный код ожидания:
    # echo "Ожидание запуска сервера (это может занять некоторое время)..."
    # local server_started=false
    # for i in {1..72}; do
    #     if docker logs ragflow-server 2>&1 | grep "Running on all addresses"; then
    #         echo -e "\nСервер ragflow-server успешно запущен!"
    #         server_started=true
    #         break
    #     fi
    #     echo -n "."
    #     sleep 5
    # done
    # 
    # if [ "$server_started" = false ]; then
    #     echo -e "\nПревышено время ожидания запуска сервера (180 секунд)."
    #     echo "Проверьте логи контейнера: docker logs -f ragflow-server"
    #     echo "Система может работать некорректно до полного запуска сервера."
    # fi
    
    # Установка Ollama
    echo "Установка Ollama..."
    
    # Проверяем и удаляем существующий контейнер Ollama
    if docker ps -a --format '{{.Names}}' | grep -q "^ollama$"; then
        echo "Найден существующий контейнер Ollama, удаляем..."
        docker stop ollama 2>/dev/null || true
        docker rm ollama 2>/dev/null || true
    fi
    
    # Запуск контейнера Ollama
    if ! docker run -d --name ollama -e OLLAMA_DEBUG=1 -p 11434:11434 ollama/ollama; then
        log_message "ERROR" "Не удалось запустить контейнер Ollama"
        echo "❌ Ошибка: Не удалось запустить контейнер Ollama"
        echo "Установка будет продолжена без Ollama..."
        log_message "WARNING" "Установка продолжена без Ollama"
    else
        log_message "INFO" "Контейнер Ollama успешно запущен"
        echo "✅ Контейнер Ollama успешно запущен"
        
        # Установка моделей в Ollama
        echo "Установка моделей в Ollama..."
        sleep 5
        
        # Установка первой модели (LLM)
        echo "Установка модели $OLLAMA_LLM_MODEL в Ollama..."
        if ! docker exec ollama ollama run $OLLAMA_LLM_MODEL; then
            log_message "ERROR" "Не удалось установить модель $OLLAMA_LLM_MODEL в Ollama"
            echo "Ошибка: Не удалось установить модель $OLLAMA_LLM_MODEL в Ollama"
        else
            log_message "INFO" "Модель $OLLAMA_LLM_MODEL успешно установлена в Ollama"
            echo "Модель $OLLAMA_LLM_MODEL успешно установлена в Ollama"
        fi
        
        # Установка второй модели (embedding)
        echo "Установка модели $OLLAMA_LLM_MODEL_2 (embedding) в Ollama..."
        if ! docker exec ollama ollama pull $OLLAMA_LLM_MODEL_2; then
            log_message "ERROR" "Не удалось установить модель $OLLAMA_LLM_MODEL_2 в Ollama"
            echo "Ошибка: Не удалось установить модель $OLLAMA_LLM_MODEL_2 в Ollama"
        else
            log_message "INFO" "Модель $OLLAMA_LLM_MODEL_2 успешно установлена в Ollama"
            echo "Модель $OLLAMA_LLM_MODEL_2 успешно установлена в Ollama"
        fi
    fi
    
    # Определение IP-адреса сервера
    local server_ip=$(hostname -I | awk '{print $1}')
    
    log_message "INFO" "XRM Director успешно установлен"
    echo "✅ XRM Director успешно установлен!"
    echo "🌐 Доступ к веб-интерфейсу: http://$server_ip"
    echo "📁 Установочная директория: $INSTALL_DIR/"
    echo "📋 Логи: $LOG_FILE"
    
    # Запускаем комплексную проверку и исправление возможных проблем
    echo ""
    echo "🔍 Выполняем проверку системы..."
    check_and_fix_ragflow_errors
    
    # Дополнительная пауза, чтобы пользователь мог прочитать результат установки
    echo ""
    read -p "Нажмите Enter для продолжения..." -r
}

# Функция для перезапуска XRM Director
restart_xrm_director() {
    log_message "INFO" "Перезапуск XRM Director..."

    echo "====== Перезапуск XRM Director ======"

    # Проверка наличия установки
    if [ ! -f "$DOCKER_COMPOSE_YML" ]; then
        log_message "WARNING" "Файл конфигурации $DOCKER_COMPOSE_YML не найден. XRM Director, возможно, не установлен"
        echo "XRM Director не установлен. Сначала выполните установку (пункт 4)."
        show_return_to_menu_message
        return 1
    fi

    # Проверка наличия контейнеров
    local ragflow_containers=$(docker ps -a --format '{{.Names}}' | grep "ragflow" || true)
    local ollama_container=$(docker ps -a --format '{{.Names}}' | grep "ollama" || true)

    if [[ -z "$ragflow_containers" && -z "$ollama_container" ]]; then
        log_message "WARNING" "Контейнеры XRM Director не найдены"
        echo "Контейнеры XRM Director не найдены. Возможные причины:"
        echo "  1. XRM Director не был запущен после установки"
        echo "  2. Контейнеры были удалены вручную"

        # Проверяем наличие образов Docker
        if docker images | grep -q -E 'infiniflow/ragflow|ollama/ollama'; then
            echo "Найдены образы Docker для XRM Director. Запускаем контейнеры..."

            cd "$DOCKER_DIR" || {
                echo "Ошибка: Не удалось перейти в директорию $DOCKER_DIR"
                show_return_to_menu_message
                return 1
            }

            # Проверяем наличие GPU
            if [ -f "$DOCKER_COMPOSE_GPU_YML" ] && has_nvidia_gpu; then
                echo "Запуск XRM Director с поддержкой GPU..."
                docker compose -f docker-compose-gpu.yml up -d
            else
                echo "Запуск XRM Director без GPU..."
                docker compose -f docker-compose.yml up -d
            fi

            sleep 5
            echo "Контейнеры запущены."
        else
            echo "Рекомендуется выполнить полную переустановку XRM Director (пункт 4)."
            show_return_to_menu_message
            return 1
        fi
    else
        echo "Найдены контейнеры XRM Director:"
        if [[ -n "$ragflow_containers" ]]; then
            echo "RAGFlow контейнеры: $ragflow_containers"
        fi
        if [[ -n "$ollama_container" ]]; then
            echo "Ollama контейнер: $ollama_container"
        fi
    fi

    # Перезапуск контейнеров ragflow
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
    if [ -n "$ollama_container" ]; then
        echo "Перезапуск контейнера Ollama..."
        if ! docker restart "$ollama_container"; then
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
    
    # Проверяем состояние системы после перезапуска
    check_and_fix_ragflow_errors
    
    show_return_to_menu_message
}

# Функция для удаления XRM Director
remove_xrm_director() {
    log_message "INFO" "Удаление XRM Director..."
    
    echo "====== Удаление XRM Director ======"
    
    # Проверяем наличие контейнеров ragflow и ollama
    local ragflow_containers=$(docker ps -a --format '{{.Names}}' | grep "ragflow" || true)
    local ollama_containers=$(docker ps -a --format '{{.Names}}' | grep "ollama" || true)
    
    if [[ -z "$ragflow_containers" && -z "$ollama_containers" ]]; then
        log_message "WARNING" "Контейнеры XRM Director не найдены"
        echo "Контейнеры XRM Director не найдены."
        
        # Проверяем наличие образов для удаления
        local ragflow_images=$(docker images --format '{{.Repository}}:{{.Tag}}' | grep "infiniflow/ragflow" || true)
        local ollama_images=$(docker images --format '{{.Repository}}:{{.Tag}}' | grep "ollama/ollama" || true)
        
        if [[ -n "$ragflow_images" || -n "$ollama_images" ]]; then
            echo "Найдены образы XRM Director для удаления:"
            if [[ -n "$ragflow_images" ]]; then
                echo "RAGFlow образы:"
                echo "$ragflow_images"
            fi
            if [[ -n "$ollama_images" ]]; then
                echo "Ollama образы:"
                echo "$ollama_images"
            fi
            
            echo "Хотите удалить найденные образы? (д/н)"
            read -r remove_images
            if [[ "$remove_images" =~ ^[yдYД]$ ]]; then
                # Удаление образов RAGFlow
                if [[ -n "$ragflow_images" ]]; then
                    echo "$ragflow_images" | while read -r image; do
                        echo "Удаление образа: $image"
                        if docker rmi -f "$image" 2>/dev/null; then
                            echo "✅ Образ $image успешно удален"
                        else
                            echo "❌ Не удалось удалить образ $image"
                        fi
                    done
                fi
                
                # Удаление образов Ollama
                if [[ -n "$ollama_images" ]]; then
                    echo "$ollama_images" | while read -r image; do
                        echo "Удаление образа: $image"
                        if docker rmi -f "$image" 2>/dev/null; then
                            echo "✅ Образ $image успешно удален"
                        else
                            echo "❌ Не удалось удалить образ $image"
                        fi
                    done
                fi
                
                echo "Образы XRM Director удалены"
            fi
        fi
        
        # Переход к опциональному удалению директорий (в конце функции)
    fi
    
    # Опциональное удаление директорий (выполняется всегда)
    echo ""
    echo "Опциональное удаление директорий:"
    echo "  - \`$INSTALL_DIR\` удалить всю директорию"
    echo "  - \`$BACKUP_DIR\` (резервные копии)"
    echo ""
    
    # Проверка и удаление основной директории установки
    if [ -d "$INSTALL_DIR" ]; then
        echo "📁 Найдена директория установки: $INSTALL_DIR"
        echo "Хотите удалить директорию установки? (д/y - да, н/n - нет)"
        read -r remove_install_dir
        remove_install_dir=$(echo "$remove_install_dir" | tr '[:upper:]' '[:lower:]')
        if [[ "$remove_install_dir" =~ ^[yд]$ ]]; then
            rm -rf "$INSTALL_DIR"
            log_message "INFO" "Директория установки $INSTALL_DIR удалена"
            echo "✅ Директория установки $INSTALL_DIR удалена"
        else
            echo "ℹ️  Директория установки сохранена"
        fi
    else
        echo "ℹ️  Директория установки $INSTALL_DIR не найдена"
    fi
    
    # Проверка и удаление директории с резервными копиями
    if [ -d "$BACKUP_DIR" ]; then
        echo "📁 Найдена директория резервных копий: $BACKUP_DIR"
        echo "Хотите удалить директорию с резервными копиями? (д/y - да, н/n - нет)"
        read -r remove_backup_dir
        remove_backup_dir=$(echo "$remove_backup_dir" | tr '[:upper:]' '[:lower:]')
        if [[ "$remove_backup_dir" =~ ^[yд]$ ]]; then
            rm -rf "$BACKUP_DIR"
            log_message "INFO" "Директория резервных копий $BACKUP_DIR удалена"
            echo "✅ Директория резервных копий $BACKUP_DIR удалена"
        else
            echo "ℹ️  Директория резервных копий сохранена"
        fi
    else
        echo "ℹ️  Директория резервных копий $BACKUP_DIR не найдена"
    fi

    # Если контейнеры не найдены, завершаем здесь
    if [[ -z "$ragflow_containers" && -z "$ollama_containers" ]]; then
        show_return_to_menu_message
        return 0
    fi
    
    # Запрос подтверждения на удаление
    echo "ВНИМАНИЕ! Это действие удалит все контейнеры XRM Director, тома, образы и файлы."
    echo "Найденные компоненты:"
    if [[ -n "$ragflow_containers" ]]; then
        echo "- Контейнеры RAGFlow: $ragflow_containers"
    fi
    if [[ -n "$ollama_containers" ]]; then
        echo "- Контейнер Ollama: $ollama_containers"
    fi
    echo "Хотите продолжить удаление? (д/y - да, н/n - нет)"
    read -r confirm
    confirm=$(echo "$confirm" | tr '[:upper:]' '[:lower:]')
    
    if [[ ! "$confirm" =~ ^[yд]$ ]]; then
        echo "Удаление отменено пользователем."
        return 0
    fi
    
    # Получение списка контейнеров с ragflow в имени
    local containers=$(docker ps -a --format '{{.Names}}' | grep "ragflow" || true)
    
    # Сбор информации о томах, подключенных к контейнерам с ragflow
    local volumes_to_remove=()
    
    if [[ -n "$containers" ]]; then
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
    fi
    
    # Остановка и удаление контейнера Ollama, если он существует
    if docker ps -a --format '{{.Names}}' | grep -q "ollama"; then
        echo "Остановка и удаление контейнера Ollama..."
        docker stop ollama 2>/dev/null
        docker rm ollama  2>/dev/null
    fi
    
    # Удаление томов
    if [ ${#volumes_to_remove[@]} -gt 0 ]; then
        echo "Удаление томов, связанных с XRM Director..."
        for vol in "${volumes_to_remove[@]}"; do
            echo "Удаление тома: $vol"
            docker volume rm "$vol" 2>/dev/null
        done
    fi
    
    # Удаление Docker образов
    echo "Поиск и удаление Docker образов..."
    
    # Удаление образов RAGFlow
    local ragflow_images=$(docker images --format '{{.Repository}}:{{.Tag}}' | grep "infiniflow/ragflow")
    if [ -n "$ragflow_images" ]; then
        echo "Найдены образы RAGFlow для удаления:"
        echo "$ragflow_images"
        echo "$ragflow_images" | while read -r image; do
            echo "Удаление образа: $image"
            if docker rmi -f "$image" 2>/dev/null; then
                echo "✅ Образ $image успешно удален"
            else
                echo "❌ Не удалось удалить образ $image"
            fi
        done
        log_message "INFO" "Образы RAGFlow обработаны"
    else
        echo "Образы RAGFlow не найдены"
    fi
    
    # Удаление образов Ollama
    local ollama_images=$(docker images --format '{{.Repository}}:{{.Tag}}' | grep "ollama/ollama")
    if [ -n "$ollama_images" ]; then
        echo "Найдены образы Ollama для удаления:"
        echo "$ollama_images"
        echo "$ollama_images" | while read -r image; do
            echo "Удаление образа: $image"
            if docker rmi -f "$image" 2>/dev/null; then
                echo "✅ Образ $image успешно удален"
            else
                echo "❌ Не удалось удалить образ $image"
            fi
        done
        log_message "INFO" "Образы Ollama обработаны"
    else
        echo "Образы Ollama не найдены"
    fi
    
    # Удаление неиспользуемых образов (опционально)
    echo "Хотите удалить все неиспользуемые Docker образы? (д/y - да, н/n - нет)"
    read -r cleanup_images
    cleanup_images=$(echo "$cleanup_images" | tr '[:upper:]' '[:lower:]')
    if [[ "$cleanup_images" =~ ^[yд]$ ]]; then
        echo "Очистка неиспользуемых образов..."
        docker image prune -a -f
        log_message "INFO" "Неиспользуемые образы очищены"
        echo "Неиспользуемые образы очищены"
    fi
    
    log_message "INFO" "XRM Director успешно удален"
    echo ""
    echo "✅ XRM Director и все связанные с ним компоненты успешно удалены!"
    show_return_to_menu_message
}

# Функция для отображения сообщения о возврате в главное меню
show_return_to_menu_message() {
    echo ""
    read -p "Нажмите Enter для продолжения..." -r
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
    DIR_BACKUPS=($(find "${USER_BACKUP_DIR}" -maxdepth 1 -type d -name "${PROJECT_NAME}_"* 2>/dev/null | sort -r))
    
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
        read -p "Вы уверены? (д/y - да, н/n - нет): " confirm
        
        if [[ ! "$confirm" =~ ^[yдYД]$ ]]; then
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
        read -p "Вы уверены, что хотите восстановить данные из '$backup_name'? (д/y - да, н/n - нет): " confirm
        
        if [[ ! "$confirm" =~ ^[yдYД]$ ]]; then
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
        UNPACKED_DIR=$(find "$TEMP_DIR" -maxdepth 1 -type d -name "${PROJECT_NAME}_"* | head -n 1)
        
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
            read -p "Вы действительно хотите удалить ВСЕ пользовательские бэкапы? Это действие необратимо! (д/y - да, н/n - нет): " confirm
            if [[ "$confirm" =~ ^[yдYД]$ ]]; then
                rm -f "${USER_BACKUP_DIR}/${PROJECT_NAME}_full_"*.tar.gz
                rm -rf "${USER_BACKUP_DIR}/${PROJECT_NAME}_"*
                print_color "green" "✅ Все пользовательские бэкапы удалены"
            else
                print_color "yellow" "❌ Удаление отменено"
            fi
            ;;
        4)
            if [ -f "${INITIAL_BACKUP_DIR}/initial_backup.tar.gz" ]; then
                read -p "Вы действительно хотите удалить системный (initial) бэкап? (д/y - да, н/n - нет): " confirm
                if [[ "$confirm" =~ ^[yдYД]$ ]]; then
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

# Функция для обновления версии в .env файле
update_env_version() {
    local env_file="$1"
    local new_version="$2"
    local edition="$3" # "slim" или "full"
    
   
    
    if [ ! -f "$env_file" ]; then
        log_message "ERROR" "Файл .env не найден: $env_file"
        echo "Ошибка: Файл .env не найден: $env_file"
        return 1
    fi
    
    echo "Обновление версии RAGFlow в файле .env..."
    log_message "INFO" "Обновление версии RAGFlow на $new_version ($edition)"
    
    # Создаем резервную копию .env файла
    cp "$env_file" "$env_file.backup"
    
    # Определяем образ в зависимости от выбранной редакции
    local image_name="infiniflow/ragflow:${new_version}"
    if [ "$edition" == "slim" ]; then
        image_name="${image_name}-slim"
    fi
    
    # Комментируем все строки с RAGFLOW_IMAGE
    sed -i '/^RAGFLOW_IMAGE=/s/^/# /' "$env_file"
    sed -i '/^# RAGFLOW_IMAGE=/s/^# /# # /' "$env_file"
    
    # Ищем место для вставки новой строки (после последней закомментированной строки RAGFLOW_IMAGE)
    local insert_line=$(grep -n "RAGFLOW_IMAGE" "$env_file" | tail -1 | cut -d: -f1)
    
    if [ -n "$insert_line" ]; then
        # Вставляем новую строку после найденной позиции
        sed -i "${insert_line}a\\RAGFLOW_IMAGE=${image_name}" "$env_file"
    else
        # Если не найдено, добавляем в конец файла
        echo "RAGFLOW_IMAGE=${image_name}" >> "$env_file"
    fi
    
    echo "Версия RAGFlow обновлена на: $image_name"
    log_message "INFO" "Версия RAGFlow успешно обновлена на: $image_name"
    
    # Показываем изменения пользователю
    echo "Текущая активная версия в .env:"
    grep "^RAGFLOW_IMAGE=" "$env_file" || echo "Ошибка: не удалось найти активную строку RAGFLOW_IMAGE"
    
    return 0
}

# Функция для установки RAGFlow
# ======= Основной код =======
# Обработка аргументов командной строки (включая справку)
if [ "$#" -gt 0 ]; then
    # Проверяем команды справки без требования root
    case "$1" in
        -h|--help)
            show_help
            exit 0
            ;;
        -v|--version)
            echo "XRM Director Installer v$VERSION"
            exit 0
            ;;
    esac
    
    # Для остальных команд требуем права root
    check_root
    parse_cli_args "$@"
    
    # Выполняем установку через CLI
    if [ $CLI_MODE -eq 1 ]; then
        # Инициализация логирования для CLI
        init_logging
        cli_install
        exit 0
    fi
else
    # Для интерактивного режима требуем права root
    check_root
fi

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
        read -p "Вы уверены, что хотите восстановить данные из '$backup_name'? (д/y - да, н/n - нет): " confirm
        
        if [[ ! "$confirm" =~ ^[yдYД]$ ]]; then
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
        UNPACKED_DIR=$(find "$TEMP_DIR" -maxdepth 1 -type d -name "${PROJECT_NAME}_"* | head -n 1)
        
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
            read -p "Вы действительно хотите удалить ВСЕ пользовательские бэкапы? Это действие необратимо! (д/y - да, н/n - нет): " confirm
            if [[ "$confirm" =~ ^[yдYД]$ ]]; then
                rm -f "${USER_BACKUP_DIR}/${PROJECT_NAME}_full_"*.tar.gz
                rm -rf "${USER_BACKUP_DIR}/${PROJECT_NAME}_"*
                print_color "green" "✅ Все пользовательские бэкапы удалены"
            else
                print_color "yellow" "❌ Удаление отменено"
            fi
            ;;
        4)
            if [ -f "${INITIAL_BACKUP_DIR}/initial_backup.tar.gz" ]; then
                read -p "Вы действительно хотите удалить системный (initial) бэкап? (д/y - да, н/n - нет): " confirm
                if [[ "$confirm" =~ ^[yдYД]$ ]]; then
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

# Функция для обновления версии в .env файле
update_env_version() {
    local env_file="$1"
    local new_version="$2"
    local edition="$3" # "slim" или "full"
    
   
    
    if [ ! -f "$env_file" ]; then
        log_message "ERROR" "Файл .env не найден: $env_file"
        echo "Ошибка: Файл .env не найден: $env_file"
        return 1
    fi
    
    echo "Обновление версии RAGFlow в файле .env..."
    log_message "INFO" "Обновление версии RAGFlow на $new_version ($edition)"
    
    # Создаем резервную копию .env файла
    cp "$env_file" "$env_file.backup"
    
    # Определяем образ в зависимости от выбранной редакции
    local image_name="infiniflow/ragflow:${new_version}"
    if [ "$edition" == "slim" ]; then
        image_name="${image_name}-slim"
    fi
    
    # Комментируем все строки с RAGFLOW_IMAGE
    sed -i '/^RAGFLOW_IMAGE=/s/^/# /' "$env_file"
    sed -i '/^# RAGFLOW_IMAGE=/s/^# /# # /' "$env_file"
    
    # Ищем место для вставки новой строки (после последней закомментированной строки RAGFLOW_IMAGE)
    local insert_line=$(grep -n "RAGFLOW_IMAGE" "$env_file" | tail -1 | cut -d: -f1)
    
    if [ -n "$insert_line" ]; then
        # Вставляем новую строку после найденной позиции
        sed -i "${insert_line}a\\RAGFLOW_IMAGE=${image_name}" "$env_file"
    else
        # Если не найдено, добавляем в конец файла
        echo "RAGFLOW_IMAGE=${image_name}" >> "$env_file"
    fi
    
    echo "Версия RAGFlow обновлена на: $image_name"
    log_message "INFO" "Версия RAGFlow успешно обновлена на: $image_name"
    
    # Показываем изменения пользователю
    echo "Текущая активная версия в .env:"
    grep "^RAGFLOW_IMAGE=" "$env_file" || echo "Ошибка: не удалось найти активную строку RAGFLOW_IMAGE"
    
    return 0
}

# Функция для установки RAGFlow
# ======= Основной код =======
# Обработка аргументов командной строки (включая справку)
if [ "$#" -gt 0 ]; then
    # Проверяем команды справки без требования root
    case "$1" in
        -h|--help)
            show_help
            exit 0
            ;;
        -v|--version)
            echo "XRM Director Installer v$VERSION"
            exit 0
            ;;
    esac
    
    # Для остальных команд требуем права root
    check_root
    parse_cli_args "$@"
    
    # Выполняем установку через CLI
    if [ $CLI_MODE -eq 1 ]; then
        # Инициализация логирования для CLI
        init_logging
        cli_install
        exit 0
    fi
else
    # Для интерактивного режима требуем права root
    check_root
fi

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
