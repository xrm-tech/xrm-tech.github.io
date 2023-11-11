#!/bin/bash

# "Dev", "ver. 1.1", "ver. 1.2" ...
xrm_ver="ver. 1.2.1"
# "dev", "v1_1", "v1_2" ...
ver_path="v1_2_1"
ver_url="v1.2.1"

script_dir="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
	
# Output of technical information
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

# Docker and Docker Compose version checking
check_docker() {
	if command -v docker &> /dev/null; then
		docker_version=$(docker -v | awk '{print $3}')
		echo "Версия Docker: $docker_version"
	else
		echo -e "\e[31mDocker - Не установлен.\e[0m"
	fi

	# Checking docker-compose version or docker compose version
	if docker compose version &> /dev/null; then
		docker_compose_version=$(docker compose version 2>&1 | awk '/version/ {print $4}')
	elif docker-compose version &> /dev/null; then
		docker_compose_version=$(docker-compose version 2>&1 | awk '/version/ {print $4}')
	else
		echo -e "\e[31mDocker Compose - Не установлен.\e[0m"
	fi

	if [ -n "$docker_compose_version" ]; then
		echo "Версия Docker Compose: $docker_compose_version"
	else
		echo -e "\e[31mDocker Compose - Не установлен.\e[0m"
	fi
	echo
	echo -e "\e[32mРекомендуемые версии Docker и Docker Compose\e[0m"
	echo
	echo "Для установки и работы XRM рекомендуем использовать версии:"
	echo "- Docker 20.10.24 и выше."
	echo "- Docker Compose 2.17.3 и выше."
}

docker_install() {
	# Checking the presence of Docker and installing it using the example of Ubuntu 22.04 OS (jammy)
	if command -v docker &> /dev/null; then
		docker_version=$(docker -v | awk '{print $3}')
		echo -e "\e[32mCреда контейнеризации Docker (версия $docker_version) уже установлена.\e[0m"
	else
		echo -e "\e[32mОбновляем индексы пакетов apt\e[0m"
		sudo apt update

		echo -e "\e[32mУстанавливаем пакеты, необходимые для работы apt по протоколу HTTPS\e[0m"
		sudo apt install curl software-properties-common ca-certificates apt-transport-https -y

		echo -e "\e[32mДобавляем GPG-ключ репозитория Docker\e[0m"
		curl -f -s -S -L https://download.docker.com/linux/ubuntu/gpg | sudo apt-key add -

		echo -e "\e[32mДобавляем репозиторий Docker (для Ubuntu 22.04 - Jammy)\e[0m"
		sudo add-apt-repository -y "deb [arch=amd64] https://download.docker.com/linux/ubuntu jammy stable"

		echo -e "\e[32mОбновляем индексы пакетов apt\e[0m"
		sudo apt update

		echo -e "\e[32mУстанавливаем Docker\e[0m"
		sudo apt install docker-ce -y

		echo -e "\e[32mУстанавливаем Docker Compose 2.17.3\e[0m"
		mkdir -p ~/.docker/cli-plugins/
		curl -SL https://github.com/docker/compose/releases/download/v2.17.3/docker-compose-linux-x86_64 -o ~/.docker/cli-plugins/docker-compose

		echo -e "\e[32mУстанавливаем правильные разрешения\e[0m"
		chmod +x ~/.docker/cli-plugins/docker-compose

		echo -e "\e[32mDocker и Docker Compose установлены.\e[0m"
	fi
}

