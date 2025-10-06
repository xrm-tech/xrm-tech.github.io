#!/bin/bash

# ======= Переменные для конфигурации =======
VERSION="1.1"
LOG_FILE="/var/log/xrmd_install.log"
DOCKER_MIN_VERSION="24.0.0"
DOCKER_COMPOSE_MIN_VERSION="v2.26.1"
REQUIRED_CPU_CORES=4
REQUIRED_RAM_GB=16
REQUIRED_DISK_GB=50
MAX_MAP_COUNT=262144
INSTALL_DIR="/opt/xrm-director/docker"
# Переменные docker
DOCKER_DIR="${INSTALL_DIR}"
DOCKER_COMPOSE_YML="${DOCKER_DIR}/docker-compose.yml"
DOCKER_COMPOSE_GPU_YML="${DOCKER_DIR}/docker-compose-gpu.yml"
DOCKER_ENV="${DOCKER_DIR}/.env"
RAGFLOW_SLIM_IMAGE="infiniflow/ragflow:v0.19.1-slim"
RAGFLOW_FULL_IMAGE="infiniflow/ragflow:v0.19.1"
# Переменные llm
LLM_CHAT="hf.co/rrelaxx/saiga_gemma3_12b-Q4_K_S-GGUF:Q4_K_S"
LLM_EMB="snowflake-arctic-embed:335m"
XINFERENCE_RERANK_MODEL="bge-reranker-base"
XINFERENCE_CONTAINER_NAME="xinference_rerank"
# Переменные для резервного копирования
BACKUP_DIR="/opt/xrm-director/backups"
PROJECT_NAME="ragflow"
DATE_FORMAT="$(date +%Y-%m-%d_%H-%M-%S)"
# Переменные для загрузки и парсинга файла базы знаний при initial backup
API_KEY="ragflow-ZjNTQxMjc0ZTE2ZTExZWZiYzQ3MDI0Mm"
BASE_URL="http://94.126.205.47:9380"
DATASET_ID="d4d37ae83a3611f0a0e40242ac120006"
FILE_PATH="/opt/xrm-director/kb/kb.txt"
DOWNLOAD_URL="https://files.x-rm.ru/xrm_director/kb/kb.txt"
# ======= Настройки резервного копирования =======
INITIAL_BACKUP_FILENAME="initial_backup_v_1_1.tar.gz"
INITIAL_BACKUP_URL="https://files.x-rm.ru/xrm_director/backup/${INITIAL_BACKUP_FILENAME}"
INITIAL_BACKUP_DIR="${BACKUP_DIR}/initial"
USER_BACKUP_DIR="${BACKUP_DIR}/user"
AUTO_RESTORE_INITIAL_BACKUP=0 # 0 - отключить, 1 - включить авторазвертывание initial backup

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
        
        # Проверяем ответ (принимаем только д/да/yes/y для да и н/нет/no/n для нет)
        case "$response" in
            д|y|да|yes)
                return 0  # Подтверждение
                ;;
            н|n|нет|no)
                return 1  # Отказ
                ;;
            *)
                echo "Пожалуйста, введите 'д', 'да', 'y' или 'yes' для подтверждения, 'н', 'нет', 'n' или 'no' для отказа"
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
    
    # Создание директории utils и скачивание файла agent manager
    echo "Создание директории для утилит и скачивание xrmd_agent_manager.py..."
    mkdir -p "/opt/xrm-director/utils"
    if ! curl -sSf https://files.x-rm.ru/xrm_director/xrmd_agent_manager.py -o "/opt/xrm-director/utils/xrmd_agent_manager.py"; then
        log_message "WARNING" "Не удалось скачать файл xrmd_agent_manager.py"
        echo "Предупреждение: Не удалось скачать файл xrmd_agent_manager.py"
    else
        log_message "INFO" "Файл xrmd_agent_manager.py успешно скачан в /opt/xrm-director/utils/"
        echo "Файл xrmd_agent_manager.py успешно скачан в /opt/xrm-director/utils/"
        # Установка прав на выполнение для скрипта
        chmod +x "/opt/xrm-director/utils/xrmd_agent_manager.py"
    fi

    # Установка pip и ragflow-sdk
    echo "Установка pip..."
    if ! dnf install python3-pip -y; then
        log_message "WARNING" "Не удалось установить python3-pip"
        echo "Предупреждение: Не удалось установить python3-pip"
    else
        log_message "INFO" "python3-pip успешно установлен"
        echo "python3-pip успешно установлен"
        
        echo "Установка ragflow-sdk..."
        if ! pip3 install ragflow-sdk; then
            log_message "WARNING" "Не удалось установить ragflow-sdk"
            echo "Предупреждение: Не удалось установить ragflow-sdk"
        else
            log_message "INFO" "ragflow-sdk успешно установлен"
            echo "ragflow-sdk успешно установлен"
        fi
    fi

    # Создание директорий для резервных копий
    mkdir -p "${INITIAL_BACKUP_DIR}" "${USER_BACKUP_DIR}"
    
    # Скачивание initial backup только в директорию initial
    echo "Загрузка initial backup..."
    if ! wget --no-check-certificate -O "${INITIAL_BACKUP_DIR}/${INITIAL_BACKUP_FILENAME}" "${INITIAL_BACKUP_URL}" || [ ! -s "${INITIAL_BACKUP_DIR}/${INITIAL_BACKUP_FILENAME}" ]; then
        log_message "WARNING" "Не удалось загрузить initial backup"
        echo "Предупреждение: Initial backup не загружен"
        
        # Попытка загрузить напрямую по конкретному URL
        echo "Пробуем альтернативную загрузку initial backup..."
        if ! wget --no-check-certificate -O "${INITIAL_BACKUP_DIR}/${INITIAL_BACKUP_FILENAME}" "https://files.x-rm.ru/xrm_director/backup/${INITIAL_BACKUP_FILENAME}"; then
            log_message "WARNING" "Альтернативная загрузка initial backup тоже не удалась"
            echo "Предупреждение: Альтернативная загрузка initial backup тоже не удалась"
        else
            log_message "INFO" "Initial backup успешно загружен альтернативным способом"
            echo "Initial backup загружен в ${INITIAL_BACKUP_DIR}"
            echo "Проверка целостности загруженного файла..."
            if ! tar -tzf "${INITIAL_BACKUP_DIR}/${INITIAL_BACKUP_FILENAME}" &>/dev/null; then
                log_message "ERROR" "Целостность загруженного initial backup не удалась"
                echo "Ошибка: Целостность загруженного initial backup не удалась"
                return 1
            fi
        fi
    else
        log_message "INFO" "Initial backup успешно загружен"
        echo "Initial backup загружен в ${INITIAL_BACKUP_DIR}"
        echo "Проверка целостности загруженного файла..."
        if ! tar -tzf "${INITIAL_BACKUP_DIR}/${INITIAL_BACKUP_FILENAME}" &>/dev/null; then
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
    if ! tar -xzf docker.tar.gz --strip-components=1; then
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
        if [ -f "${INITIAL_BACKUP_DIR}/${INITIAL_BACKUP_FILENAME}" ]; then
            echo "Развертывание начальной резервной копии..."
            
            # Создаем временную директорию для распаковки
            TEMP_RESTORE_DIR=$(mktemp -d)
            
            # Распаковываем архив
            tar -xzf "${INITIAL_BACKUP_DIR}/${INITIAL_BACKUP_FILENAME}" -C "${TEMP_RESTORE_DIR}"
            
            # Находим директорию с бэкапами (обычно имеет формат ragflow_*)
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
        
        # Заменяем в контейнере ragflow-server исправленный файл prompts.py 
        docker exec -i ragflow-server curl -sSf https://files.x-rm.ru/xrm_director/prompts.py -o /ragflow/rag/prompts.py -f

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
    
    # Установка LLM-Server
    echo "Установка llm-server..."
    
    # Проверяем и удаляем существующий контейнер LLM-Server
    if docker ps -a --format '{{.Names}}' | grep -q "^llm-server$"; then
        echo "Найден существующий контейнер llm-server, удаляем..."
        docker stop llm-server 2>/dev/null || true
        docker rm llm-server 2>/dev/null || true
    fi
    
    # Запуск контейнера llm-server
    if ! docker run -d --name llm-server -e OLLAMA_DEBUG=1 -p 11434:11434 ollama/ollama; then
        log_message "ERROR" "Не удалось запустить контейнер llm-server"
        echo "❌ Ошибка: Не удалось запустить контейнер llm-server"
        echo "Установка будет продолжена без llm-server..."
        log_message "WARNING" "Установка продолжена без llm-server"
    else
        log_message "INFO" "Контейнер llm-server успешно запущен"
        echo "✅ Контейнер llm-server успешно запущен"
        
        # Установка моделей в llm-server
        echo "Установка моделей в llm-server..."
        sleep 5
        
        # Установка первой модели (LLM)
        echo "Установка модели $LLM_CHAT в llm-server..."
        if ! docker exec llm-server ollama run $LLM_CHAT; then
            log_message "ERROR" "Не удалось установить модель $LLM_CHAT в llm-server"
            echo "Ошибка: Не удалось установить модель $LLM_CHAT в llm-server"
        else
            log_message "INFO" "Модель $LLM_CHAT успешно установлена в llm-server"
            echo "Модель $LLM_CHAT успешно установлена в llm-server"
        fi
        
        # Установка второй модели (embedding)
        echo "Установка модели $LLM_EMB (embedding) в llm-server..."
        if ! docker exec llm-server ollama pull $LLM_EMB; then
            log_message "ERROR" "Не удалось установить модель $LLM_EMB в llm-server"
            echo "Ошибка: Не удалось установить модель $LLM_EMB в llm-server"
        else
            log_message "INFO" "Модель $LLM_EMB успешно установлена в llm-server"
            echo "Модель $LLM_EMB успешно установлена в llm-server"
        fi
    fi
    
    # Развертывание XINFERENCE

