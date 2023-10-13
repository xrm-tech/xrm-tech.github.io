#!/bin/bash
 
# "Dev", "ver. 1.1", "ver. 1.2" ...
xrm_ver="Dev"
# "dev", "v1_1", "v1_2" ...
ver_path="dev"
	
# Функция для вывода тех информации
get_pc_info() {
    os=$(lsb_release -si)
    release=$(lsb_release -sr)
    memory_gb=$(free -g | awk 'NR==2 {print $2}')
    free_space=$(df -h / | awk 'NR==2 {print $4}')
	architecture=$(uname -m)
	echo "Операционная система: $os $release"
    echo "Архитектура процессора: $architecture"
	echo "Количество ядер процессора: $(nproc)"
	echo "Объем оперативной памяти: $memory_gb GB"
    echo "Свободное место на жестком диске: $free_space"
	echo
	echo -e "\e[32mТехнические требования для установки и работы XRM\e[0m"
	echo
    echo "Поддерживаемые операционные системы для установки:"
	echo
	echo "- Ubuntu 18, 20, 22 / Debian 10, 11, 12"
	echo "- RHEL 8, 9 / CentOS 8, 9/ RockyLinux 8 / Oracle Linux 8, 9"
	echo "- Astra Linux (CE, SE) 1.6, 1.7"
	echo "- РЕД ОС 7.2, 7.3 / AlterOS 8 / Rosa Enterprise Linux"
	echo "- ОС АЛЬТ 9, 10"
	echo
	echo "Стандартный виртуальный сервер архитектуры: x86/x86-64"
	echo "Количество ядер vCPU: 2"
	echo "Количество оперативной памяти: 2 ГБ"
	echo "Свободное место на жестком диске: 10 ГБ"
	}

# Функция проверки версий Docker и Docker Compose
check_docker() {
    if command -v docker &> /dev/null; then
        docker_version=$(docker -v | awk '{print $3}')
        echo "Версия Docker: $docker_version"
    else
        echo "Docker - Не установлен"
    fi

 # Проверка docker-compose version или docker compose version
if docker compose version &> /dev/null; then
    docker_compose_version=$(docker compose version 2>&1 | awk '/version/ {print $4}')
elif docker-compose version &> /dev/null; then
    docker_compose_version=$(docker-compose version 2>&1 | awk '/version/ {print $4}')
else
    echo "Docker Compose - Не установлен"
fi

if [ -n "$docker_compose_version" ]; then
    echo "Версия Docker Compose: $docker_compose_version"
else
    echo "Docker Compose - Не установлен"
fi
	echo
    echo -e "\e[32mРекомендуемые версии Docker и Docker Compose\e[0m"
	echo
    echo "Для установки и работы XRM рекомендуем использовать версии:"
	echo "- Docker 20.10.24 и выше."
	echo "- Docker Compose 2.17.3 и выше."
}

docker_install() {
# Проверка наличия Docker и его установка на примере ОС Ubuntu 22.04 (jammy) 
if command -v docker &> /dev/null; then
    docker_version=$(docker -v | awk '{print $3}')
    echo -e "\e[32mCреда контейнеризации Docker (версия $docker_version) уже установлена.\e[0m"
else
    echo -e "\e[32m1. Обновляем индексы пакетов apt\e[0m"
    sudo apt update

    echo -e "\e[32m2. Устанавливаем пакеты, необходимые для работы apt по протоколу HTTPS\e[0m"
    sudo apt install curl software-properties-common ca-certificates apt-transport-https -y

    echo -e "\e[32m3. Добавляем GPG-ключ репозитория Docker\e[0m"
    curl -f -s -S -L https://download.docker.com/linux/ubuntu/gpg | sudo apt-key add -

    echo -e "\e[32m4. Добавляем репозиторий Docker (для Ubuntu 22.04 - Jammy)\e[0m"
    sudo add-apt-repository -y "deb [arch=amd64] https://download.docker.com/linux/ubuntu jammy stable"

    echo -e "\e[32m5. Обновляем индексы пакетов apt\e[0m"
    sudo apt update

    echo -e "\e[32m6. Устанавливаем Docker\e[0m"
    sudo apt install docker-ce -y

    echo -e "\e[32mУстанавливаем Docker Compose\e[0m"
    echo -e "\e[32m7. Загружаем Docker Compose версии 2.17.3\e[0m"
    mkdir -p ~/.docker/cli-plugins/
    curl -SL https://github.com/docker/compose/releases/download/v2.17.3/docker-compose-linux-x86_64 -o ~/.docker/cli-plugins/docker-compose

    echo -e "\e[32m8. Устанавливаем правильные разрешения\e[0m"
    chmod +x ~/.docker/cli-plugins/docker-compose

    echo -e "\e[32mDocker и Docker Compose установлены.\e[0m"
fi
}