# Deploying XRM
xrm_install() {
	if [ -e "./xrm_${ver_path}/tests/checkpass" ] && ! sudo docker ps -a --format '{{.Names}}' | grep -q 'xrm-'; then
		echo -e "\e[32mДиректория xrm_${ver_path} существует.\e[0m"
  		echo -e "\e[32mРазвертывание сервисов веб-приложения XRM.\e[0m"
		cd "./xrm_${ver_path}"
		sudo docker compose up -d

		# If docker compose up -d failed, try the second option under RED OS
		if [ $? -ne 0 ]; then
			echo -e "\e[33mExecuting su -c \"docker-compose up -d\"\e[0m"
			su -c "docker-compose up -d"

			# If the second option fails, then docker-compose up -d
			if [ $? -ne 0 ]; then
				echo -e "\e[33mExecuting docker-compose up -d\e[0m"
				sudo docker-compose up -d
			fi
		fi

		echo -e "\e[32mУстановка  XRM oVirt pack\e[0m"
		seconds=70
		for ((i=seconds; i>=1; i--)); do
			# Pause before installing oVirt
			printf "\r\e[32m%s\e[0m Подготовка, установка XRM oVirt начнется через: %02d сек" "$original_text" "$i"
			# Wait 1 second
			sleep 1
		done

		sudo docker exec -it xrm-client st2 pack install "https://github.com/xrm-tech/xrm-ovirt-st2=xrm_v1.2"
		echo -e "\e[32mУстановка XRM $xrm_ver завершена.\e[0m"
	else
		echo

		if ! command -v docker &> /dev/null; then
			echo -e "\e[31mXRM $xrm_ver не может быть установлен, не найдена среда контейнеризации Docker.\e[0m"
			exit 1
		fi

		if sudo docker ps -a --format '{{.Names}}' | grep -q 'xrm-'; then
			echo -e "\e[32mXRM $xrm_ver уже установлен.\e[0m"
		else
			echo -e "\e[32mСоздание директории xrm_${ver_path} для X Recovery Manager\e[0m"
   			cd "$script_dir"
			sudo mkdir -p "./xrm_${ver_path}" && cd "./xrm_${ver_path}"
			echo -e "\e[32mЗагрузка архива XRM $xrm_ver xrm-docker_${ver_path}.tar.gz\e[0m"
			sudo wget "https://files.x-rm.ru/releases/$ver_url/xrm-docker_${ver_path}.tar.gz"
			echo -e "\e[32mИзвлечение архива xrm-docker_${ver_path}.tar.gz в директорию xrm_${ver_path}\e[0m"
			sudo tar -zxvf "xrm-docker_${ver_path}.tar.gz"
			echo -e "\e[32mРазвертывание сервисов веб-приложения XRM.\e[0m"
			sudo docker compose up -d

			# If docker compose up -d failed, try the second option under RED OS
			if [ $? -ne 0 ]; then
				echo -e "\e[33mExecuting su -c \"docker-compose up -d\"\e[0m"
				su -c "docker-compose up -d"

				# If the second option fails, then docker-compose up -d
				if [ $? -ne 0 ]; then
					echo -e "\e[33mExecuting docker-compose up -d\e[0m"
					sudo docker-compose up -d
				fi
			fi

			echo -e "\e[32mУстановка  XRM oVirt pack\e[0m"
			seconds=70
			for ((i=seconds; i>=1; i--)); do
				# Pause before installing oVirt
				printf "\r\e[32m%s\e[0m Подготовка, установка XRM oVirt начнется через: %02d сек" "$original_text" "$i"
				# Wait 1 second
				sleep 1
			done

			sudo docker exec -it xrm-client st2 pack install "https://github.com/xrm-tech/xrm-ovirt-st2=xrm_v1.2"
			echo -e "\e[32mУстановка XRM $xrm_ver завершена.\e[0m"
		fi
	fi
}

# Restarting XRM containers
xrm_restart() {
	# Checking the presence of a directory xrm_${ver_path}
	if [ ! -d "./xrm_${ver_path}" ]; then
		echo -e "\e[31mXRM $xrm_ver не установлен.\e[0m"
		return
	fi

	cd "./xrm_${ver_path}"

	sudo docker compose down || sudo docker-compose down || su -c "docker-compose down"
	sudo docker compose up -d || sudo docker-compose up -d || su -c "docker-compose up -d"

	echo -e "\e[32mКонтейнеры XRM перезапущены.\e[0m"
}