echo "=== Начало развертывания XINFERENCE с моделью Reranker ==="
echo "Запуск контейнера XINFERENCE..."
docker run -d --name $XINFERENCE_CONTAINER_NAME \
  -e XINFERENCE_MODEL_SRC=modelscope \
  -e CUDA_VISIBLE_DEVICES="" \
  -e XINFERENCE_DEVICE=cpu \
  -p 9998:9997 \
  xprobe/xinference:nightly-main-cpu \
  xinference-local -H 0.0.0.0 --log-level debug

if [ $? -ne 0 ]; then
    echo "Ошибка: Не удалось запустить контейнер"
    exit 1
fi

echo "Контейнер запущен с именем: $XINFERENCE_CONTAINER_NAME"

echo "Ожидание запуска сервера XINFERENCE..."
MAX_WAIT=60
WAIT_COUNT=0
SERVER_READY=false

while [ $WAIT_COUNT -lt $MAX_WAIT ]; do
    # Проверяем доступность API эндпоинта
    if curl -s http://localhost:9998/v1/models > /dev/null 2>&1; then
        echo "Сервер XINFERENCE готов к работе"
        SERVER_READY=true
        break
    fi
    
    echo "Ожидание готовности сервера... ($((WAIT_COUNT + 1))/$MAX_WAIT)"
    sleep 5
    WAIT_COUNT=$((WAIT_COUNT + 1))
done

if [ "$SERVER_READY" = false ]; then
    echo "Ошибка: Сервер XINFERENCE не запустился в течение $MAX_WAIT секунд"
    docker logs $XINFERENCE_CONTAINER_NAME
    exit 1
fi

echo "Запуск модели Reranker: $XINFERENCE_RERANK_MODEL"
docker exec $XINFERENCE_CONTAINER_NAME xinference launch \
  --model-name $XINFERENCE_RERANK_MODEL \
  --model-type rerank \
  --model-engine sentence_transformers \
  --model-format pytorch \
  --quantization none \
  --replica 1

if [ $? -ne 0 ]; then
    echo "Ошибка: Не удалось запустить модель $XINFERENCE_RERANK_MODEL"
    exit 1
fi

echo "Модель $XINFERENCE_RERANK_MODEL успешно запущена"

docker exec $XINFERENCE_CONTAINER_NAME xinference list
echo "Контейнер: $XINFERENCE_CONTAINER_NAME"
echo "Модель Reranker: $XINFERENCE_RERANK_MODEL"
    
    # Определение IP-адреса сервера
    local server_ip=$(hostname -I | awk '{print $1}')
    
    log_message "INFO" "XRM Director успешно установлен"
    echo "✅ XRM Director успешно установлен!"
    echo "📁 Установочная директория: $INSTALL_DIR/"
    echo "📋 Логи: $LOG_FILE"
    
    # Дополнительная пауза, чтобы пользователь мог прочитать результат установки
    echo ""
    read -p "Нажмите Enter для продолжения..." -r
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
    if ! check_docker_before_install; then
        echo "❌ Проверка Docker не пройдена. Установка прервана."
        exit 1
    fi
    
    # Установка XRM Director
    echo "🎯 Установка XRM Director..."
    if ! install_xrm_director_cli; then
        echo "❌ Ошибка установки XRM Director"
        exit 1
    fi
}

# Функция проверки наличия NVIDIA GPU
has_nvidia_gpu() {
    # Проверяем наличие nvidia-smi
    if command -v nvidia-smi >/dev/null 2>&1; then
        # Проверяем, что NVIDIA GPU доступна
        if nvidia-smi >/dev/null 2>&1; then
            return 0
        fi
    fi
    
    # Проверяем наличие файла устройства NVIDIA
    if [ -e "/dev/nvidia0" ] || [ -e "/dev/nvidiactl" ]; then
        return 0
    fi
    
    return 1
}

# Универсальная функция для запроса подтверждения (принимает только д/y/да/yes или н/n/нет/no)
ask_yes_no() {
    local prompt="$1"
    local default_answer="${2:-}"  # Опциональный параметр для ответа по умолчанию
    
    while true; do
        if [[ -n "$default_answer" ]]; then
            echo -n "$prompt (д/y/да/yes - да, н/n/нет/no - нет, по умолчанию: $default_answer): "
        else
            echo -n "$prompt (д/y/да/yes - да, н/n/нет/no - нет): "
        fi
        
        read -r answer
        
        # Если ответ пустой и есть значение по умолчанию
        if [[ -z "$answer" && -n "$default_answer" ]]; then
            answer="$default_answer"
        fi
        
        # Преобразуем ответ в нижний регистр для упрощения проверки
        answer=$(echo "$answer" | tr '[:upper:]' '[:lower:]')
        
        # Проверяем ответ (принимаем расширенный набор вариантов для да и нет)
        case "$answer" in
            д|y|да|yes)
                return 0  # Да
                ;;
            н|n|нет|no)
                return 1  # Нет
                ;;
            *)
                echo "❌ Пожалуйста, введите: 'д', 'да', 'y', 'yes' для подтверждения, 'н', 'нет', 'n', 'no' для отказа"
                ;;
        esac
    done
}

