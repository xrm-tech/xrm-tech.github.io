#!/usr/bin/env python3
# -*- coding: utf-8 -*-

import requests
import os
import json
import re
import urllib3
import sys

# ============= КОНФИГУРАЦИЯ =============
# Параметры подключения к серверу
HOST = "37.187.132.140:15043"

# Пути для сохранения файлов
# Используем директорию в домашнем каталоге пользователя
HOME_DIR = os.path.expanduser("~")
LOGS_DIR = os.path.join(HOME_DIR, "uds_logs")

# Куки для HTTP-запросов (измените на свои значения)
COOKIES = {
    'uds': 'QTKdZrtZDr3qb3KTRoyGxHvP0lNaA22yGf91DmFinmuc5pF1',
    'csrftoken': 'XIFv2gzw2FoDFFv500I3gHv8IpIwSsq8BDLGDxpeKQCiWt3TvtrCmbrHbr98srmV',
    'sessionid': 'rz6ia9kdv9yee2nzsfuntuhyjeav9dnq',
    'cookieconsent_status': 'dismiss'
}

# URLs для запросов
BASE_URL = f"https://{HOST}"
AUTH_URL = f"{BASE_URL}/uds/rest/auth/login"
LOGS_PAGE_URL = f"{BASE_URL}/uds/tools/logs"
DOWNLOAD_URL = f"{BASE_URL}/hostvm/utility/download"
ALT_DOWNLOAD_URL_TEMPLATE = f"{BASE_URL}/uds/rest/component/server/log/"

# Заголовки для HTTP-запросов
HEADERS = {
    "Accept": "text/html,application/xhtml+xml,application/xml;q=0.9,image/avif,image/webp,*/*;q=0.8",
    "User-Agent": "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/134.0.0.0 Safari/537.36"
}

# Словарь доступных логов
AVAILABLE_LOGS = {
    "auth.log": "Журнал событий аутентификации пользователей",
    "services.log": "Журнал событий сервис-провайдеров",
    "sql.log": "Журнал базы данных",
    "trace.log": "Журнал проверок доступности сервисов",
    "uds.log": "Основной журнал брокера",
    "use.log": "Журнал подключений пользователей к сервисам",
    "workers.log": "Журнал работы процессов"
}

# Список файлов логов для скачивания
LOG_FILES = [
    "auth.log",
    "services.log",
    "sql.log",
    "trace.log",
    "uds.log",
    "use.log",
    "workers.log"
]

# Отключаем предупреждения о SSL
urllib3.disable_warnings(urllib3.exceptions.InsecureRequestWarning)
# =======================================

# Пытаемся импортировать BeautifulSoup, если не получается - предлагаем установить
try:
    from bs4 import BeautifulSoup
    BEAUTIFULSOUP_AVAILABLE = True
except ImportError:
    print("ВНИМАНИЕ: Модуль bs4 (BeautifulSoup) не установлен.")
    print("Для установки выполните команду: pip install beautifulsoup4")
    print("Продолжаем работу с ограниченной функциональностью...\n")
    BEAUTIFULSOUP_AVAILABLE = False