# Removing XRM
xrm_clear() {
	if sudo docker ps -a --format '{{.Names}}' | grep -q 'xrm-'; then
		echo -e "\e[32mОстановка и удаление контейнеров, связанных с XRM.\e[0m"
		sudo docker stop $(sudo docker ps -a | grep "xrm-" | awk '{print $1}') && sudo docker rm $(sudo docker ps -a | grep "xrm-" | awk '{print $1}')
		echo -e "\e[32mУдаление образов контейнеров, связанных с XRM.\e[0m"
		sudo docker images | grep -E "xrm|stackstorm" | awk '{print $3}' | xargs sudo docker rmi
		echo -e "\e[32mУдаление volume (dangling) томов, не привязанных к контейнерам.\e[0m"
		sudo docker volume rm $(sudo docker volume ls -qf dangling=true)
		echo -e "\e[32mУдаление директории xrm_${ver_path}, файлов, связанных с XRM.\e[0m"
  		cd "$script_dir"
		sudo rm -rf "./xrm_${ver_path}"
		echo -e "\e[32mУдаление завершено.\e[0m"
	else
		echo -e "\e[31mXRM не установлен.\e[0m"
	fi
}

# Setting a password
set_password() {
	if [ ! -d "./xrm_${ver_path}" ]; then
 		cd "$script_dir"
		sudo mkdir "./xrm_${ver_path}" && cd "./xrm_${ver_path}"
		sudo wget "https://files.x-rm.ru/releases/$ver_url/xrm-docker_${ver_path}.tar.gz"
		sudo tar -zxvf "xrm-docker_${ver_path}.tar.gz"
		touch "./tests/checkpass"
		cd ..
		clear
	else
		echo
	fi

	if [ -d "./xrm_${ver_path}" ]; then
 		echo -e "\e[32mУстановить/Изменить пароль администратора XRM\e[0m"
   		echo
		read -p "Введите имя пользователя: " login
		read -s -p "Введите пароль: " password
		echo
		while true; do
			read -s -p "Повторите пароль: " password_confirmation
			echo
			if [ "$password" = "$password_confirmation" ]; then
				break
			else
				echo -e "\e[31mПароли не совпадают. Попробуйте снова.\e[0m"
				read -s -p "Введите пароль: " password
				echo
			fi
		done

		if [ -n "$login" ] && [ -n "$password" ]; then
			hashed_password=$(openssl passwd -apr1 "$password")
			echo "$login:$hashed_password" > "./xrm_${ver_path}/files/htpasswd"
			echo -e "\e[32mИмя пользователя и пароль успешно установлены/изменены.\e[0m"
			sed -i "s/^username = .*/username = $login/" "./xrm_${ver_path}/files/st2-cli.conf"
			sed -i "s/^password = .*/password = $password/" "./xrm_${ver_path}/files/st2-cli.conf"
		else
			echo -e "\e[31mПароль не задан. Имя пользователя/пароль должны содержать минимум 1 символ.\e[0m"
		fi
	else
		echo -e "\e[31mXRM не установлен.\e[0m"
		echo -e "\e[32mИзменить или добавить учетную запись вы можете только после установки XRM.\e[0m"
	fi
}

# Checking for command line arguments
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

# Main menu cycle
while true; do
	clear
	echo -e "\e[32m##  ##   #####   ##   ##\e[0m"
	echo -e "\e[32m ####    ##  ##  ### ###\e[0m"
	echo -e "\e[32m  ##     #####   ## # ##\e[0m"
	echo -e "\e[32m ####    ####    ##   ##\e[0m"
	echo -e "\e[32m##  ##   ## ##   ##   ##\e[0m"
	echo -e "\e[97mX Recovery Manager (XRM) $xrm_ver\e[0m"
	echo
	echo "Меню:"
	echo
	echo "1. Системные требования"
	echo "2. Информация об установленных Docker / Docker Compose"
	echo "3. Установить Docker / Docker Compose (Ubuntu)"
	echo "4. Установить XRM $xrm_ver"
	echo "5. Перезапустить XRM $xrm_ver"
	echo "6. Удалить XRM $xrm_ver"
	echo "7. Установить пароль администратора XRM"
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
			echo -e "\e[32mУстановить/Изменить пароль администратора XRM\e[0m"
			echo
			set_password
			echo
			read -p "Нажмите Enter, чтобы вернуться в меню..."
			;;
		8)
			clear
			exit
			;;
		*)
			echo -e "\e[31mНеверный выбор, попробуйте снова.\e[0m"
			sleep 2
			;;
	esac
done