# Функция тихой проверки системных требований (для CLI режима)
check_system_requirements_silent() {
    local all_ok=1
    local warnings=()
    
    echo "📋 Проверка системных требований:"
    
    # Проверка ОС и её версии
    if [ ! -f /etc/redhat-release ] && [ ! -f /etc/centos-release ]; then
        echo "❌ ОС: Неподдерживаемая операционная система"
        echo "   Требуется: Red Hat Enterprise Linux / CentOS"
        log_message "ERROR" "Неподдерживаемая операционная система"
        warnings+=("Неподдерживаемая операционная система")
        all_ok=0
    else
        local os_display_name=$(cat /etc/redhat-release 2>/dev/null || cat /etc/centos-release 2>/dev/null)
        
        if [ -f /etc/os-release ]; then
            local os_name=$(grep '^NAME=' /etc/os-release | cut -d= -f2 | tr -d '"')
            local os_version_str=$(grep '^VERSION=' /etc/os-release | cut -d= -f2 | tr -d '"')
            local os_version_num=$(echo "$os_version_str" | grep -oP '\(\K[0-9]+\.[0-9]+' 2>/dev/null || echo "$os_version_str" | awk '{print $NF}' | cut -d. -f1-2)
            local os_major=$(echo "$os_version_num" | cut -d. -f1)
            
            if [ -n "$os_major" ] && [ "$os_major" -ge 8 ] 2>/dev/null; then
                echo "✅ ОС: $os_name $os_version_str - OK"
            else
                echo "✅ ОС: $os_name $os_version_str - ПРЕДУПРЕЖДЕНИЕ"
                echo "   Для нормального функционирования рекомендуем RED OS версии 8.0 или выше."
            fi
        else
            echo "✅ ОС: $os_display_name - Не удалось определить версию ОС"
        fi
    fi
    
    # Проверка CPU
    local cpu_cores=$(nproc)
    if [ "$cpu_cores" -lt "$REQUIRED_CPU_CORES" ]; then
        echo "❌ CPU: $cpu_cores ядер (требуется: $REQUIRED_CPU_CORES)"
        log_message "ERROR" "Недостаточно ядер CPU: найдено $cpu_cores, требуется $REQUIRED_CPU_CORES"
        warnings+=("Недостаточно ядер CPU: $cpu_cores < $REQUIRED_CPU_CORES")
        all_ok=0
    else
        echo "✅ CPU: $cpu_cores ядер (требуется: $REQUIRED_CPU_CORES)"
    fi
    
    # Проверка RAM
    local ram_gb=$(free -g | awk '/^Mem:/{print $2}')
    if [ "$ram_gb" -lt "$REQUIRED_RAM_GB" ]; then
        echo "❌ RAM: ${ram_gb}GB (требуется: ${REQUIRED_RAM_GB}GB)"
        log_message "ERROR" "Недостаточно RAM: найдено ${ram_gb}GB, требуется ${REQUIRED_RAM_GB}GB"
        warnings+=("Недостаточно RAM: ${ram_gb}GB < ${REQUIRED_RAM_GB}GB")
        all_ok=0
    else
        echo "✅ RAM: ${ram_gb}GB (требуется: ${REQUIRED_RAM_GB}GB)"
    fi
    
    # Проверка места на диске
    local disk_gb=$(df / | awk 'NR==2{print int($4/1024/1024)}')
    if [ "$disk_gb" -lt "$REQUIRED_DISK_GB" ]; then
        echo "❌ Диск: ${disk_gb}GB свободно (требуется: ${REQUIRED_DISK_GB}GB)"
        log_message "ERROR" "Недостаточно места на диске: найдено ${disk_gb}GB, требуется ${REQUIRED_DISK_GB}GB"
        warnings+=("Недостаточно места на диске: ${disk_gb}GB < ${REQUIRED_DISK_GB}GB")
        all_ok=0
    else
        echo "✅ Диск: ${disk_gb}GB свободно (требуется: ${REQUIRED_DISK_GB}GB)"
    fi
    
    # Если есть проблемы, показываем их и даем выбор
    if [ $all_ok -eq 0 ]; then
        echo ""
        echo "⚠️  Обнаружены следующие проблемы:"
        for warning in "${warnings[@]}"; do
            echo "   • $warning"
        done
        echo ""
        echo "🤔 Что делать?"
        echo "1. Отменить установку (рекомендуется)"
        echo "2. Продолжить установку (может привести к проблемам)"
        echo ""
        read -p "Ваш выбор (1-2): " choice
        
        case $choice in
            1)
                echo "🛑 Установка отменена пользователем"
                log_message "INFO" "Установка отменена из-за невыполнения системных требований"
                return 1
                ;;
            2)
                echo "⚠️  Продолжаем установку, игнорируя предупреждения..."
                log_message "WARNING" "Установка продолжена с игнорированием системных требований"
                return 0
                ;;
            *)
                echo "❌ Неверный выбор. Установка отменена."
                return 1
                ;;
        esac
    fi
    
    echo "✅ Все системные требования выполнены"
    return 0
}

# Функция тихой проверки Docker
check_docker_installed_silent() {
    if ! command -v docker &> /dev/null; then
        log_message "INFO" "Docker не установлен"
        return 1
    fi
    
    if ! systemctl is-active --quiet docker; then
        log_message "INFO" "Docker не запущен, запускаем..."
        systemctl start docker
        if ! systemctl is-active --quiet docker; then
            log_message "ERROR" "Не удалось запустить Docker"
            return 1
        fi
    fi
    
    return 0
}