def download_log(host=HOST, username=None, password=None, log_file="auth.log", cookies=COOKIES, logs_dir=LOGS_DIR):
    """
    Скачивает лог-файл с сервера OpenUDS.
    
    Args:
        host: Хост сервера (например, "37.187.132.140:15043")
        username: Имя пользователя (не требуется при использовании cookies)
        password: Пароль (не требуется при использовании cookies)
        log_file: Имя файла лога для скачивания
        cookies: Словарь с cookies для аутентификации
        logs_dir: Директория для сохранения логов
        
    Returns:
        str: Путь к сохраненному файлу или None в случае ошибки
    """
    session = requests.Session()
    session.verify = False  # Отключаем проверку SSL
    
    if cookies:
        # Используем cookie-аутентификацию
        print(f"Авторизация на {host} с использованием cookies")
        for key, value in cookies.items():
            session.cookies.set(key, value, domain=host.split(':')[0])
        
        # Получаем CSRF токен из cookies, если он там есть
        csrf_token = cookies.get('csrftoken')
        if csrf_token:
            print(f"Используем CSRF токен из cookies: {csrf_token[:10]}...")
    else:
        # Шаг 1: Аутентификация через логин/пароль
        print(f"Авторизация на {host} с пользователем {username}")
        auth_url = f"https://{host}/uds/rest/auth/login"
        auth_data = {
            "auth": "adm",
            "username": username,
            "password": password
        }
        
        auth_response = session.post(
            auth_url,
            headers={"Content-Type": "application/json"},
            json=auth_data
        )
        
        if auth_response.status_code != 200:
            print(f"Ошибка аутентификации: {auth_response.status_code}")
            print(auth_response.text)
            return None
        
        auth_result = auth_response.json()
        if auth_result.get("result") != "ok" or not auth_result.get("token"):
            print(f"Неверный ответ при аутентификации: {auth_result}")
            return None
        
        token = auth_result["token"]
        print(f"Успешная авторизация, получен токен: {token[:10]}...")

        # Шаг 2: Получаем CSRF токен
        print("Получаем CSRF токен...")
        logs_page_url = LOGS_PAGE_URL
        logs_page = session.get(logs_page_url)
        
        csrf_token = session.cookies.get('csrftoken')
        if not csrf_token:
            print("CSRF токен не найден!")
            return None
        
        print(f"Получен CSRF токен: {csrf_token[:10]}...")
    
    # Шаг 3: Скачиваем файл логов
    print(f"Доступ к странице логов: {LOGS_PAGE_URL}")
    
    # Формируем заголовки
    headers = HEADERS.copy()
    
    # Добавляем X-CSRFToken если есть
    csrf_token = session.cookies.get('csrftoken')
    if csrf_token:
        headers["X-CSRFToken"] = csrf_token
    
    # Выполняем GET-запрос для получения страницы с логами
    response = session.get(
        LOGS_PAGE_URL,
        headers=headers
    )
    
    # Проверяем результат
    if response.status_code != 200:
        print(f"Ошибка доступа к странице логов: HTTP {response.status_code}")
        print(response.text[:200])
        return None
    
    # Убираем сохранение HTML страницы логов
    print("Анализируем страницу логов...")
    
    # Инициализируем переменные
    target_link = None
    download_links = {}
    
    # Парсим HTML в зависимости от наличия библиотеки BeautifulSoup
    if BEAUTIFULSOUP_AVAILABLE:
        # Используем BeautifulSoup для парсинга HTML
        soup = BeautifulSoup(response.text, 'html.parser')
        
        # Ищем кнопки и ссылки, которые могут быть связаны со скачиванием логов
        print("Ищем ссылки на файлы логов...")
        buttons = soup.find_all('button')
        links = soup.find_all('a')
        
        # Получаем информацию о доступных кнопках/ссылках
        for button in buttons:
            print(f"Найдена кнопка: {button.get_text().strip()} (id={button.get('id', 'нет')}, class={button.get('class', 'нет')})")
        
        for link in links:
            href = link.get('href', '')
            text = link.get_text().strip()
            if any(log_name in href or log_name in text for log_name in AVAILABLE_LOGS.keys()):
                print(f"Найдена возможная ссылка на лог: {text} -> {href}")
                download_links[href] = text
    else:
        # Используем регулярные выражения для поиска ссылок
        print("Ищем ссылки на файлы логов с помощью регулярных выражений...")
        
        # Ищем кнопки для отображения
        buttons = re.findall(r'<button[^>]*>([^<]*)</button>', response.text)
        for button in buttons:
            if button.strip():
                print(f"Найдена кнопка: {button.strip()}")
        
        # Ищем ссылки на логи
        link_pattern = r'<a[^>]*href="([^"]*)"[^>]*>([^<]*)</a>'
        links = re.findall(link_pattern, response.text)
        for href, text in links:
            if any(log_name in href or log_name in text for log_name in AVAILABLE_LOGS.keys()):
                text = text.strip()
                print(f"Найдена возможная ссылка на лог: {text} -> {href}")
                download_links[href] = text
    
    # Пытаемся найти ссылку на конкретный лог по имени файла
    for href, text in download_links.items():
        if log_file in href or log_file in text:
            target_link = href
            print(f"Найдена ссылка на запрошенный лог {log_file}: {href}")
            break
    
    if not target_link:
        print(f"Не найдена прямая ссылка на {log_file}, пробуем прямой запрос на скачивание...")
        
        # Если не найдена прямая ссылка, пробуем прямой запрос на скачивание
        download_headers = {
            "Accept": "*/*",
            "Content-Type": "application/json", 
            "Origin": BASE_URL,
            "Referer": LOGS_PAGE_URL,
            "User-Agent": HEADERS["User-Agent"],
            "X-CSRFToken": csrf_token
        }
        
        # Исправляем формат JSON - использование правильного формата для запроса
        download_body = '{"filename": "' + log_file + '"}'
        
        print(f"Отправляем запрос на скачивание {log_file} на URL: {DOWNLOAD_URL}")
        print(f"Заголовки запроса: {download_headers}")
        print(f"Тело запроса: {download_body}")
        
        download_response = session.post(
            DOWNLOAD_URL,
            headers=download_headers,
            data=download_body
        )
        
        # Добавляем более подробную отладочную информацию
        if download_response.status_code != 200:
            print(f"Ошибка скачивания: HTTP {download_response.status_code}")
            print(f"Ответ сервера: {download_response.text}")
            
            # Попробуем альтернативный URL для скачивания
            alt_download_url = ALT_DOWNLOAD_URL_TEMPLATE + log_file
            print(f"Пробуем альтернативный URL: {alt_download_url}")
            
            alt_download_response = session.get(
                alt_download_url,
                headers={"Accept": "*/*", "X-CSRFToken": csrf_token}
            )
            
            if alt_download_response.status_code != 200:
                print(f"Ошибка при использовании альтернативного URL: HTTP {alt_download_response.status_code}")
                return None
            
            # Если альтернативный URL сработал
            download_response = alt_download_response
        
        content_type = download_response.headers.get('Content-Type', '')
        if 'text/html' in content_type:
            print(f"Получен HTML вместо файла! Content-Type: {content_type}")
            print("Ответ сервера содержит HTML вместо файла логов")
            return None
        
        # Сохраняем скачанный файл
        # Создаем директорию для логов, если она не существует
        os.makedirs(logs_dir, exist_ok=True)
        
        file_path = os.path.join(logs_dir, log_file)
        with open(file_path, "wb") as f:
            f.write(download_response.content)
        
        file_size = os.path.getsize(file_path)
        print(f"Файл сохранен как: {file_path}")
        print(f"Размер файла: {file_size} байт")
        
        return file_path
    
    else:
        # Если нашли ссылку, переходим по ней для скачивания лога
        download_url = target_link
        if not download_url.startswith('http'):
            if download_url.startswith('/'):
                download_url = f"{BASE_URL}{download_url}"
            else:
                download_url = f"{BASE_URL}/{download_url}"
        
        print(f"Скачиваем файл по ссылке: {download_url}")
        download_response = session.get(download_url, headers=headers)
        
        if download_response.status_code != 200:
            print(f"Ошибка скачивания: HTTP {download_response.status_code}")
            print(download_response.text[:200])
            return None
        
        # Создаем директорию для логов, если она не существует
        os.makedirs(logs_dir, exist_ok=True)
        
        file_path = os.path.join(logs_dir, log_file)
        with open(file_path, "wb") as f:
            f.write(download_response.content)
        
        file_size = os.path.getsize(file_path)
        print(f"Файл сохранен как: {file_path}")
        print(f"Размер файла: {file_size} байт")
        
        return file_path

