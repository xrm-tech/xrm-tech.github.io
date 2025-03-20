#!/bin/bash
# filepath: /home/user/ragflow/docker/backup_volumes.sh

# Настройки
BACKUP_DIR="/home/dinar/backups"
DATE_FORMAT=$(date +%Y-%m-%d_%H-%M-%S)
PROJECT_NAME="xrm_dir"
COMPOSE_FILE="/opt/xrm-director/docker/docker-compose.yml"

# Создаем директорию для бэкапов, если ее нет
mkdir -p ${BACKUP_DIR}

# Функция для отображения цветного текста
print_color() {
    COLOR=$1
    TEXT=$2
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
    cd $(dirname ${COMPOSE_FILE})
    docker compose -f $(basename ${COMPOSE_FILE}) down
}

# Запуск всех контейнеров
start_containers() {
    print_color "green" "▶️ Запускаем контейнеры..."
    cd $(dirname ${COMPOSE_FILE})
    docker compose -f $(basename ${COMPOSE_FILE}) up -d
}

# Создание резервной копии
create_backup() {
    print_color "blue" "🚀 Начинаем резервное копирование томов ${PROJECT_NAME} (${DATE_FORMAT})"
    
    # Останавливаем контейнеры
    stop_containers
    
    # Получаем список томов
    get_volumes
    
    # Счетчик успешных архиваций
    SUCCESS_COUNT=0
    
    # Создаем директорию для текущего бэкапа
    BACKUP_SUBDIR="${BACKUP_DIR}/${PROJECT_NAME}_${DATE_FORMAT}"
    mkdir -p ${BACKUP_SUBDIR}
    
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
    
    # Создаем метаинформацию о бэкапе
    echo "Дата создания: $(date)" > ${BACKUP_SUBDIR}/backup_info.txt
    echo "Версия Docker: $(docker --version)" >> ${BACKUP_SUBDIR}/backup_info.txt
    echo "Контейнеры:" >> ${BACKUP_SUBDIR}/backup_info.txt
    docker ps -a >> ${BACKUP_SUBDIR}/backup_info.txt
    
    # Запускаем контейнеры снова
    start_containers
    
    # Выводим информацию о созданных архивах
    print_color "blue" "📊 Информация о созданном бэкапе:"
    if [ $SUCCESS_COUNT -gt 0 ]; then
      ls -lh ${BACKUP_SUBDIR}/*.tar.gz 2>/dev/null
      print_color "green" "🎉 Успешно архивировано томов: ${SUCCESS_COUNT} из ${#VOLUMES[@]}"
      print_color "green" "📂 Бэкап сохранен в: ${BACKUP_SUBDIR}"
      
      # Создаем общий архив для удобства переноса
      tar -czf "${BACKUP_DIR}/${PROJECT_NAME}_full_${DATE_FORMAT}.tar.gz" -C ${BACKUP_DIR} $(basename ${BACKUP_SUBDIR})
      print_color "green" "📦 Создан полный архив: ${BACKUP_DIR}/${PROJECT_NAME}_full_${DATE_FORMAT}.tar.gz"
    else
      print_color "red" "⚠️ Не удалось создать ни одного архива"
      rm -rf ${BACKUP_SUBDIR}
    fi
}

# Получение списка доступных бэкапов
list_backups() {
    print_color "blue" "📋 Доступные полные бэкапы:"
    
    # Ищем полные архивы
    FULL_BACKUPS=($(find ${BACKUP_DIR} -maxdepth 1 -name "${PROJECT_NAME}_full_*.tar.gz" | sort -r))
    
    if [ ${#FULL_BACKUPS[@]} -eq 0 ]; then
        print_color "yellow" "⚠️ Полные архивы не найдены"
    else
        echo "Найдено ${#FULL_BACKUPS[@]} архивов:"
        for i in "${!FULL_BACKUPS[@]}"; do
            filename=$(basename "${FULL_BACKUPS[$i]}")
            size=$(du -h "${FULL_BACKUPS[$i]}" | cut -f1)
            date_created=$(date -r "${FULL_BACKUPS[$i]}" "+%Y-%m-%d %H:%M:%S")
            echo "[$i] ${filename} (${size}, создан: ${date_created})"
        done
    fi
    
    # Ищем директории с бэкапами
    DIR_BACKUPS=($(find ${BACKUP_DIR} -maxdepth 1 -type d -name "${PROJECT_NAME}_*" | sort -r))
    
    if [ ${#DIR_BACKUPS[@]} -gt 1 ]; then  # >1 потому что сам BACKUP_DIR тоже будет в списке
        print_color "blue" "📂 Директории с отдельными бэкапами томов:"
        for i in "${!DIR_BACKUPS[@]}"; do
            if [ "${DIR_BACKUPS[$i]}" != "${BACKUP_DIR}" ]; then
                dirname=$(basename "${DIR_BACKUPS[$i]}")
                echo "[$i] ${dirname}"
            fi
        done
    fi
}

# Восстановление из бэкапа
restore_backup() {
    print_color "blue" "🔄 Восстановление из бэкапа"
    
    # Показываем доступные бэкапы
    list_backups
    
    if [ ${#FULL_BACKUPS[@]} -eq 0 ]; then
        print_color "red" "❌ Нет доступных бэкапов для восстановления"
        return 1
    fi
    
    # Запрашиваем номер бэкапа для восстановления
    read -p "Введите номер бэкапа для восстановления или 'q' для отмены: " backup_number
    
    if [ "$backup_number" == "q" ]; then
        print_color "yellow" "❌ Восстановление отменено пользователем"
        return 0
    fi
    
    # Проверяем корректность ввода
    if ! [[ "$backup_number" =~ ^[0-9]+$ ]] || [ $backup_number -ge ${#FULL_BACKUPS[@]} ]; then
        print_color "red" "❌ Некорректный номер бэкапа"
        return 1
    fi
    
    # Выбранный бэкап
    selected_backup="${FULL_BACKUPS[$backup_number]}"
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
        print_color "green" "🎉 Успешно восстановлено томов: $SUCCESS_COUNT из $VOLUMES_TOTAL"
    else
        print_color "red" "❌ Не удалось восстановить ни одного тома"
    fi
}

# Управление бэкапами (удаление старых)
manage_backups() {
    print_color "blue" "📊 Управление резервными копиями"
    
    # Показываем доступные бэкапы
    list_backups
    
    echo ""
    echo "Выберите действие:"
    echo "1. Удалить выбранный бэкап"
    echo "2. Оставить только последние N бэкапов"
    echo "3. Удалить все бэкапы"
    echo "4. Вернуться в главное меню"
    
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
                    if [ -d "${BACKUP_DIR}/${backup_dir_name}" ]; then
                        rm -rf "${BACKUP_DIR}/${backup_dir_name}"
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
                            if [ -d "${BACKUP_DIR}/${backup_dir_name}" ]; then
                                rm -rf "${BACKUP_DIR}/${backup_dir_name}"
                            fi
                            
                            print_color "green" "✅ Бэкап '$backup_name' удален"
                        done
                        print_color "green" "✅ Удаление старых бэкапов завершено"
                    fi
                fi
            fi
            ;;
        3)
            read -p "Вы действительно хотите удалить ВСЕ бэкапы? Это действие необратимо! (yes/n): " confirm
            if [ "$confirm" == "yes" ]; then
                rm -f ${BACKUP_DIR}/${PROJECT_NAME}_full_*.tar.gz
                rm -rf ${BACKUP_DIR}/${PROJECT_NAME}_20*
                print_color "green" "✅ Все бэкапы удалены"
            else
                print_color "yellow" "❌ Удаление отменено"
            fi
            ;;
        4)
            return
            ;;
        *)
            print_color "red" "❌ Некорректный выбор"
            ;;
    esac
}

# Главное меню
show_menu() {
    clear
    echo "======================================================"
    print_color "blue" "     🛠️  Утилита управления томами RagFlow 🛠️"
    echo "======================================================"
    echo ""
    echo "1. Создать резервную копию всех томов"
    echo "2. Просмотреть доступные резервные копии"
    echo "3. Восстановить из резервной копии"
    echo "4. Управление резервными копиями"
    echo "0. Выход"
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
            print_color "green" "👋 До свидания!"
            exit 0
            ;;
        *)
            print_color "red" "❌ Некорректный выбор"
            read -p "Нажмите Enter для продолжения..."
            ;;
    esac
}

# Основная функция
main() {
    check_docker
    
    # Интерактивный режим
    while true; do
        show_menu
    done
}

# Запускаем основную функцию
main