# Функция для проверки наличия Docker перед установкой
check_docker_before_install() {
    log_message "INFO" "Проверка наличия Docker перед установкой..."
    
    if ! command -v docker &> /dev/null; then
        log_message "ERROR" "Docker не установлен. Необходимо установить Docker для продолжения."
        print_color "red" "❌ Docker не установлен. Установите Docker для продолжения."
        
        # Предложение установить Docker
        if ask_yes_no "Хотите установить Docker прямо сейчас?"; then
            install_docker
            
            # Повторная проверка после установки
            if ! command -v docker &> /dev/null; then
                log_message "ERROR" "Не удалось установить Docker. Установка RagFlow прервана."
                print_color "red" "❌ Не удалось установить Docker. Установка RagFlow прервана."
                return 1
            fi
            
            log_message "INFO" "Docker успешно установлен."
            print_color "green" "✅ Docker успешно установлен. Продолжаем установку XRM Director."
        else
            log_message "INFO" "Установка Docker отклонена пользователем. Установка RagFlow прервана."
            print_color "yellow" "⚠️ Для установки RagFlow необходим Docker. Установка прервана."
            return 1
        fi
    else
        # Проверка запуска службы Docker
        if ! systemctl is-active --quiet docker; then
            log_message "WARNING" "Docker установлен, но служба не запущена."
            print_color "yellow" "⚠️ Docker установлен, но служба не запущена."
            
            if ask_yes_no "Хотите запустить службу Docker?"; then
                systemctl start docker
                
                if ! systemctl is-active --quiet docker; then
                    log_message "ERROR" "Не удалось запустить службу Docker. Установка RagFlow прервана."
                    print_color "red" "❌ Не удалось запустить службу Docker. Установка RagFlow прервана."
                    return 1
                fi
                
                log_message "INFO" "Служба Docker успешно запущена."
                print_color "green" "✅ Служба Docker успешно запущена."
            else
                log_message "INFO" "Запуск службы Docker отклонен пользователем. Установка RagFlow прервана."
                print_color "yellow" "⚠️ Для установки RagFlow необходимо запустить службу Docker. Установка прервана."
                return 1
            fi
        fi
        
        # Docker установлен и запущен
        log_message "INFO" "Docker установлен и запущен. Продолжаем установку XRM Director."
        print_color "green" "✅ Docker установлен и запущен."
    fi
    
    return 0
}

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
    
    # Вывод информации о CPU
    if [ "$cpu_cores" -lt "$REQUIRED_CPU_CORES" ]; then
        echo "❌ CPU: $cpu_cores ядер (требуется: $REQUIRED_CPU_CORES)"
    else
        echo "✅ CPU: $cpu_cores ядер (требуется: $REQUIRED_CPU_CORES)"
    fi
    
    # Вывод информации о RAM
    if [ "$ram_gb" -lt "$REQUIRED_RAM_GB" ]; then
        echo "❌ RAM: ${ram_gb}GB (требуется: ${REQUIRED_RAM_GB}GB)"
    else
        echo "✅ RAM: ${ram_gb}GB (требуется: ${REQUIRED_RAM_GB}GB)"
    fi
    
    # Вывод информации о дисковом пространстве
    if [ "$disk_gb" -lt "$REQUIRED_DISK_GB" ]; then
        echo "❌ Диск: ${disk_gb}GB свободно (требуется: ${REQUIRED_DISK_GB}GB)"
    else
        echo "✅ Диск: ${disk_gb}GB свободно (требуется: ${REQUIRED_DISK_GB}GB)"
    fi
    
    # Проверка версии ОС
    if [ -f /etc/os-release ]; then
        local os_name=$(grep '^NAME=' /etc/os-release | cut -d= -f2 | tr -d '"')
        local os_version_str=$(grep '^VERSION=' /etc/os-release | cut -d= -f2 | tr -d '"')
        local os_version_num=$(echo "$os_version_str" | grep -oP '\(\K[0-9]+\.[0-9]+' 2>/dev/null || echo "$os_version_str" | awk '{print $NF}' | cut -d. -f1-2)
        local os_major=$(echo "$os_version_num" | cut -d. -f1)
        
        if [ -n "$os_major" ] && [ "$os_major" -ge 8 ] 2>/dev/null; then
            echo "✅ ОС: $os_name $os_version_str - OK"
        else
            echo "❌ ОС: $os_name $os_version_str - ПРЕДУПРЕЖДЕНИЕ:"
            echo "   Для нормального функционирования рекомендуем RED OS версии 8.0 или выше."
        fi
    else
        echo "❌ ОС: Не удалось определить версию ОС"
    fi
    
    # Проверка Docker, если установлен
    if command -v docker &>/dev/null; then
        local docker_version=$(docker --version | awk '{print $3}' | sed 's/,//')
        echo "✅ Docker: $docker_version (минимум: $DOCKER_MIN_VERSION) - $(check_version "$docker_version" "$DOCKER_MIN_VERSION" && echo "OK" || echo "НЕ СООТВЕТСТВУЕТ")"
    else
        echo "❌ Docker: Не установлен"
    fi
    
    # Проверка Docker Compose, если установлен
    if docker compose version &>/dev/null; then
        # Упрощенное получение версии Docker Compose
        local compose_version=$(docker compose version | grep -o "[0-9]\+\.[0-9]\+\.[0-9]\+")
        
        echo "✅ Docker Compose: $compose_version (минимум: $DOCKER_COMPOSE_MIN_VERSION) - $(check_version "$compose_version" "$DOCKER_COMPOSE_MIN_VERSION" && echo "OK" || echo "НЕ СООТВЕТСТВУЕТ")"
    else
        echo "❌ Docker Compose: Не установлен"
    fi
    
    # Проверка Python, если установлен
    if command -v python3 &>/dev/null; then
        local python_version=$(python3 -c 'import sys; print(f"{sys.version_info.major}.{sys.version_info.minor}.{sys.version_info.micro}")')
        local python_major=$(echo "$python_version" | cut -d. -f1)
        local python_minor=$(echo "$python_version" | cut -d. -f2)
        
        # Проверка совместимости версии Python для ragflow-sdk
        if [ "$python_major" -eq 3 ] && [ "$python_minor" -ge 10 ] && [ "$python_minor" -le 13 ]; then
            echo "✅ Python: $python_version - OK (совместим с ragflow-sdk)"
        else
            echo "❌ Python: $python_version - ПРЕДУПРЕЖДЕНИЕ"
            echo "   Для работы с утилитой \"Менеджер по работе с агентами XRM Director\""
            echo "   требуется ragflow-sdk, для его установки рекомендуем установить python версии >3.10 - <3.13"
            echo "   например 3.11.9.\""
        fi
    else
        echo "Python: Не установлен"
        echo "   Для работы с утилитой \"Менеджер по работе с агентами XRM Director\" рекомендуется"
        echo "   установить Python версии 3.10-3.13 (например 3.11.9) и ragflow-sdk\""
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
            if ask_yes_no "Хотите продолжить установку Docker/Docker Compose?"; then
                install_docker
            fi
        fi
    else
        echo "Docker не установлен"
        if ask_yes_no "Хотите установить Docker/Docker Compose?"; then
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
        if ask_yes_no "Хотите установить Docker Compose?"; then
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

# Функция для получения списка доступных версий RAGFlow
get_available_versions() {
    # Актуальный список версий из Docker Hub (https://hub.docker.com/r/infiniflow/ragflow/tags)
    local versions=(
        "nightly"
        "v0.19.0"
        "v0.18.0"
        "v0.19.1"
        "v0.17.1"
        "v0.17.0"
    )
    
    # Возвращаем версии через echo для использования в других функциях
    printf '%s\n' "${versions[@]}"
}