# Развертывание XRM Dev
xrm_install() {
if ! command -v docker &> /dev/null; then
    echo -e "\e[31mXRM $xrm_ver не может быть установлен, не найдена среда контейнеризации Docker.\e[0m"
else
    if sudo docker ps -a --format '{{.Names}}' | grep -q 'xrm-'; then
        echo -e "\e[32mXRM $xrm_ver уже установлен.\e[0m"
    else
        echo -e "\e[32m1. Создание директории $xrm_ver для X Recovery Manager\e[0m"
        sudo mkdir ./xrm_${ver_path} && cd ./xrm_${ver_path}
        echo -e "\e[32m2. Загрузка архива XRM $xrm_ver xrm-docker_${ver_path}.tar.gz\e[0m"
        sudo wget https://files.x-rm.ru/releases/${ver_path}/xrm-docker_${ver_path}.tar.gz
        echo -e "\e[32m3. Извлечение архива xrm-docker_${ver_path}.tar.gz в директорию xrm_${ver_path}\e[0m"
        sudo tar -zxvf xrm-docker_${ver_path}.tar.gz
	echo -e "\e[32m4. Развертывание сервисов веб-приложения XRM.\e[0m"
        sudo docker compose up -d

        # Если не удалось выполнить docker compose up -d, попробовать второй вариант под РЕД ОС
        if [ $? -ne 0 ]; then
            echo -e "\e[33mВыполняю su -c \"docker-compose up -d\"\e[0m"
            su -c "docker-compose up -d"

            # Если и второй вариант не удался, то docker-compose up -d
            if [ $? -ne 0 ]; then
                echo -e "\e[33mВыполняю docker-compose up -d\e[0m"
                sudo docker-compose up -d
            fi
        fi
        echo -e "\e[32m5. Установка  XRM oVirt pack\e[0m"
		seconds=70
for ((i=seconds; i>=1; i--)); do
    # Пауза перед установкой oVirt
    printf "\r\e[32m%s\e[0m Подготовка, установка XRM oVirt начнется через: %02d сек" "$original_text" "$i"
    # Ждем 1 секунду
    sleep 1
done
	    sudo docker exec -it xrm-client st2 pack install https://github.com/xrm-tech/xrm-ovirt-st2=master
		echo -e "\e[32mУстановка XRM $xrm_ver завершена.\e[0m"
    fi
fi
}

# Удаление XRM
xrm_clear() {
if sudo docker ps -a --format '{{.Names}}' | grep -q 'xrm-'; then
    echo -e "\e[32m1. Остановка и удаление контейнеров связанных с XRM.\e[0m"
    sudo docker stop $(sudo docker ps -a | grep "xrm-" | awk '{print $1}') && sudo docker rm $(sudo docker ps -a | grep "xrm-" | awk '{print $1}')
    echo -e "\e[32m2. Удаление образов контейнеров связанных с XRM.\e[0m"
    sudo docker images | grep -E "xrm|stackstorm" | awk '{print $3}' | xargs sudo docker rmi
    echo -e "\e[32m3. Удаление volume (dangling) томов, не привязаных к контейнерам.\e[0m"
    sudo docker volume rm $(sudo docker volume ls -qf dangling=true)
    echo -e "\e[32m4. Удаление директории xrm_${ver_path}, файлов связанных с XRM.\e[0m"
    sudo rm -rf ./xrm_${ver_path}
    echo -e "\e[32mУдаление завершено.\e[0m"
else
    echo -e "\e[32mXRM не установлен.\e[0m"
fi
}

# Перезапуск контейнеров XRM
xrm_restart() {
# Проверка наличия директории xrm_${ver_path}
if [ ! -d "./xrm_${ver_path}" ]; then
    echo "XRM $xrm_ver не установлен."
    return
fi

# Переход в директорию
cd ./xrm_${ver_path}

# Операции по перезапуску контейнеров
sudo docker compose down || sudo docker-compose down || su -c "docker-compose down"
sudo docker compose up -d || sudo docker-compose up -d || su -c "docker-compose up -d"

echo "Произведен перезапуск контейнеров XRM."
}