def list_available_logs():
    """Выводит список доступных логов с их описаниями"""
    print("Доступные файлы логов:")
    for log_name, description in AVAILABLE_LOGS.items():
        print(f"  {log_name:<15} - {description}")

if __name__ == "__main__":
    # Проверка версии Python
    if sys.version_info.major < 3:
        print("ОШИБКА: Для работы скрипта требуется Python 3")
        sys.exit(1)
    
    # Выводим список доступных логов
    list_available_logs()
    
    # Создаем директорию для логов, если она не существует
    os.makedirs(LOGS_DIR, exist_ok=True)
    print(f"Файлы логов будут сохранены в директорию: {os.path.abspath(LOGS_DIR)}")
    
    # Скачиваем все файлы логов
    successful_downloads = 0
    failed_downloads = 0
    
    print(f"\nНачинаем скачивание {len(LOG_FILES)} файлов логов...")
    
    for log_file in LOG_FILES:
        print(f"\nСкачиваем файл {log_file}...")
        result = download_log(log_file=log_file)
        
        if result:
            print(f"Скачивание {log_file} успешно завершено!")
            successful_downloads += 1
        else:
            print(f"Не удалось скачать файл {log_file}")
            failed_downloads += 1
    
    print("\n" + "="*50)
    print(f"Итоги скачивания:")
    print(f"Успешно скачано: {successful_downloads} файлов")
    print(f"Не удалось скачать: {failed_downloads} файлов")
    print(f"Все файлы сохранены в директории: {os.path.abspath(LOGS_DIR)}")
    print("="*50)