# Функция для выбора версии RAGFlow
# ======= Функции для установки и управления XRM Director =======
# Функция для установки XRM Director
install_xrm_director() {
    log_message "INFO" "Установка XRM Director..."

    echo "====== Установка XRM Director ======"
    
    # Проверка наличия Docker
    if ! check_docker_before_install; then
        echo "Установка XRM Director прервана. Docker не установлен или не запущен."
        return 1
    fi

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

     # Создание директории utils и скачивание файла agent manager
    echo "Создание директории для утилит и скачивание xrmd_agent_manager.py..."
    mkdir -p "/opt/xrm-director/utils"
    if ! curl -sSf https://files.x-rm.ru/xrm_director/xrmd_agent_manager.py -o "/opt/xrm-director/utils/xrmd_agent_manager.py"; then
        log_message "WARNING" "Не удалось скачать файл xrmd_agent_manager.py"
        echo "Предупреждение: Не удалось скачать файл xrmd_agent_manager.py"
    else
        log_message "INFO" "Файл xrmd_agent_manager.py успешно скачан в /opt/xrm-director/utils/"
        echo "Файл xrmd_agent_manager.py успешно скачан в /opt/xrm-director/utils/"
        # Установка прав на выполнение для скрипта
        chmod +x "/opt/xrm-director/utils/xrmd_agent_manager.py"
    fi
    
    # Установка pip и ragflow-sdk
    echo "Установка pip..."
    if ! dnf install python3-pip -y; then
        log_message "WARNING" "Не удалось установить python3-pip"
        echo "Предупреждение: Не удалось установить python3-pip"
    else
        log_message "INFO" "python3-pip успешно установлен"
        echo "python3-pip успешно установлен"
        
        echo "Установка ragflow-sdk..."
        if ! pip3 install ragflow-sdk; then
            log_message "WARNING" "Не удалось установить ragflow-sdk"
            echo "Предупреждение: Не удалось установить ragflow-sdk"
        else
            log_message "INFO" "ragflow-sdk успешно установлен"
            echo "ragflow-sdk успешно установлен"
        fi
    fi

    # Скачивание initial backup только в директорию initial
    echo "Загрузка initial backup..."
    if ! wget --no-check-certificate -O "${INITIAL_BACKUP_DIR}/${INITIAL_BACKUP_FILENAME}" "${INITIAL_BACKUP_URL}" || [ ! -s "${INITIAL_BACKUP_DIR}/${INITIAL_BACKUP_FILENAME}" ]; then
        log_message "WARNING" "Не удалось загрузить initial backup"
        echo "Предупреждение: Initial backup не загружен"
        
        # Попытка загрузить напрямую по конкретному URL
        echo "Пробуем альтернативную загрузку initial backup..."
        if ! wget --no-check-certificate -O "${INITIAL_BACKUP_DIR}/${INITIAL_BACKUP_FILENAME}" "https://files.x-rm.ru/xrm_director/backup/${INITIAL_BACKUP_FILENAME}"; then
            log_message "WARNING" "Альтернативная загрузка initial backup тоже не удалась"
            echo "Предупреждение: Альтернативная загрузка initial backup тоже не удалась"
        else
            log_message "INFO" "Initial backup успешно загружен альтернативным способом"
            echo "Initial backup загружен в ${INITIAL_BACKUP_DIR}"
            echo "Проверка целостности загруженного файла..."
            if ! tar -tzf "${INITIAL_BACKUP_DIR}/${INITIAL_BACKUP_FILENAME}" &>/dev/null; then
                log_message "ERROR" "Целостность загруженного initial backup не удалась"
                echo "Ошибка: Целостность загруженного initial backup не удалась"
                return 1
            fi
        fi
    else
        log_message "INFO" "Initial backup успешно загружен"
        echo "Initial backup загружен в ${INITIAL_BACKUP_DIR}"
        echo "Проверка целостности загруженного файла..."
        if ! tar -tzf "${INITIAL_BACKUP_DIR}/${INITIAL_BACKUP_FILENAME}" &>/dev/null; then
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
    if ! tar -xzf docker.tar.gz --strip-components=1; then
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
        if [ -f "${INITIAL_BACKUP_DIR}/${INITIAL_BACKUP_FILENAME}" ]; then
            echo "Развертывание начальной резервной копии..."
            
            # Создаем временную директорию для распаковки
            TEMP_RESTORE_DIR=$(mktemp -d)
            
            # Распаковываем архив
            tar -xzf "${INITIAL_BACKUP_DIR}/${INITIAL_BACKUP_FILENAME}" -C "${TEMP_RESTORE_DIR}"
            
            # Находим директорию с бэкапами (обычно имеет формат ragflow_*)
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

        # Заменяем в контейнере ragflow-server исправленный файл prompts.py 
        docker exec -i ragflow-server curl -sSf https://files.x-rm.ru/xrm_director/prompts.py -o /ragflow/rag/prompts.py -f

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
    
    # Установка llm-server
    echo "Установка llm-server..."
    
    # Проверяем и удаляем существующий контейнер llm-server
    if docker ps -a --format '{{.Names}}' | grep -q "^llm-server$"; then
        echo "Найден существующий контейнер llm-server, удаляем..."
        docker stop llm-server 2>/dev/null || true
        docker rm llm-server 2>/dev/null || true
    fi
    
    # Запуск контейнера llm-server
    if ! docker run -d --name llm-server -e OLLAMA_DEBUG=1 -p 11434:11434 ollama/ollama; then
        log_message "ERROR" "Не удалось запустить контейнер llm-server"
        echo "❌ Ошибка: Не удалось запустить контейнер llm-server"
        echo "Установка будет продолжена без llm-server..."
        log_message "WARNING" "Установка продолжена без llm-server"
    else
        log_message "INFO" "Контейнер llm-server успешно запущен"
        echo "✅ Контейнер llm-server успешно запущен"
        
        # Установка моделей в llm-server
        echo "Установка моделей в llm-server..."
        sleep 5
        
        # Установка первой модели (LLM)
        echo "Установка модели $LLM_CHAT в llm-server..."
        if ! docker exec llm-server ollama run $LLM_CHAT; then
            log_message "ERROR" "Не удалось установить модель $LLM_CHAT в llm-server"
            echo "Ошибка: Не удалось установить модель $LLM_CHAT в llm-server"
        else
            log_message "INFO" "Модель $LLM_CHAT успешно установлена в llm-server"
            echo "Модель $LLM_CHAT успешно установлена в llm-server"
        fi
        
        # Установка второй модели (embedding)
        echo "Установка модели $LLM_EMB (embedding) в llm-server..."
        if ! docker exec llm-server ollama pull $LLM_EMB; then
            log_message "ERROR" "Не удалось установить модель $LLM_EMB в llm-server"
            echo "Ошибка: Не удалось установить модель $LLM_EMB в llm-server"
        else
            log_message "INFO" "Модель $LLM_EMB успешно установлена в llm-server"
            echo "Модель $LLM_EMB успешно установлена в llm-server"
        fi
    fi
    
    # Развертывание XINFERENCE

    echo "=== Начало развертывания XINFERENCE с моделью Reranker ==="
echo "Запуск контейнера XINFERENCE..."
docker run -d --name $XINFERENCE_CONTAINER_NAME \
  -e XINFERENCE_MODEL_SRC=modelscope \
  -e CUDA_VISIBLE_DEVICES="" \
  -e XINFERENCE_DEVICE=cpu \
  -p 9998:9997 \
  xprobe/xinference:nightly-main-cpu \
  xinference-local -H 0.0.0.0 --log-level debug

if [ $? -ne 0 ]; then
    echo "Ошибка: Не удалось запустить контейнер"
    exit 1
fi

echo "Контейнер запущен с именем: $XINFERENCE_CONTAINER_NAME"

echo "Ожидание запуска сервера XINFERENCE..."
MAX_WAIT=60
WAIT_COUNT=0
SERVER_READY=false

while [ $WAIT_COUNT -lt $MAX_WAIT ]; do
    # Проверяем доступность API эндпоинта
    if curl -s http://localhost:9998/v1/models > /dev/null 2>&1; then
        echo "Сервер XINFERENCE готов к работе"
        SERVER_READY=true
        break
    fi
    
    echo "Ожидание готовности сервера... ($((WAIT_COUNT + 1))/$MAX_WAIT)"
    sleep 5
    WAIT_COUNT=$((WAIT_COUNT + 1))
done

if [ "$SERVER_READY" = false ]; then
    echo "Ошибка: Сервер XINFERENCE не запустился в течение $MAX_WAIT секунд"
    docker logs $XINFERENCE_CONTAINER_NAME
    exit 1
fi

echo "Запуск модели Reranker: $XINFERENCE_RERANK_MODEL"
docker exec $XINFERENCE_CONTAINER_NAME xinference launch \
  --model-name $XINFERENCE_RERANK_MODEL \
  --model-type rerank \
  --model-engine sentence_transformers \
  --model-format pytorch \
  --quantization none \
  --replica 1

if [ $? -ne 0 ]; then
    echo "Ошибка: Не удалось запустить модель $XINFERENCE_RERANK_MODEL"
    exit 1
fi

echo "Модель $XINFERENCE_RERANK_MODEL успешно запущена"

docker exec $XINFERENCE_CONTAINER_NAME xinference list
echo "Контейнер: $XINFERENCE_CONTAINER_NAME"
echo "Модель Reranker: $XINFERENCE_RERANK_MODEL"

    # Определение IP-адреса сервера
    local server_ip=$(hostname -I | awk '{print $1}')
    
    log_message "INFO" "XRM Director успешно установлен"
    echo "✅ XRM Director успешно установлен!"
    echo "📁 Установочная директория: $INSTALL_DIR/"
    echo "📋 Логи: $LOG_FILE"
    
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
    local ollama_container=$(docker ps -a --format '{{.Names}}' | grep "llm-server" || true)

    if [[ -z "$ragflow_containers" && -z "$ollama_container" ]]; then
        log_message "WARNING" "Контейнеры XRM Director не найдены"
        echo "Контейнеры XRM Director не найдены. Возможные причины:"
        echo "  1. XRM Director не был запущен после установки"
        echo "  2. Контейнеры были удалены вручную"

        # Проверяем наличие образов Docker
        if docker images | grep -q -E 'infiniflow/ragflow'; then
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
            echo "llm-server контейнер: $ollama_container"
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

    # Перезапуск контейнера llm-server, если он существует
    if [ -n "$ollama_container" ]; then
        echo "Перезапуск контейнера Ollama..."
        if ! docker restart "$ollama_container"; then
            log_message "ERROR" "Не удалось перезапустить контейнер llm-server"
            echo "Ошибка: не удалось перезапустить контейнер llm-server"
        else
            log_message "INFO" "Контейнер llm-server успешно перезапущен"
            echo "Контейнер llm-server успешно перезапущен"
        fi
    else
        echo "Контейнер llm-server не обнаружен"
    fi

    log_message "INFO" "XRM Director успешно перезапущен"
    echo "XRM Director успешно перезапущен"
    show_return_to_menu_message
}