# Функция установки пароля
set_password () {
    if [ -d "./xrm_${ver_path}" ]; then
        read -p "Введите имя пользователя: " login
        read -s -p "Введите пароль: " password
        echo

        if [ -n "$login" ] && [ -n "$password" ]; then
            hashed_password=$(openssl passwd -apr1 "$password")
            echo "$login:$hashed_password" > "./xrm_${ver_path}/files/htpasswd"
            echo "Имя пользователя и пароль успешно установлены/изменены."
        else
            echo "Имя пользователя и пароль должны содержать хотя бы по одному символу."
        fi
    else
        echo -e "\e[32mXRM не установлен.\e[0m"
        echo -e "\e[32mИзменить или добавить учетную запись вы можете только после установки XRM.\e[0m"
    fi
}

# Проверка наличия аргументов командной строки
if [ $# -eq 1 ]; then
	choice="$1"
	case $choice in
		1)
			get_pc_info
			exit
			;;
		2)
			check_docker
			exit
			;;
		3)
			docker_install
			exit
			;;
		4)
			xrm_install
			exit
			;;
		5)
			xrm_restart
			exit
			;;
		6)
			xrm_clear
			exit
			;;
		7)
			set_password
			exit
			;;
		*)
			echo "Неверный аргумент. Допустимые аргументы: 1, 2, 3, 4, 5, 6"
			exit 1
			;;
	esac
fi

# Основной цикл меню
while true; do
	clear
	echo -e "\e[32m##  ##   #####	##   ##\e[0m"
	echo -e "\e[32m ####	##  ##   ### ###\e[0m"
	echo -e "\e[32m  ##	 #####	## # ##\e[0m"
	echo -e "\e[32m ####	####	 ##   ##\e[0m"
	echo -e "\e[32m##  ##   ## ##	##   ##\e[0m"
	echo -e "\e[32mX Recovery Manager (XRM) $xrm_ver\e[0m"
	echo
	echo "Меню:"
	echo
	echo "1. Системные требования"
	echo "2. Информация об установленных Docker / Docker Compose"
	echo "3. Установить Docker / Docker Compose (Ubuntu)"
	echo "4. Установить XRM $xrm_ver"
	echo "5. Перезапустить XRM $xrm_ver"
	echo "6. Удалить XRM $xrm_ver"
	echo "7. Задать пароль на вход в XRM"
	echo "8. Выйти"
	read -p "Выберите пункт меню: " choice

	case $choice in
		1)
			clear
			echo -e "\e[32mХарактеристики вашей системы:\e[0m"
			echo
			get_pc_info	
			echo			
			read -p "Нажмите Enter, чтобы вернуться в меню..."
			;;
		2)
			clear
			echo -e "\e[32mИнформация об установленных Docker / Docker Compose:\e[0m"
			echo
			check_docker
			echo
			read -p "Нажмите Enter, чтобы вернуться в меню..."
			;;
		3)
			clear
			echo -e "\e[32mУстановка Docker / Docker Compose на ОС Ubuntu 22.04 (jammy)\e[0m"
			echo
			docker_install
			echo
			read -p "Нажмите Enter, чтобы вернуться в меню..."
			;;
		4)
			clear
			echo -e "\e[32mУстановка XRM $xrm_ver в среде контейнеризации Docker.\e[0m"
			echo
			xrm_install
			echo
			read -p "Нажмите Enter, чтобы вернуться в меню..."
			;;
		5)
			clear
			echo -e "\e[32mПерезапуск XRM $xrm_ver в среде контейнеризации Docker.\e[0m"
			echo
			xrm_restart
			echo
			read -p "Нажмите Enter, чтобы вернуться в меню..."
			;;
		6)
			clear
			echo -e "\e[32mУдаление XRM $xrm_ver из среды контейнеризации Docker.\e[0m"
			echo
			xrm_clear
			echo
			read -p "Нажмите Enter, чтобы вернуться в меню..."
			;;
		7)
			clear
			echo -e "\e[32mЗадать пароль на вход в XRM.\e[0m"
			echo
			set_password
			echo
			read -p "Нажмите Enter, чтобы вернуться в меню..."
			;;
		8)
			echo "Вы вышли из меню установки XRM"
			exit
			;;
		*)
			echo "Неверный выбор. Пожалуйста, выберите снова."
			;;
	esac

done