# Функция для удаления XRM Director
remove_xrm_director() {
    log_message "INFO" "Удаление XRM Director..."
    
    echo "====== Удаление XRM Director ======"
    
    # Быстрое удаление всего сразу (опционально)
    echo ""
    echo "⚠️  ВНИМАНИЕ! Вы можете выбрать один из вариантов:"
    echo "   1. Удалить ВСЁ сразу (контейнеры, образы, тома, директории)"
    echo "   2. Выборочное удаление (будет запрос на каждый компонент)"
    echo ""
    
    if ask_yes_no "Хотите удалить ВСЁ сразу без дополнительных вопросов?"; then
        echo ""
        echo "🔥 Начинается полное удаление XRM Director..."
        
        # Остановка и удаление всех контейнеров
        local all_containers=$(docker ps -a --format '{{.Names}}' | grep -E "(ragflow|xinference|llm-server)" || true)
        if [[ -n "$all_containers" ]]; then
            echo "Остановка всех контейнеров..."
            docker ps -a --format '{{.Names}}' | grep -E "(ragflow|xinference|llm-server)" | xargs -r docker stop 2>/dev/null
            echo "Удаление всех контейнеров..."
            docker ps -a --format '{{.Names}}' | grep -E "(ragflow|xinference|llm-server)" | xargs -r docker rm 2>/dev/null
            echo "✅ Все контейнеры удалены"
        fi
        
        # Удаление всех томов
        local all_volumes=$(docker volume ls --format '{{.Name}}' | grep -E "(ragflow|xinference)" || true)
        if [[ -n "$all_volumes" ]]; then
            echo "Удаление всех томов..."
            docker volume ls --format '{{.Name}}' | grep -E "(ragflow|xinference)" | xargs -r docker volume rm 2>/dev/null
            echo "✅ Все тома удалены"
        fi
        
        # Удаление всех образов
        echo "Удаление всех образов..."
        docker images --format '{{.Repository}}:{{.Tag}}' | grep -E "(infiniflow/ragflow|ollama/ollama|xprobe/xinference)" | xargs -r docker rmi -f 2>/dev/null
        echo "✅ Все образы удалены"
        
        # Удаление директории установки
        if [ -d "$INSTALL_DIR" ]; then
            echo "Удаление директории установки $INSTALL_DIR..."
            rm -rf "$INSTALL_DIR"
            echo "✅ Директория установки удалена"
            log_message "INFO" "Директория установки $INSTALL_DIR удалена"
        fi
        
        # Удаление директории резервных копий
        if [ -d "$BACKUP_DIR" ]; then
            echo "Удаление директории резервных копий $BACKUP_DIR..."
            rm -rf "$BACKUP_DIR"
            echo "✅ Директория резервных копий удалена"
            log_message "INFO" "Директория резервных копий $BACKUP_DIR удалена"
        fi
        
        log_message "INFO" "Полное удаление XRM Director завершено"
        echo ""
        echo "✅ XRM Director полностью удален!"
        show_return_to_menu_message
        return 0
    fi
    
    # Выборочное удаление (существующий код)
    echo ""
    echo "Переход к выборочному удалению..."
    
    # Проверяем наличие контейнеров двумя способами
    local ragflow_containers=$(docker ps -a --format '{{.Names}}' | grep -E "(ragflow|xinference)" || true)
    
    # Прямая проверка наличия контейнера llm-server
    local llm_server_exists=false
    if docker inspect llm-server &>/dev/null; then
        llm_server_exists=true
    fi
    
    # Убираем пустые строки и пробелы
    ragflow_containers=$(echo "$ragflow_containers" | grep -v '^$' | xargs)
    
    # Опциональное удаление контейнеров
    if [[ -n "$ragflow_containers" ]]; then
        echo ""
        echo "Найдены контейнеры RAGFlow/Xinference:"
        docker ps -a --format '{{.Names}}' | grep -E "(ragflow|xinference)" | while read -r container; do
            echo "  - $container"
        done
        
        if ask_yes_no "Хотите остановить и удалить эти контейнеры?"; then
            echo "Остановка контейнеров RAGFlow/Xinference..."
            docker ps -a --format '{{.Names}}' | grep -E "(ragflow|xinference)" | while read -r container; do
                docker stop "$container" 2>/dev/null && echo "✅ Контейнер $container остановлен"
            done
            
            echo "Удаление контейнеров RAGFlow/Xinference..."
            docker ps -a --format '{{.Names}}' | grep -E "(ragflow|xinference)" | while read -r container; do
                docker rm "$container" 2>/dev/null && echo "✅ Контейнер $container удален"
            done
            log_message "INFO" "Контейнеры RAGFlow/Xinference удалены"
        else
            echo "ℹ️  Контейнеры RAGFlow/Xinference сохранены"
        fi
    else
        echo "ℹ️  Контейнеры RAGFlow/Xinference не найдены"
    fi
    
    # Обработка llm-server отдельно
    if $llm_server_exists; then
        echo ""
        echo "Найден контейнер LLM-server:"
        echo "  - llm-server"
        
        if ask_yes_no "Хотите остановить и удалить контейнер llm-server?"; then
            echo "Остановка контейнера llm-server..."
            docker stop llm-server 2>/dev/null && echo "✅ Контейнер llm-server остановлен"
            
            echo "Удаление контейнера llm-server..."
            docker rm llm-server 2>/dev/null && echo "✅ Контейнер llm-server удален"
            log_message "INFO" "Контейнер llm-server удален"
        else
            echo "ℹ️  Контейнер llm-server сохранен"
        fi
    else
        echo "ℹ️  Контейнер llm-server не найден"
    fi
    
    # Опциональное удаление томов
    echo ""
    local all_volumes=$(docker volume ls --format '{{.Name}}' | grep -E "(ragflow|xinference)" || true)
    if [[ -n "$all_volumes" ]]; then
        echo "Найдены Docker тома:"
        echo "$all_volumes" | while read -r vol; do
            echo "  - $vol"
        done
        
        if ask_yes_no "Хотите удалить эти тома?"; then
            echo "$all_volumes" | while read -r vol; do
                if docker volume rm "$vol" 2>/dev/null; then
                    echo "✅ Том $vol удален"
                else
                    echo "❌ Не удалось удалить том $vol (возможно, используется)"
                fi
            done
            log_message "INFO" "Тома обработаны"
        else
            echo "ℹ️  Тома сохранены"
        fi
    else
        echo "ℹ️  Docker тома не найдены"
    fi
    
    # Опциональное удаление образов
    echo ""
    echo "Поиск Docker образов..."
    
    local ragflow_images=$(docker images --format '{{.Repository}}:{{.Tag}}' | grep "infiniflow/ragflow" || true)
    if [[ -n "$ragflow_images" ]]; then
        echo ""
        echo "Найдены образы RAGFlow:"
        echo "$ragflow_images" | while read -r image; do
            echo "  - $image"
        done
        
        if ask_yes_no "Хотите удалить образы RAGFlow?"; then
            echo "$ragflow_images" | while read -r image; do
                if docker rmi -f "$image" 2>/dev/null; then
                    echo "✅ Образ $image удален"
                else
                    echo "❌ Не удалось удалить образ $image"
                fi
            done
            log_message "INFO" "Образы RAGFlow обработаны"
        else
            echo "ℹ️  Образы RAGFlow сохранены"
        fi
    else
        echo "ℹ️  Образы RAGFlow не найдены"
    fi
    
    local ollama_images=$(docker images --format '{{.Repository}}:{{.Tag}}' | grep "ollama/ollama" || true)
    if [[ -n "$ollama_images" ]]; then
        echo ""
        echo "Найдены образы Ollama:"
        echo "$ollama_images" | while read -r image; do
            echo "  - $image"
        done
        
        if ask_yes_no "Хотите удалить образы Ollama?"; then
            echo "$ollama_images" | while read -r image; do
                if docker rmi -f "$image" 2>/dev/null; then
                    echo "✅ Образ $image удален"
                else
                    echo "❌ Не удалось удалить образ $image"
                fi
            done
            log_message "INFO" "Образы Ollama обработаны"
        else
            echo "ℹ️  Образы Ollama сохранены"
        fi
    else
        echo "ℹ️  Образы Ollama не найдены"
    fi
    
    local xinference_images=$(docker images --format '{{.Repository}}:{{.Tag}}' | grep "xprobe/xinference" || true)
    if [[ -n "$xinference_images" ]]; then
        echo ""
        echo "Найдены образы Xinference:"
        echo "$xinference_images" | while read -r image; do
            echo "  - $image"
        done
        
        if ask_yes_no "Хотите удалить образы Xinference?"; then
            echo "$xinference_images" | while read -r image; do
                if docker rmi -f "$image" 2>/dev/null; then
                    echo "✅ Образ $image удален"
                else
                    echo "❌ Не удалось удалить образ $image"
                fi
            done
            log_message "INFO" "Образы Xinference обработаны"
        else
            echo "ℹ️  Образы Xinference сохранены"
        fi
    else
        echo "ℹ️  Образы Xinference не найдены"
    fi
    
    # Удаление неиспользуемых образов (опционально)
    if ask_yes_no "Хотите удалить все неиспользуемые Docker образы?"; then
        echo "Очистка неиспользуемых образов..."
        docker image prune -a -f
        log_message "INFO" "Неиспользуемые образы очищены"
        echo "✅ Неиспользуемые образы очищены"
    fi
    
    # Опциональное удаление поддиректорий
    echo ""
    echo "Опциональное удаление поддиректорий в $INSTALL_DIR:"
    
    local subdirs=("docker" "history_data_agent" "kb" "utils")
    for subdir in "${subdirs[@]}"; do
        local full_path="$INSTALL_DIR/$subdir"
        if [ -d "$full_path" ]; then
            echo ""
            echo "📁 Найдена директория: $full_path"
            if ask_yes_no "Хотите удалить директорию $subdir?"; then
                rm -rf "$full_path"
                log_message "INFO" "Директория $full_path удалена"
                echo "✅ Директория $full_path удалена"
            else
                echo "ℹ️  Директория $subdir сохранена"
            fi
        fi
    done
    
    # Проверка и удаление директории с резервными копиями
    echo ""
    if [ -d "$BACKUP_DIR" ]; then
        echo "📁 Найдена директория резервных копий: $BACKUP_DIR"
        if ask_yes_no "Хотите удалить директорию с резервными копиями?"; then
            rm -rf "$BACKUP_DIR"
            log_message "INFO" "Директория резервных копий $BACKUP_DIR удалена"
            echo "✅ Директория резервных копий $BACKUP_DIR удалена"
        else
            echo "ℹ️  Директория резервных копий сохранена"
        fi
    else
        echo "ℹ️  Директория резервных копий $BACKUP_DIR не найдена"
    fi
    
    # Проверка и удаление основной директории установки (если пуста или по желанию)
    echo ""
    if [ -d "$INSTALL_DIR" ]; then
        echo "📁 Основная директория установки: $INSTALL_DIR"
        if ask_yes_no "Хотите удалить всю директорию установки $INSTALL_DIR со всем содержимым?"; then
            rm -rf "$INSTALL_DIR"
            log_message "INFO" "Директория установки $INSTALL_DIR удалена"
            echo "✅ Директория установки $INSTALL_DIR удалена"
        else
            echo "ℹ️  Директория установки сохранена"
        fi
    fi
    
    log_message "INFO" "Процесс удаления XRM Director завершен"
    echo ""
    echo "✅ Процесс удаления XRM Director завершен!"
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
    print_color "blue" "📊 Информация о созданном бэке:"
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
    if [ -f "${INITIAL_BACKUP_DIR}/${INITIAL_BACKUP_FILENAME}" ]; then
        size=$(du -h "${INITIAL_BACKUP_DIR}/${INITIAL_BACKUP_FILENAME}" | cut -f1)
        date_created=$(date -r "${INITIAL_BACKUP_DIR}/${INITIAL_BACKUP_FILENAME}" "+%Y-%m-%d %H:%M:%S")
        echo "[S] ${INITIAL_BACKUP_FILENAME} (${size}, создан: ${date_created})"
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
    if [ ${#FULL_BACKUPS[@]} -eq 0 ] && [ ! -f "${INITIAL_BACKUP_DIR}/${INITIAL_BACKUP_FILENAME}" ]; then
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
        if [ ! -f "${INITIAL_BACKUP_DIR}/${INITIAL_BACKUP_FILENAME}" ]; then
            print_color "red" "❌ Системный бэкап не найден"
            return 1
        fi
        
        print_color "yellow" "⚠️ Внимание! Восстановление из системного бэкапа перезапишет текущие данные томов."
        if ! ask_yes_no "Вы уверены?"; then
            print_color "yellow" "❌ Восстановление отменено пользователем"
            return 0
        fi
        
        # Останавливаем контейнеры
        stop_containers
        
        # Создаем временную директорию для распаковки
        TEMP_DIR=$(mktemp -d)
        print_color "blue" "📂 Распаковываем системный архив во временную директорию: ${TEMP_DIR}"
        
        # Распаковываем архив
        tar -xzf "${INITIAL_BACKUP_DIR}/${INITIAL_BACKUP_FILENAME}" -C "${TEMP_DIR}"
        
        # Находим директорию с бэкапами (обычно имеет формат ragflow_*)
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
    
    # --- Загрузка файла базы знаний и парсинг ---
   
# Функция для проверки доступности API RagFlow
wait_for_ragflow() {
    local max_attempts=90
    local attempt=1
    local wait_seconds=10
    
    echo "Ожидаем ответ от сервера API XRM Director"
    
    while [ $attempt -le $max_attempts ]; do
        echo "Попытка $attempt/$max_attempts: Проверяем доступность сервера по API..."
        
        # Пробуем выполнить простой запрос к API (например, получение списка датасетов)
        response=$(curl -s -w "%{http_code}" --max-time 5 \
            --url "$BASE_URL/api/v1/datasets?page=1&page_size=1" \
            --header "Authorization: Bearer $API_KEY")
        
        http_code=$(echo "$response" | tail -n1)
        
        # Если получили HTTP 200 и ответ содержит код 0 (успех) или просто 200 OK
        if [ "$http_code" -eq 200 ]; then
            # Проверяем, содержит ли ответ JSON с кодом 0 (для RagFlow API)
            if echo "$response" | head -n1 | grep -q '"code":0'; then
                echo "✅ Сервер API XRM Director доступен и готов к работе!"
                return 0
            elif echo "$response" | head -n1 | grep -q '"code":'; then
                # Если есть поле code, но не 0 - это может быть ошибка, но API доступен
                echo "⚠️ Сервер API XRM Director, но вернул ошибку. Продолжаем ожидание..."
            else
                # Если нет поля code, но HTTP 200 - считаем что API доступен
                echo "✅ Сервер API XRM Director доступен!"
                return 0
            fi
        fi
        
        if [ $attempt -eq $max_attempts ]; then
            echo "❌ Превышено максимальное количество попыток. Сервер API XRM Director недоступен."
            return 1
        fi
        
        echo "Сервер API XRM Director еще не доступен. Ждем $wait_seconds секунд..."
        sleep $wait_seconds
        attempt=$((attempt + 1))
    done
    
    return 1
}

# Альтернативная упрощенная версия проверки (раскомментировать если нужна)
# wait_for_ragflow_simple() {
#     echo "Ожидаем доступности RagFlow API (упрощенная проверка)..."
#     
#     while true; do
#         if curl -s --max-time 5 "$BASE_URL" > /dev/null 2>&1; then
#             echo "✅ RagFlow доступен!"
#             return 0
#         fi
#         echo "RagFlow недоступен, ждем 10 секунд..."
#         sleep 10
#     done
# }

# Функция для создания каталога, если он не существует
create_directory_if_needed() {
    local dir_path="$1"
    
    # Извлекаем путь к каталогу из полного пути к файлу
    local dir=$(dirname "$dir_path")
    
    if [ ! -d "$dir" ]; then
        echo "Создаем каталог: $dir"
        if mkdir -p "$dir"; then
            echo "Каталог успешно создан"
            return 0
        else
            echo "Ошибка: Не удалось создать каталог $dir"
            return 1
        fi
    else
        echo "Каталог уже существует: $dir"
        return 0
    fi
}

# Функция для загрузки файла
download_kb_file() {
    echo "Загрузку файла из $DOWNLOAD_URL"
    
    # Создаем каталог для файла
    if ! create_directory_if_needed "$FILE_PATH"; then
        echo "Ошибка при создании каталога"
        return 1
    fi
    
    # Загружаем файл с проверкой успешности
    if wget -O "$FILE_PATH" "$DOWNLOAD_URL"; then
        echo "✅ Файл успешно загружен в $FILE_PATH"
        
        # Проверяем размер файла (должен быть больше 0)
        file_size=$(stat -c%s "$FILE_PATH" 2>/dev/null || stat -f%z "$FILE_PATH" 2>/dev/null)
        if [ "$file_size" -gt 0 ]; then
            echo "Размер загруженного файла: $file_size байт"
            return 0
        else
            echo "Предупреждение: Загруженный файл имеет нулевой размер"
            return 0
        fi
    else
        echo "Ошибка: Не удалось загрузить файл из $DOWNLOAD_URL"
        return 1
    fi
}

# === ОСНОВНОЙ ПРОЦЕСС ===

echo "=== Процесс загрузки и парсинга файла базы знаний сервером XRM Director==="

# Загружаем файл
if download_kb_file; then
    echo "✅  Файл готов к обработке"
else
    echo "❌ Критическая ошибка: Не удалось загрузить файл базы знаний"
    exit 1
fi

echo "=== Ожидаем доступность API XRM Director==="

# Ждем пока RagFlow станет доступен
if ! wait_for_ragflow; then
    echo "❌ Не удалось дождаться доступности API XRM Director. Прерываем выполнение."
    exit 1
fi

echo "=== Переходим к загрузке в XRM Director ==="

# Проверка существования файла после загрузки
if [ ! -f "$FILE_PATH" ]; then
    echo "Ошибка: Файл не найден после загрузки: $FILE_PATH"
    exit 1
fi

echo "Uploading file: $FILE_PATH"

# Загрузка файла
UPLOAD_RESPONSE=$(curl -s --request POST \
  --url "$BASE_URL/api/v1/datasets/$DATASET_ID/documents" \
  --header "Content-Type: multipart/form-data" \
  --header "Authorization: Bearer $API_KEY" \
  --form "file=@$FILE_PATH")

# Проверка успешности загрузки и извлечение document_id
if echo "$UPLOAD_RESPONSE" | grep -q '"code":0'; then
    DOCUMENT_ID=$(echo "$UPLOAD_RESPONSE" | grep -o '"id":"[^"]*"' | head -1 | cut -d'"' -f4)
    echo "Upload successful. Document ID: $DOCUMENT_ID"
else
    echo "Upload failed. Response: $UPLOAD_RESPONSE"
    exit 1
fi

# Парсинг документа
echo "Starting document parsing..."
PARSE_RESPONSE=$(curl -s --request POST \
  --url "$BASE_URL/api/v1/datasets/$DATASET_ID/chunks" \
  --header "Content-Type: application/json" \
  --header "Authorization: Bearer $API_KEY" \
  --data "{\"document_ids\": [\"$DOCUMENT_ID\"]}")

if echo "$PARSE_RESPONSE" | grep -q '"code":0'; then
    echo "✅ Document parsing started successfully"
else
    echo "❌ Parsing failed. Response: $PARSE_RESPONSE"
    exit 1
fi

echo "✅ Процесс загрузки файла базы знаний завершен успешно! Парсинг запущен!"
# ---        
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
        if ! ask_yes_no "Вы уверены, что хотите восстановить данные из '$backup_name'?"; then
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
                
                if ask_yes_no "Вы действительно хотите удалить '$backup_name'?"; then
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
                    if ask_yes_no "Будет удалено $to_delete старых бэкапов. Продолжить?"; then
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
            if ask_yes_no "Вы действительно хотите удалить ВСЕ пользовательские бэкапы? Это действие необратимо!"; then
                rm -f "${USER_BACKUP_DIR}/${PROJECT_NAME}_full_"*.tar.gz
                rm -rf "${USER_BACKUP_DIR}/${PROJECT_NAME}_"*
                print_color "green" "✅ Все пользовательские бэкапы удалены"
            else
                print_color "yellow" "❌ Удаление отменено"
            fi
            ;;
        4)
            if [ -f "${INITIAL_BACKUP_DIR}/${INITIAL_BACKUP_FILENAME}" ]; then
                if ask_yes_no "Вы действительно хотите удалить системный (initial) бэкап?"; then
                    rm -f "${INITIAL_BACKUP_DIR}/${INITIAL_BACKUP_FILENAME}"
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
check_root
parse_cli_args "$@"

# Выполняем установку через CLI
if [ $CLI_MODE -eq 1 ]; then
    # Инициализация логирования для CLI
    init_logging
    cli_install
    exit 0
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
