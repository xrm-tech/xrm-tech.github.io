#!/usr/bin/env python3
# -*- coding: utf-8 -*-

from ragflow_sdk import RAGFlow
from typing import List, Optional
import sys
import os
import time
import sqlite3
import threading
import queue
import datetime
import random
import logging
import json
import re
import argparse
from pathlib import Path

# Регистрация адаптеров для работы с datetime в SQLite3 (для совместимости с Python 3.12+)
def adapt_datetime(val):
    return val.isoformat()

def convert_datetime(val):
    return datetime.datetime.fromisoformat(val.decode())

# Регистрация адаптеров
sqlite3.register_adapter(datetime.datetime, adapt_datetime)
sqlite3.register_converter("DATETIME", convert_datetime)

# =====================================================================
# ПОЛЬЗОВАТЕЛЬСКИЕ НАСТРОЙКИ
# Вы можете изменять эти параметры в соответствии с вашими потребностями
# =====================================================================

# Параметры подключения к RAGFlow
API_KEY = "ragflow-ZjNTQxMjc0ZTE2ZTExZWZiYzQ3MDI0Mm"
BASE_URL = "http://51.68.234.104:9380"

# Настройки чата с агентом
ENABLE_STREAMING = True           # Использовать потоковую передачу ответов (True/False)
SHOW_REFERENCES = True           # Показывать источники информации в ответах (True/False)
MAX_RESPONSE_LENGTH = 0           # Максимальная длина ответа (0 = без ограничений)
USER_PROMPT_PREFIX = "===== Вы =====\n> "  # Префикс для ввода пользователя
ASSISTANT_PREFIX = "===== Агент ====="  # Префикс для ответов ассистента

# Настройки анализатора логов
# Получаем директорию текущего скрипта
SCRIPT_DIR = os.path.dirname(os.path.abspath(__file__))
LOG_FILE_PATH = os.path.join(SCRIPT_DIR, "logs_to_agent.txt")  # Путь к файлу с логами
LOG_DB_PATH = os.path.join(SCRIPT_DIR, "log_results.db")       # Путь к базе данных результатов
LOG_BATCH_SIZE = 10                 # Количество логов для обработки за один вызов
LOG_PROCESSING_DELAY = 0.5          # Задержка между обработкой логов (в секундах)

# Предустановленные промпты
PREDEFINED_PROMPTS = {
    "log_prompt_1": "You are a log analyzer. Strictly compare the incoming log line for similarity with two knowledge bases: {{kb_uds_error}} - error examples (ERROR) and {{kb_uds_info}} - normal operation logs (INFO). Log line for analysis: '{}'. Respond ONLY with the required JSON.",
    "log_prompt_2": "Input text:: '{}'",
    "log_analyzer": "'{}'",
}

# Настройки внешнего вида
MENU_SEPARATOR = "-" * 50
EXIT_COMMANDS = ['exit', 'quit', 'выход']
MENU_COMMANDS = ['menu', 'меню', '/menu', '/меню']  # Команды для возврата в главное меню

# =====================================================================
# КОНЕЦ ПОЛЬЗОВАТЕЛЬСКИХ НАСТРОЕК
# =====================================================================

# Системные конфигурационные параметры
CONFIG = {
    # Параметры подключения к RAGFlow
    'API_KEY': API_KEY,
    'BASE_URL': BASE_URL,
    
    # Параметры пагинации
    'DEFAULT_PAGE': 1,
    'DEFAULT_PAGE_SIZE': 30,
    
    # Параметры сортировки
    'DEFAULT_ORDER_BY': "update_time",
    'DEFAULT_DESC': True,
    
    # Настройки интерфейса
    'MENU_SEPARATOR': MENU_SEPARATOR,
    'EXIT_COMMANDS': EXIT_COMMANDS,
    'MENU_COMMANDS': MENU_COMMANDS,
    
    # Настройки чата
    'ENABLE_STREAMING': ENABLE_STREAMING,
    'SHOW_REFERENCES': SHOW_REFERENCES,
    'MAX_RESPONSE_LENGTH': MAX_RESPONSE_LENGTH,
    'USER_PROMPT_PREFIX': USER_PROMPT_PREFIX,
    'ASSISTANT_PREFIX': ASSISTANT_PREFIX,
    
    # Предустановленные промпты
    'PREDEFINED_PROMPTS': PREDEFINED_PROMPTS,
    'INPUT_LOG_LINE': "[INPUT_LOG_LINE]",
    
    # Сообщения
    'MESSAGES': {
        'welcome': "Менеджер по работе с агентами XRM Director",
        'goodbye': "До свидания!",
        'invalid_choice': "Неверный выбор. Попробуйте снова.",
        'press_enter': "Нажмите Enter для продолжения...",
        'no_agents': "Нет доступных агентов",
        'no_session': "Сначала создайте сеанс!",
        'no_sessions_available': "Нет доступных сеансов для этого агента. Создайте новый сеанс.",
        'session_error': "Сессия была сброшена из-за ошибки. Пожалуйста, создайте новую сессию.",
        'chat_welcome': "Здравствуйте! Задайте свой вопрос агенту?",
        'chat_exit_help': "Для выхода введите 'exit', 'quit' или 'выход'. Для возврата в главное меню введите 'menu' или 'меню'.",
        'all_sessions_deleted': "Все сеансы у всех агентов удалены",
        'select_session': "Выберите существующий сеанс или создайте новый",
        'back_to_menu': "Возврат в главное меню..."    }
}

# =====================================================================
# CLI ФУНКЦИИ ДЛЯ РАБОТЫ ИЗ КОМАНДНОЙ СТРОКИ
# =====================================================================

def cli_list_agents():
    """CLI функция для отображения списка агентов"""
    try:
        rag_object = RAGFlow(api_key=CONFIG['API_KEY'], base_url=CONFIG['BASE_URL'])
        agents = rag_object.list_agents(
            page=CONFIG['DEFAULT_PAGE'],
            page_size=CONFIG['DEFAULT_PAGE_SIZE'],
            orderby=CONFIG['DEFAULT_ORDER_BY'],
            desc=CONFIG['DEFAULT_DESC']
        )
        
        if not agents:
            print("Нет доступных агентов")
            return False
            
        print("Доступные агенты:")
        print(CONFIG['MENU_SEPARATOR'])
        for idx, agent in enumerate(agents, 1):
            print(f"{idx}. ID: {agent.id}")
            print(f"   Название: {agent.title}")
            print(CONFIG['MENU_SEPARATOR'])
        return True
    except Exception as e:
        print(f"Ошибка при получении списка агентов: {str(e)}")
        return False

def cli_create_session(agent_id=None, agent_title=None):
    """CLI функция для создания сеанса с агентом"""
    try:
        rag_object = RAGFlow(api_key=CONFIG['API_KEY'], base_url=CONFIG['BASE_URL'])
        
        # Получаем список агентов
        agents = rag_object.list_agents(
            page=CONFIG['DEFAULT_PAGE'],
            page_size=CONFIG['DEFAULT_PAGE_SIZE'],
            orderby=CONFIG['DEFAULT_ORDER_BY'],
            desc=CONFIG['DEFAULT_DESC']
        )
        
        if not agents:
            print("Нет доступных агентов")
            return None, None
            
        # Поиск агента по ID или названию
        target_agent = None
        if agent_id:
            target_agent = next((agent for agent in agents if agent.id == agent_id), None)
        elif agent_title:
            target_agent = next((agent for agent in agents if agent_title.lower() in agent.title.lower()), None)
        
        if not target_agent:
            print("Агент не найден. Доступные агенты:")
            cli_list_agents()
            return None, None
            
        # Создание сеанса
        session = target_agent.create_session()
        print(f"Создан новый сеанс с агентом '{target_agent.title}'")
        print(f"ID агента: {target_agent.id}")
        print(f"ID сеанса: {session.id}")
        
        return target_agent, session
        
    except Exception as e:
        print(f"Ошибка при создании сеанса: {str(e)}")
        return None, None

def cli_send_message(message, agent_id=None, agent_title=None, session_id=None, create_new_session=False):
    """CLI функция для отправки сообщения агенту"""
    try:
        rag_object = RAGFlow(api_key=CONFIG['API_KEY'], base_url=CONFIG['BASE_URL'])
        
        # Получаем список агентов
        agents = rag_object.list_agents(
            page=CONFIG['DEFAULT_PAGE'],
            page_size=CONFIG['DEFAULT_PAGE_SIZE'],
            orderby=CONFIG['DEFAULT_ORDER_BY'],
            desc=CONFIG['DEFAULT_DESC']
        )
        
        if not agents:
            print("Нет доступных агентов")
            return False
            
        # Поиск агента
        target_agent = None
        if agent_id:
            target_agent = next((agent for agent in agents if agent.id == agent_id), None)
        elif agent_title:
            target_agent = next((agent for agent in agents if agent_title.lower() in agent.title.lower()), None)
        else:
            # Если не указан агент, берем первого доступного
            target_agent = agents[0]
            print(f"Агент не указан, используется первый доступный: '{target_agent.title}'")
        
        if not target_agent:
            print("Агент не найден. Доступные агенты:")
            cli_list_agents()
            return False
            
        # Поиск или создание сеанса
        target_session = None
        
        if session_id:
            # Поиск конкретного сеанса
            sessions = target_agent.list_sessions()
            target_session = next((session for session in sessions if session.id == session_id), None)
            if not target_session:
                print(f"Сеанс с ID {session_id} не найден")
                return False
        elif create_new_session:
            # Создание нового сеанса
            target_session = target_agent.create_session()
            print(f"Создан новый сеанс с ID: {target_session.id}")
        else:
            # Поиск существующего сеанса или создание нового
            sessions = target_agent.list_sessions()
            if sessions:
                target_session = sessions[0]  # Берем первый доступный сеанс
                print(f"Используется существующий сеанс с ID: {target_session.id}")
            else:
                target_session = target_agent.create_session()
                print(f"Создан новый сеанс с ID: {target_session.id}")
        
        # Отправка сообщения
        print(f"\nОтправка сообщения агенту '{target_agent.title}':")
        print(f"Сообщение: {message}")
        print(f"\n{CONFIG['ASSISTANT_PREFIX']}")
        
        content = ""
        response_received = False
        references = []
        
        # Получение ответа от агента
        for response in target_session.ask(message, stream=CONFIG['ENABLE_STREAMING']):
            if response and hasattr(response, 'content'):
                response_received = True
                
                # Обработка ограничения длины ответа
                if CONFIG['MAX_RESPONSE_LENGTH'] > 0 and len(response.content) > CONFIG['MAX_RESPONSE_LENGTH']:
                    if len(content) < CONFIG['MAX_RESPONSE_LENGTH']:
                        new_content = response.content[len(content):CONFIG['MAX_RESPONSE_LENGTH']]
                        print(new_content + "... [Ответ обрезан из-за ограничения длины]", end='', flush=True)
                        content = response.content[:CONFIG['MAX_RESPONSE_LENGTH']]
                else:
                    new_content = response.content[len(content):]
                    print(new_content, end='', flush=True)
                    content = response.content
                    
                # Сохраняем ссылки на источники
                if CONFIG['SHOW_REFERENCES'] and hasattr(response, 'reference') and response.reference:
                    references = response.reference
        
        if not response_received:
            print("Извините, произошла ошибка при обработке ответа.")
            return False
            
        # Вывод источников информации
        if CONFIG['SHOW_REFERENCES'] and references:
            print("\n\nИсточники информации:")
            for idx, ref in enumerate(references, 1):
                if isinstance(ref, dict):
                    doc_name = ref.get('document_name', f'Источник {idx}')
                    ref_content = ref.get('content', '')
                    similarity = ref.get('similarity', None)
                else:
                    doc_name = getattr(ref, 'document_name', f'Источник {idx}')
                    ref_content = getattr(ref, 'content', '')
                    similarity = getattr(ref, 'similarity', None)
                
                print(f"\n{idx}. {doc_name}")
                if ref_content:
                    print(f"   {ref_content[:100]}...")
                if similarity is not None:
                    print(f"   Релевантность: {similarity:.2f}")
        
        print()
        return True
        
    except Exception as e:
        print(f"Ошибка при отправке сообщения: {str(e)}")
        return False

def parse_arguments():
    """Парсинг аргументов командной строки"""
    parser = argparse.ArgumentParser(
        description="Менеджер для работы с агентами RAGFlow",
        formatter_class=argparse.RawDescriptionHelpFormatter,
        epilog="""
Примеры использования:

# Показать список агентов
python ragflow_menu.py --list-agents

# Создать сеанс с агентом по ID
python ragflow_menu.py --create-session --agent-id "agent123"

# Создать сеанс с агентом по названию
python ragflow_menu.py --create-session --agent-title "GPT"

# Отправить сообщение агенту (создаст новый сеанс)
python ragflow_menu.py --send "Привет, как дела?" --agent-title "GPT"

# Отправить сложную строку лога (используйте одинарные кавычки в PowerShell)
python ragflow_menu.py --send 'ERROR 2024-07-12 11:15:26,987 config get 148 FATAL: no pg_hba.conf entry for host "10.1.97.70", user "udsdbadm", database "udsdb", SSL on' --agent-title "api_llm_agent" --new-session

# Отправить сообщение в существующий сеанс
python ragflow_menu.py --send "Что такое Python?" --agent-id "agent123" --session-id "session456"

# Отправить сообщение с принудительным созданием нового сеанса
python ragflow_menu.py --send "Новый вопрос" --agent-title "GPT" --new-session
        """
    )
    
    # Основные команды
    parser.add_argument('--list-agents', action='store_true', 
                       help='Показать список всех доступных агентов')
    parser.add_argument('--create-session', action='store_true',
                       help='Создать новый сеанс с агентом')
    parser.add_argument('--send', type=str, metavar='MESSAGE',
                       help='Отправить сообщение агенту')
    
    # Параметры для выбора агента
    parser.add_argument('--agent-id', type=str, metavar='ID',
                       help='ID агента для работы')
    parser.add_argument('--agent-title', type=str, metavar='TITLE',
                       help='Название агента для поиска (частичное совпадение)')
    
    # Параметры для работы с сеансами
    parser.add_argument('--session-id', type=str, metavar='ID',
                       help='ID существующего сеанса')
    parser.add_argument('--new-session', action='store_true',
                       help='Принудительно создать новый сеанс')
    
    # Дополнительные опции
    parser.add_argument('--no-references', action='store_true',
                       help='Не показывать источники информации в ответах')
    parser.add_argument('--no-streaming', action='store_true',
                       help='Отключить потоковую передачу ответов')
    
    return parser.parse_args()

class RAGFlowMenu:
    def __init__(self):
        """Инициализация меню и подключения к RAGFlow"""
        try:
            self.rag_object = RAGFlow(api_key=CONFIG['API_KEY'], base_url=CONFIG['BASE_URL'])
            self.current_agent = None
            self.current_session = None
            self.log_processor = LogProcessor(self)  # Инициализация процессора логов
            
            # Проверяем соединение при инициализации
            self._test_connection()
            
        except Exception as e:
            print(f"Ошибка при инициализации RAGFlow: {e}")
            print("Проверьте настройки API_KEY и BASE_URL")
            self.rag_object = None
            self.current_agent = None
            self.current_session = None
            self.log_processor = None
    
    def _test_connection(self):
        """Тестирование подключения к RAGFlow API"""
        try:
            # Пытаемся получить список агентов для проверки соединения
            test_agents = self.rag_object.list_agents(page=1, page_size=1)
            print("✓ Подключение к RAGFlow API успешно установлено")
            return True
        except Exception as e:
            error_msg = str(e)
            if "Expecting value" in error_msg:
                print("✗ Ошибка: Сервер вернул некорректный JSON. Проверьте BASE_URL.")
            elif "Connection" in error_msg or "timeout" in error_msg.lower():
                print("✗ Ошибка: Не удается подключиться к серверу RAGFlow.")
            elif "401" in error_msg or "Unauthorized" in error_msg:
                print("✗ Ошибка: Неверный API_KEY.")
            else:
                print(f"✗ Ошибка подключения: {error_msg}")
            return False

    def clear_screen(self):
        """Очистка экрана"""
        os.system('cls' if os.name == 'nt' else 'clear')

    def select_agent(self) -> Optional[object]:
        """Выбор агента из списка"""
        if not self.rag_object:
            print("Ошибка: нет подключения к RAGFlow API")
            return None
            
        try:
            agents = self.rag_object.list_agents(
                page=CONFIG['DEFAULT_PAGE'],
                page_size=CONFIG['DEFAULT_PAGE_SIZE'],
                orderby=CONFIG['DEFAULT_ORDER_BY'],
                desc=CONFIG['DEFAULT_DESC']
            )
            if not agents:
                print(f"\n{CONFIG['MESSAGES']['no_agents']}")
                return None

            print("\nДоступные агенты:")
            print(CONFIG['MENU_SEPARATOR'])
            for idx, agent in enumerate(agents, 1):
                print(f"{idx}. ID: {agent.id}")
                print(f"   Название: {agent.title}")
                # Строка с временем создания удалена
                print(CONFIG['MENU_SEPARATOR'])

            while True:
                try:
                    choice = int(input("\nВыберите номер агента (0 для возврата): "))
                    if choice == 0:
                        return None
                    if 1 <= choice <= len(agents):
                        return agents[choice - 1]
                    print(CONFIG['MESSAGES']['invalid_choice'])
                except ValueError:
                    print("Пожалуйста, введите число.")
        except Exception as e:
            error_msg = str(e)
            if "Expecting value" in error_msg:
                print("Ошибка: Сервер RAGFlow вернул некорректный ответ")
            else:
                print(f"Ошибка при получении списка агентов: {error_msg}")
            return None

    def create_session(self):
        """Создание нового сеанса с агентом"""
        agent = self.select_agent()
        if not agent:
            return

        try:
            session = agent.create_session()
            print(f"\nСоздан новый сеанс с агентом '{agent.title}'")
            print(f"ID сеанса: {session.id}")
            self.current_agent = agent
            self.current_session = session
        except Exception as e:
            print(f"Ошибка при создании сеанса: {str(e)}")

    def chat_with_agent(self):
        """Общение с агентом"""
        # Проверяем валидность текущего сеанса
        if self.current_session and not self.check_session_valid():
            print("\nТекущий сеанс больше не действителен (возможно, был удален).")
            print(CONFIG['MESSAGES']['no_session'])
            # Сбрасываем значения current_agent и current_session
            self.current_agent = None
            self.current_session = None
            
        # Проверяем наличие текущего сеанса
        if not self.current_session:
            # Если нет текущего сеанса, предлагаем выбрать агента
            agent = self.select_agent()
            if not agent:
                return
                
            # После выбора агента, предлагаем выбрать существующий сеанс или создать новый
            print(f"\n{CONFIG['MESSAGES']['select_session']}")
            session = self.select_session(agent)
            
            if not session:
                return
                
            self.current_agent = agent
            self.current_session = session
        
        print(f"\nЧат с агентом '{self.current_agent.title}' - сеанс {self.current_session.id}")
        print(CONFIG['MESSAGES']['chat_exit_help'])
        print(f"\n{CONFIG['ASSISTANT_PREFIX']}")
        print(CONFIG['MESSAGES']['chat_welcome'])

        while True:
            question = input(f"\n{CONFIG['USER_PROMPT_PREFIX']}")
            final_prompt = question  # Сохраняем исходный вопрос для отображения
            
            # Проверка команд выхода и возврата в меню
            if question.lower() in CONFIG['EXIT_COMMANDS']:
                break
            elif question.lower() in CONFIG['MENU_COMMANDS']:
                print(f"\n{CONFIG['MESSAGES']['back_to_menu']}")
                return

            # Проверка на использование предустановленных промптов
            if question.startswith("/"):
                prompt_key = question[1:].strip()
                if prompt_key in CONFIG['PREDEFINED_PROMPTS']:
                    print(f"\nИспользуется предустановленный промпт: {prompt_key}")
                    user_input = input("Введите текст отпавляемый агенту: ")
                    final_prompt = CONFIG['PREDEFINED_PROMPTS'][prompt_key].format(user_input)
                    print(f"\nАгенту отправлен текст: {final_prompt}")
                elif prompt_key == "help":
                    print("\nДоступные команды:")
                    for key, prompt in CONFIG['PREDEFINED_PROMPTS'].items():
                        print(f"/{key} - {prompt[:30]}...")
                    print("\nСистемные команды:")
                    print("'exit', 'quit', 'выход' - Выход из чата с сохранением сеанса")
                    print("'menu', 'меню', '/menu', '/меню' - Возврат в главное меню")
                    continue
                # Обратная совместимость со старым кодом для анализа логов
                elif CONFIG['INPUT_LOG_LINE'] in question:
                    log_line = input("\nВведите строку лога для анализа: ")
                    final_prompt = CONFIG['PREDEFINED_PROMPTS']['log_prompt_1'].format(log_line)
                    print(f"\nИспользуется предустановленный промпт для анализа логов")
                    print(f"Агенту отправлен текст: {final_prompt}")
                else:
                    # Обычный вопрос, начинающийся с /
                    print(f"\nАгенту отправлен текст: {final_prompt}")
            else:
                # Обычный вопрос без префикса /
                print(f"\nАгенту отправлен текст: {final_prompt}")

            print(f"\n{CONFIG['ASSISTANT_PREFIX']}")
            try:
                content = ""
                response_received = False
                references = []
                
                # Получение ответа от агента с использованием пользовательских настроек
                for response in self.current_session.ask(final_prompt, stream=CONFIG['ENABLE_STREAMING']):
                    if response and hasattr(response, 'content'):
                        response_received = True
                        
                        # Обработка ограничения длины ответа
                        if CONFIG['MAX_RESPONSE_LENGTH'] > 0 and len(response.content) > CONFIG['MAX_RESPONSE_LENGTH']:
                            # Если длина превышает максимальную, обрезаем контент
                            if len(content) < CONFIG['MAX_RESPONSE_LENGTH']:
                                new_content = response.content[len(content):CONFIG['MAX_RESPONSE_LENGTH']]
                                print(new_content + "... [Ответ обрезан из-за ограничения длины]", end='', flush=True)
                                content = response.content[:CONFIG['MAX_RESPONSE_LENGTH']]
                        else:
                            new_content = response.content[len(content):]
                            print(new_content, end='', flush=True)
                            content = response.content
                            
                        # Сохраняем ссылки на источники, если они есть
                        if CONFIG['SHOW_REFERENCES'] and hasattr(response, 'reference') and response.reference:
                            references = response.reference
                    
                if not response_received:
                    print("Извините, произошла ошибка при обработке ответа. Попробуйте переформулировать вопрос.")
                  # Вывод источников информации, если они есть и настройка включена
                if CONFIG['SHOW_REFERENCES'] and references:
                    print("\n\nИсточники информации:")
                    for idx, ref in enumerate(references, 1):
                        # Проверяем, является ли ref словарем или объектом
                        if isinstance(ref, dict):
                            doc_name = ref.get('document_name', f'Источник {idx}')
                            content = ref.get('content', '')
                            similarity = ref.get('similarity', None)
                        else:
                            # Это объект с атрибутами
                            doc_name = getattr(ref, 'document_name', f'Источник {idx}')
                            content = getattr(ref, 'content', '')
                            similarity = getattr(ref, 'similarity', None)
                        
                        print(f"\n{idx}. {doc_name}")
                        if content:
                            print(f"   {content[:100]}...")
                        if similarity is not None:
                            print(f"   Релевантность: {similarity:.2f}")
                
                print()
                
            except Exception as e:
                print(f"Ошибка при получении ответа: {str(e)}")
                print("Попробуйте создать новый сеанс или переформулировать вопрос.")
                if "not callable" in str(e) or "not valid" in str(e):
                    self.current_session = None
                    print(f"\n{CONFIG['MESSAGES']['session_error']}")
                    break

    def list_sessions(self):
        """Просмотр списка сеансов агента"""
        agent = self.select_agent()
        if not agent:
            return

        try:
            sessions = agent.list_sessions(
                page=CONFIG['DEFAULT_PAGE'],
                page_size=CONFIG['DEFAULT_PAGE_SIZE'],
                orderby=CONFIG['DEFAULT_ORDER_BY'],
                desc=CONFIG['DEFAULT_DESC']
            )
            if not sessions:
                print(f"\nНет доступных сеансов для агента '{agent.title}'")
                return

            print(f"\nСписок сеансов агента '{agent.title}':")
            print(CONFIG['MENU_SEPARATOR'])
            for session in sessions:
                print(f"ID сеанса: {session.id}")
                print(CONFIG['MENU_SEPARATOR'])
        except Exception as e:
            print(f"Ошибка при получении списка сеансов: {str(e)}")

    def delete_sessions(self):
        """Удаление сеансов агента"""
        agent = self.select_agent()
        if not agent:
            return

        try:
            sessions = agent.list_sessions()
            if not sessions:
                print(f"\nНет доступных сеансов для удаления у агента '{agent.title}'")
                return

            print("\nДоступные сеансы для удаления:")
            print(CONFIG['MENU_SEPARATOR'])
            for idx, session in enumerate(sessions, 1):
                print(f"{idx}. ID: {session.id}")
            print(CONFIG['MENU_SEPARATOR'])

            while True:
                try:
                    choice = input("\nВведите номера сеансов для удаления через запятую (0 для удаления всех): ")
                    if choice == "0":
                        agent.delete_sessions()
                        print("\nВсе сеансы удалены")
                        break
                    
                    indices = [int(x.strip()) for x in choice.split(",")]
                    session_ids = [sessions[i-1].id for i in indices if 1 <= i <= len(sessions)]
                    
                    if session_ids:
                        agent.delete_sessions(ids=session_ids)
                        print("\nВыбранные сеансы удалены")
                        break
                    else:
                        print(CONFIG['MESSAGES']['invalid_choice'])
                except ValueError:
                    print("Пожалуйста, введите корректные номера сеансов.")
                except Exception as e:
                    print(f"Ошибка при удалении сеансов: {str(e)}")
                    break
        except Exception as e:
            print(f"Ошибка при получении списка сеансов: {str(e)}")

    def delete_all_sessions(self):
        """Удаление всех сеансов у всех агентов"""
        try:
            agents = self.rag_object.list_agents(
                page=CONFIG['DEFAULT_PAGE'],
                page_size=CONFIG['DEFAULT_PAGE_SIZE'],
                orderby=CONFIG['DEFAULT_ORDER_BY'],
                desc=CONFIG['DEFAULT_DESC']
            )
            
            if not agents:
                print(f"\n{CONFIG['MESSAGES']['no_agents']}")
                return
                
            # Подтверждение операции
            confirm = input("\nВы уверены, что хотите удалить ВСЕ сеансы у ВСЕХ агентов? (y/n): ")
            if confirm.lower() != 'y':
                print("\nОперация отменена.")
                return
                
            # Удаление сеансов у каждого агента
            deleted_count = 0
            for agent in agents:
                try:
                    sessions = agent.list_sessions()
                    if sessions:
                        agent.delete_sessions()
                        deleted_count += len(sessions)
                        print(f"Удалены все сеансы у агента '{agent.title}'")
                except Exception as e:
                    print(f"Ошибка при удалении сеансов агента '{agent.title}': {str(e)}")
                    
            print(f"\nУдалено всего сеансов: {deleted_count}")
            print(CONFIG['MESSAGES']['all_sessions_deleted'])
            
        except Exception as e:
            print(f"Ошибка при получении списка агентов: {str(e)}")

    def select_session(self, agent) -> Optional[object]:
        """Выбор существующей сессии агента"""
        try:
            sessions = agent.list_sessions(
                page=CONFIG['DEFAULT_PAGE'],
                page_size=CONFIG['DEFAULT_PAGE_SIZE'],
                orderby=CONFIG['DEFAULT_ORDER_BY'],
                desc=CONFIG['DEFAULT_DESC']
            )
            
            if not sessions:
                print(f"\n{CONFIG['MESSAGES']['no_sessions_available']}")
                return None

            print("\nДоступные сеансы:")
            print(CONFIG['MENU_SEPARATOR'])
            for idx, session in enumerate(sessions, 1):
                print(f"{idx}. ID сеанса: {session.id}")
                print(CONFIG['MENU_SEPARATOR'])

            print(f"{len(sessions) + 1}. Создать новый сеанс")
            print(CONFIG['MENU_SEPARATOR'])

            while True:
                try:
                    choice = int(input("\nВыберите номер сеанса (0 для возврата): "))
                    if choice == 0:
                        return None
                    if 1 <= choice <= len(sessions):
                        return sessions[choice - 1]
                    if choice == len(sessions) + 1:
                        # Создание нового сеанса
                        try:
                            session = agent.create_session()
                            print(f"\nСоздан новый сеанс с агентом '{agent.title}'")
                            print(f"ID сеанса: {session.id}")
                            return session
                        except Exception as e:
                            print(f"Ошибка при создании сеанса: {str(e)}")
                            return None
                    print(CONFIG['MESSAGES']['invalid_choice'])
                except ValueError:
                    print("Пожалуйста, введите число.")
        except Exception as e:
            print(f"Ошибка при получении списка сеансов: {str(e)}")
            return None

    def view_all_agents(self):
        """Просмотр списка всех агентов"""
        try:
            agents = self.rag_object.list_agents(
                page=CONFIG['DEFAULT_PAGE'],
                page_size=CONFIG['DEFAULT_PAGE_SIZE'],
                orderby=CONFIG['DEFAULT_ORDER_BY'],
                desc=CONFIG['DEFAULT_DESC']
            )
            
            if not agents:
                print(f"\n{CONFIG['MESSAGES']['no_agents']}")
                return
                
            print("\nСписок всех агентов:")
            print(CONFIG['MENU_SEPARATOR'])
            for agent in agents:
                print(f"ID: {agent.id}")
                print(f"Название: {agent.title}")
                print(CONFIG['MENU_SEPARATOR'])
            
        except Exception as e:
            print(f"Ошибка при получении списка агентов: {str(e)}")

    def get_active_sessions_info(self):
        """Получение информации об активных сеансах для всех агентов"""
        try:
            # Проверяем соединение с API перед запросом
            try:
                agents = self.rag_object.list_agents(
                    page=CONFIG['DEFAULT_PAGE'],
                    page_size=CONFIG['DEFAULT_PAGE_SIZE'],
                    orderby=CONFIG['DEFAULT_ORDER_BY'],
                    desc=CONFIG['DEFAULT_DESC']
                )
            except Exception as api_error:
                # Обрабатываем ошибки API соединения
                error_msg = str(api_error)
                if "Expecting value" in error_msg:
                    return "Ошибка подключения к API RAGFlow. Проверьте:\n1. Правильность BASE_URL\n2. Доступность сервера\n3. Корректность API_KEY"
                elif "Connection" in error_msg or "timeout" in error_msg.lower():
                    return "Сервер RAGFlow недоступен. Проверьте сетевое подключение."
                else:
                    return f"Ошибка API: {error_msg}"
            
            if not agents:
                return "Нет доступных агентов"
            
            active_sessions = []
            total_sessions = 0
            
            for agent in agents:
                try:
                    sessions = agent.list_sessions()
                    session_count = len(sessions) if sessions else 0
                    total_sessions += session_count
                    
                    if session_count > 0:
                        active_sessions.append({
                            "agent_name": agent.title,
                            "agent_id": agent.id,
                            "sessions_count": session_count
                        })
                except Exception as session_error:
                    # Логируем ошибку получения сеансов для конкретного агента
                    print(f"Предупреждение: не удалось получить сеансы для агента {agent.title}: {str(session_error)}")
                    continue
            
            if active_sessions:
                result = f"Всего активных сеансов: {total_sessions}\n"
                result += "Детализация по агентам:\n"
                for agent_info in active_sessions:
                    result += f"• {agent_info['agent_name']}: {agent_info['sessions_count']} сеансов\n"
                return result
            else:
                return "Нет активных сеансов у агентов"
                
        except Exception as e:
            error_msg = str(e)
            if "Expecting value" in error_msg:
                return "Ошибка парсинга JSON ответа от сервера RAGFlow"
            else:
                return f"Ошибка при проверке активных сеансов: {error_msg}"

    def check_session_valid(self):
        """Проверка валидности текущего сеанса"""
        if not self.current_agent or not self.current_session:
            return False
            
        try:
            # Проверяем, существует ли еще этот агент
            agents = self.rag_object.list_agents()
            agent_exists = any(agent.id == self.current_agent.id for agent in agents)
            
            if not agent_exists:
                self.current_agent = None
                self.current_session = None
                return False
                
            # Проверяем, существует ли еще сеанс у этого агента
            sessions = self.current_agent.list_sessions()
            session_exists = any(session.id == self.current_session.id for session in sessions)
            
            if not session_exists:
                self.current_session = None
                return False
                
            return True
        except Exception:
            # При возникновении любой ошибки считаем сеанс недействительным
            self.current_agent = None
            self.current_session = None
            return False

    def show_menu(self):
        """Отображение главного меню"""
        while True:
            self.clear_screen()
            print(f"\n{CONFIG['MESSAGES']['welcome']}")
            print(CONFIG['MENU_SEPARATOR'])
            
            # Проверяем соединение с API
            if not self.rag_object:
                print("❌ НЕТ ПОДКЛЮЧЕНИЯ К RAGFlow API")
                print("Проверьте настройки API_KEY и BASE_URL в файле")
                print(CONFIG['MENU_SEPARATOR'])
            else:
                # Проверка наличия открытых сеансов
                active_sessions_info = self.get_active_sessions_info()
                print(f"\n{active_sessions_info}\n")
                print(CONFIG['MENU_SEPARATOR'])
            
            print("1. Посмотреть всех агентов")
            print("2. Создать сеанс с агентом")
            print("3. Поговорить с агентом")
            print("4. Список сеансов агента")
            print("5. Удалить сеансы агента")
            print("6. Удалить все сеансы у всех агентов")
            print("7. Анализатор логов")  # Новая опция для меню анализа логов
            print("0. Выход")
            print(CONFIG['MENU_SEPARATOR'])

            try:
                choice = input("\nВыберите действие: ")
                
                # Проверяем доступность API для операций, требующих соединения
                if choice in ["1", "2", "3", "4", "5", "6"] and not self.rag_object:
                    print("\nОшибка: Нет подключения к RAGFlow API. Исправьте настройки подключения.")
                    input(f"\n{CONFIG['MESSAGES']['press_enter']}")
                    continue
                
                if choice == "1":
                    self.view_all_agents()
                elif choice == "2":
                    self.create_session()
                elif choice == "3":
                    self.chat_with_agent()
                elif choice == "4":
                    self.list_sessions()
                elif choice == "5":
                    self.delete_sessions()
                elif choice == "6":
                    self.delete_all_sessions()
                elif choice == "7":
                    self.log_analyzer_menu()  # Переход в меню анализа логов
                elif choice == "0":
                    print(f"\n{CONFIG['MESSAGES']['goodbye']}")
                    sys.exit(0)
                else:
                    print(f"\n{CONFIG['MESSAGES']['invalid_choice']}")
                
                input(f"\n{CONFIG['MESSAGES']['press_enter']}")
            except KeyboardInterrupt:
                print("\nПрограмма завершена пользователем")
                sys.exit(0)
            except Exception as e:
                print(f"\nПроизошла ошибка: {str(e)}")
                input(f"\n{CONFIG['MESSAGES']['press_enter']}")

    def log_analyzer_menu(self):
        """Меню для работы с анализатором логов"""
        while True:
            self.clear_screen()
            print("\nАнализатор логов")
            print(CONFIG['MENU_SEPARATOR'])
            
            # Отображение текущего статуса обработки
            status = self.log_processor.get_status()
            print(f"Текущий статус: {status}")
            print(CONFIG['MENU_SEPARATOR'])
            
            print("1. Запустить обработку логов")
            print("2. Остановить обработку логов")
            print("3. Приостановить обработку")
            print("4. Возобновить обработку")
            print("5. Показать статистику обработки")
            print("6. Настройки анализатора")
            print("0. Вернуться в главное меню")
            print(CONFIG['MENU_SEPARATOR'])
            
            try:
                choice = input("\nВыберите действие: ")
                if choice == "1":
                    self.log_processor.start_processing()
                elif choice == "2":
                    self.log_processor.stop_processing()
                elif choice == "3":
                    self.log_processor.pause_processing()
                elif choice == "4":
                    self.log_processor.resume_processing()
                elif choice == "5":
                    self.log_processor.show_statistics()
                elif choice == "6":
                    self.log_analyzer_settings()
                elif choice == "0":
                    return
                else:
                    print(f"\n{CONFIG['MESSAGES']['invalid_choice']}")
                
                input(f"\n{CONFIG['MESSAGES']['press_enter']}")
            except KeyboardInterrupt:
                print("\nОперация отменена пользователем")
                return
            except Exception as e:
                print(f"\nПроизошла ошибка: {str(e)}")
                input(f"\n{CONFIG['MESSAGES']['press_enter']}")
    
    def log_analyzer_settings(self):
        """Настройки анализатора логов"""
        global LOG_FILE_PATH, LOG_DB_PATH, LOG_PROCESSING_DELAY
        
        while True:
            self.clear_screen()
            print("\nНастройки анализатора логов")
            print(CONFIG['MENU_SEPARATOR'])
            
            print(f"1. Файл логов: {LOG_FILE_PATH}")
            print(f"2. База данных: {LOG_DB_PATH}")
            print(f"3. Задержка между обработками: {LOG_PROCESSING_DELAY} сек.")
            print("4. Редактировать промпты")
            print("0. Вернуться в меню анализатора")
            print(CONFIG['MENU_SEPARATOR'])
            
            try:
                choice = input("\nВыберите параметр для изменения: ")
                if choice == "1":
                    new_path = input(f"Введите новый путь к файлу логов [{LOG_FILE_PATH}]: ")
                    if new_path.strip():
                        LOG_FILE_PATH = new_path.strip()
                        print(f"Путь к файлу логов изменен на: {LOG_FILE_PATH}")
                elif choice == "2":
                    new_path = input(f"Введите новый путь к базе данных [{LOG_DB_PATH}]: ")
                    if new_path.strip():
                        LOG_DB_PATH = new_path.strip()
                        print(f"Путь к базе данных изменен на: {LOG_DB_PATH}")
                elif choice == "3":
                    try:
                        new_delay = float(input(f"Введите новую задержку в секундах [{LOG_PROCESSING_DELAY}]: "))
                        if new_delay >= 0:
                            LOG_PROCESSING_DELAY = new_delay
                            print(f"Задержка изменена на: {LOG_PROCESSING_DELAY} сек.")
                        else:
                            print("Задержка не может быть отрицательной.")
                    except ValueError:
                        print("Пожалуйста, введите корректное число.")
                elif choice == "4":
                    self.edit_prompts()
                elif choice == "0":
                    return
                else:
                    print(f"\n{CONFIG['MESSAGES']['invalid_choice']}")
                
                input(f"\n{CONFIG['MESSAGES']['press_enter']}")
            except KeyboardInterrupt:
                print("\nОперация отменена пользователем")
                return
            except Exception as e:
                print(f"\nПроизошла ошибка: {str(e)}")
                input(f"\n{CONFIG['MESSAGES']['press_enter']}")
    
    def edit_prompts(self):
        """Редактирование предустановленных промптов"""
        while True:
            self.clear_screen()
            print("\nРедактирование промптов")
            print(CONFIG['MENU_SEPARATOR'])
            
            prompt_options = []
            for idx, (key, prompt) in enumerate(CONFIG['PREDEFINED_PROMPTS'].items(), 1):
                print(f"{idx}. {key}")
                print(f"   {prompt[:50]}..." if len(prompt) > 50 else f"   {prompt}")
                print(CONFIG['MENU_SEPARATOR'])
                prompt_options.append((key, prompt))
            
            print(f"{len(prompt_options) + 1}. Добавить новый промпт")
            print("0. Вернуться в настройки")
            print(CONFIG['MENU_SEPARATOR'])
            
            try:
                choice = input("\nВыберите промпт для редактирования: ")
                if choice == "0":
                    return
                elif choice.isdigit() and 1 <= int(choice) <= len(prompt_options):
                    key = prompt_options[int(choice) - 1][0]
                    current_prompt = CONFIG['PREDEFINED_PROMPTS'][key]
                    
                    print(f"\nТекущий промпт: {current_prompt}")
                    new_prompt = input("\nВведите новый промпт (или оставьте пустым для сохранения текущего):\n")
                    
                    if new_prompt.strip():
                        CONFIG['PREDEFINED_PROMPTS'][key] = new_prompt
                        print(f"\nПромпт '{key}' обновлен.")
                elif choice == str(len(prompt_options) + 1):
                    # Добавление нового промпта
                    key = input("\nВведите ключ для нового промпта: ")
                    if key.strip() and key not in CONFIG['PREDEFINED_PROMPTS']:
                        prompt = input("\nВведите текст промпта (используйте {} для вставки текста лога):\n")
                        if prompt.strip():
                            CONFIG['PREDEFINED_PROMPTS'][key] = prompt
                            print(f"\nНовый промпт '{key}' добавлен.")
                    else:
                        print("Ключ должен быть непустым и уникальным.")
                else:
                    print(f"\n{CONFIG['MESSAGES']['invalid_choice']}")
                
                input(f"\n{CONFIG['MESSAGES']['press_enter']}")
            except KeyboardInterrupt:
                print("\nОперация отменена пользователем")
                return
            except Exception as e:
                print(f"\nПроизошла ошибка: {str(e)}")
                input(f"\n{CONFIG['MESSAGES']['press_enter']}")
    

class Database:
    """Класс для работы с базой данных SQLite"""
    
    def __init__(self, db_path=LOG_DB_PATH):
        """Инициализация подключения к базе данных"""
        self.db_path = db_path
        self.conn = None
        self.cursor = None
        self.init_database()
        
    def init_database(self):
        """Создание таблиц базы данных, если они не существуют"""
        try:
            # Проверка существования файла базы данных
            db_exists = os.path.exists(self.db_path)
            
            # Подключение к базе данных (будет создана, если не существует)
            self.connect()
            
            # Включение внешних ключей для обеспечения целостности данных
            self.cursor.execute("PRAGMA foreign_keys = ON;")
            
            # Создаем таблицу для хранения результатов анализа логов
            self.cursor.execute('''
                CREATE TABLE IF NOT EXISTS log_analysis (
                    id INTEGER PRIMARY KEY AUTOINCREMENT,
                    agent_name TEXT NOT NULL,
                    log_text TEXT NOT NULL,
                    response TEXT NOT NULL,
                    json_answer TEXT,
                    processing_time REAL NOT NULL,
                    timestamp DATETIME DEFAULT CURRENT_TIMESTAMP
                )
            ''')
            
            # Проверяем, существует ли столбец json_answer в существующей таблице
            if db_exists:
                self.cursor.execute("PRAGMA table_info(log_analysis)")
                columns = [column[1] for column in self.cursor.fetchall()]
                
                if 'json_answer' not in columns:
                    print("Обновление структуры базы данных: добавление столбца json_answer...")
                    self.cursor.execute("ALTER TABLE log_analysis ADD COLUMN json_answer TEXT")
                    print("Столбец json_answer успешно добавлен в существующую базу данных.")
            
            # Создаем таблицу для хранения статистики обработки
            self.cursor.execute('''
                CREATE TABLE IF NOT EXISTS log_stats (
                    id INTEGER PRIMARY KEY AUTOINCREMENT,
                    start_time DATETIME NOT NULL,
                    end_time DATETIME,
                    total_logs INTEGER NOT NULL,
                    processed_logs INTEGER NOT NULL,
                    successful_logs INTEGER NOT NULL,
                    failed_logs INTEGER NOT NULL,
                    average_time REAL,
                    status TEXT NOT NULL
                )
            ''')
            
            # Сохраняем изменения
            self.conn.commit()
            
            # Проверяем, были ли таблицы созданы успешно
            self.cursor.execute("SELECT name FROM sqlite_master WHERE type='table' AND name IN ('log_analysis', 'log_stats')")
            tables = self.cursor.fetchall()
            
            if len(tables) < 2:
                logging.error("Не все таблицы были успешно созданы. Проверьте права доступа к базе данных.")
                print(f"Ошибка: не все таблицы были созданы в базе данных {self.db_path}")
                
            if not db_exists:
                logging.info(f"База данных {self.db_path} создана и инициализирована.")
                print(f"База данных {self.db_path} успешно создана.")
                
        except Exception as e:
            logging.error(f"Критическая ошибка при инициализации базы данных: {e}")
            print(f"Критическая ошибка при инициализации базы данных: {e}")
            
            # Пробуем удалить файл базы, если он существует, но поврежден
            if os.path.exists(self.db_path):
                try:
                    self.disconnect()
                    print(f"Пытаемся пересоздать базу данных {self.db_path}...")
                    os.remove(self.db_path)
                    # Повторная инициализация базы
                    self.connect()
                    
                    # Создаем таблицы заново
                    self.cursor.execute('''
                        CREATE TABLE IF NOT EXISTS log_analysis (
                            id INTEGER PRIMARY KEY AUTOINCREMENT,
                            agent_name TEXT NOT NULL,
                            log_text TEXT NOT NULL,
                            response TEXT NOT NULL,
                            json_answer TEXT,
                            processing_time REAL NOT NULL,
                            timestamp DATETIME DEFAULT CURRENT_TIMESTAMP
                        )
                    ''')
                    
                    self.cursor.execute('''
                        CREATE TABLE IF NOT EXISTS log_stats (
                            id INTEGER PRIMARY KEY AUTOINCREMENT,
                            start_time DATETIME NOT NULL,
                            end_time DATETIME,
                            total_logs INTEGER NOT NULL,
                            processed_logs INTEGER NOT NULL,
                            successful_logs INTEGER NOT NULL,
                            failed_logs INTEGER NOT NULL,
                            average_time REAL,
                            status TEXT NOT NULL
                        )
                    ''')
                    
                    self.conn.commit()
                    logging.info("База данных успешно пересоздана.")
                    print("База данных успешно пересоздана.")
                    
                except Exception as e2:
                    logging.error(f"Не удалось пересоздать базу данных: {e2}")
                    print(f"Не удалось пересоздать базу данных: {e2}")
        finally:
            self.disconnect()    
    def connect(self):
        """Установка соединения с базой данных"""
        self.conn = sqlite3.connect(self.db_path)
        self.cursor = self.conn.cursor()
    
    def disconnect(self):
        """Закрытие соединения с базой данных"""
        if self.conn:
            self.conn.close()
            self.conn = None
            self.cursor = None
    
    def extract_json_from_response(self, response_text):
        """Извлечение JSON из ответа агента с использованием регулярных выражений"""
        try:
            # Поиск JSON-объектов в тексте ответа
            # Ищем паттерн типа {"ключ": значение, ...}
            json_pattern = r'\{[^{}]*(?:"[^"]*"\s*:\s*[^,}]+[,}])+[^{}]*\}'
            
            matches = re.findall(json_pattern, response_text)
            
            if matches:
                # Пытаемся распарсить найденные JSON
                for match in matches:
                    try:
                        # Проверяем, является ли найденная строка валидным JSON
                        parsed_json = json.loads(match)
                        # Возвращаем первый успешно распарсенный JSON как строку
                        return json.dumps(parsed_json, ensure_ascii=False, indent=2)
                    except json.JSONDecodeError:
                        continue
            
            # Если стандартный поиск не дал результатов, попробуем более широкий поиск
            # Ищем любые фигурные скобки, которые могут содержать JSON
            broader_pattern = r'\{[^{}]*\}'
            broader_matches = re.findall(broader_pattern, response_text)
            
            for match in broader_matches:
                try:
                    parsed_json = json.loads(match)
                    return json.dumps(parsed_json, ensure_ascii=False, indent=2)
                except json.JSONDecodeError:
                    continue
            
            # Если JSON не найден, возвращаем None
            return None
            
        except Exception as e:
            logging.error(f"Ошибка при извлечении JSON из ответа: {e}")
            return None
    
    def save_log_analysis(self, agent_name, log_text, response, processing_time):
        """Сохранение результата анализа лога в базу данных"""
        try:
            self.connect()
            
            # Извлекаем JSON из ответа агента
            json_answer = self.extract_json_from_response(response)
            
            self.cursor.execute(
                "INSERT INTO log_analysis (agent_name, log_text, response, json_answer, processing_time) VALUES (?, ?, ?, ?, ?)",
                (agent_name, log_text, response, json_answer, processing_time)
            )
            self.conn.commit()
              # Логируем информацию о найденном JSON
            if json_answer:
                logging.info(f"JSON извлечен из ответа агента: {json_answer[:100]}...")
            else:
                logging.info("JSON не найден в ответе агента")
            
            return self.cursor.lastrowid
        except Exception as e:
            logging.error(f"Ошибка при сохранении анализа лога: {e}")
            return None
        finally:
            self.disconnect()
    
    def create_log_stats_session(self, total_logs):
        """Создание записи о новой сессии обработки логов"""
        try:
            self.connect()
            self.cursor.execute(
                "INSERT INTO log_stats (start_time, total_logs, processed_logs, successful_logs, failed_logs, status) VALUES (?, ?, ?, ?, ?, ?)",
                (datetime.datetime.now(), total_logs, 0, 0, 0, "running")
            )
            self.conn.commit()
            return self.cursor.lastrowid
        except Exception as e:
            logging.error(f"Ошибка при создании записи статистики: {e}")
            return None
        finally:
            self.disconnect()
    
    def update_log_stats(self, stats_id, processed=0, successful=0, failed=0, status=None):
        """Обновление статистики обработки логов"""
        try:
            self.connect()
            
            # Получение текущей статистики
            self.cursor.execute("SELECT processed_logs, successful_logs, failed_logs FROM log_stats WHERE id = ?", (stats_id,))
            row = self.cursor.fetchone()
            if not row:
                return False
            
            current_processed, current_successful, current_failed = row
            
            # Обновление статистики
            new_processed = current_processed + processed
            new_successful = current_successful + successful
            new_failed = current_failed + failed
            
            if status == "completed":
                # Финализация статистики при завершении
                end_time = datetime.datetime.now()
                
                # Расчет среднего времени обработки
                self.cursor.execute(
                    "SELECT AVG(processing_time) FROM log_analysis WHERE timestamp > (SELECT start_time FROM log_stats WHERE id = ?)",
                    (stats_id,)
                )
                avg_time = self.cursor.fetchone()[0] or 0
                
                self.cursor.execute(
                    "UPDATE log_stats SET processed_logs = ?, successful_logs = ?, failed_logs = ?, end_time = ?, average_time = ?, status = ? WHERE id = ?",
                    (new_processed, new_successful, new_failed, end_time, avg_time, status, stats_id)
                )
            else:
                # Обновление текущей статистики
                self.cursor.execute(
                    "UPDATE log_stats SET processed_logs = ?, successful_logs = ?, failed_logs = ? WHERE id = ?",
                    (new_processed, new_successful, new_failed, stats_id)
                )
                
                if status:
                    self.cursor.execute("UPDATE log_stats SET status = ? WHERE id = ?", (status, stats_id))
            
            self.conn.commit()
            return True
        except Exception as e:
            logging.error(f"Ошибка при обновлении статистики: {e}")
            return False
        finally:
            self.disconnect()
    
    def get_stats_summary(self):
        """Получение сводной статистики обработки логов"""
        try:
            self.connect()
            self.cursor.execute("""
                SELECT COUNT(*) as total_sessions, 
                       SUM(total_logs) as total_logs,
                       SUM(processed_logs) as processed_logs,
                       SUM(successful_logs) as successful_logs,
                       SUM(failed_logs) as failed_logs,
                       AVG(average_time) as avg_time
                FROM log_stats
            """)
            result = self.cursor.fetchone()
            if not result:
                return None
                
            return {
                "total_sessions": result[0],
                "total_logs": result[1] or 0,
                "processed_logs": result[2] or 0,
                "successful_logs": result[3] or 0,
                "failed_logs": result[4] or 0,
                "avg_time": result[5] or 0
            }
        except Exception as e:
            logging.error(f"Ошибка при получении сводной статистики: {e}")
            return None
        finally:
            self.disconnect()
    
    def get_recent_stats(self, limit=5):
        """Получение последних сессий обработки логов"""
        try:
            self.connect()
            self.cursor.execute("""
                SELECT id, start_time, end_time, total_logs, processed_logs, 
                       successful_logs, failed_logs, average_time, status
                FROM log_stats
                ORDER BY start_time DESC
                LIMIT ?
            """, (limit,))
            
            rows = self.cursor.fetchall()
            if not rows:
                return []
                
            stats = []
            for row in rows:
                stats.append({
                    "id": row[0],
                    "start_time": row[1],
                    "end_time": row[2],
                    "total_logs": row[3],
                    "processed_logs": row[4],
                    "successful_logs": row[5],
                    "failed_logs": row[6],
                    "average_time": row[7] or 0,
                    "status": row[8]
                })
            
            return stats
        except Exception as e:
            logging.error(f"Ошибка при получении последней статистики: {e}")
            return []
        finally:
            self.disconnect()


class LogProcessor:
    """Класс для обработки логов с использованием агента"""
    
    def __init__(self, rag_menu):
        """Инициализация процессора логов"""
        self.rag_menu = rag_menu  # Ссылка на основное меню
        self.db = Database()  # Создаем экземпляр класса для работы с БД
        self.processing_flag = False  # Флаг для управления обработкой
        self.paused = False  # Флаг для приостановки обработки
        self.processor_thread = None  # Поток для обработки логов
        self.current_stats_id = None  # ID текущей сессии в БД
        self.current_agent = None  # Текущий агент
        self.current_session = None  # Текущая сессия
        self.prompt_template = ""  # Шаблон промпта для отправки агенту
        self.log_queue = queue.Queue()  # Очередь для логов
        
        # Настройка логирования с явным указанием кодировки UTF-8
        logging.basicConfig(
            level=logging.INFO,
            format='%(asctime)s - %(levelname)s - %(message)s',
            handlers=[
                logging.FileHandler("log_processor.log", encoding='utf-8'),
                logging.StreamHandler(sys.stdout)  # Явно указываем вывод в stdout для корректной обработки Unicode
            ],
            force=True  # Принудительная перенастройка логирования
        )
    
    def load_logs_from_file(self, file_path):
        """Загрузка логов из файла в очередь обработки"""
        try:
            if not os.path.exists(file_path):
                logging.error(f"Файл логов не найден: {file_path}")
                return 0
                
            with open(file_path, 'r', encoding='utf-8') as file:
                lines = file.readlines()
                
            # Очистка очереди перед добавлением новых логов
            while not self.log_queue.empty():
                try:
                    self.log_queue.get_nowait()
                except queue.Empty:
                    break
              # Добавление строк в очередь
            for line in lines:
                line = line.strip()
                if line:  # Пропускаем пустые строки
                    self.log_queue.put(line)
                    
            return len(lines)
        except Exception as e:
            logging.error(f"Ошибка при загрузке логов из файла: {e}")
            return 0
    
    def select_prompt_template(self):
        """Выбор предустановленного шаблона промпта для обработки логов"""
        print("\nДоступные шаблоны промптов для анализа логов:")
        print(CONFIG['MENU_SEPARATOR'])
        
        prompt_options = []
        for idx, (key, prompt) in enumerate(CONFIG['PREDEFINED_PROMPTS'].items(), 1):
            print(f"{idx}. {key}")
            print(f"   {prompt[:50]}..." if len(prompt) > 50 else f"   {prompt}")
            print(CONFIG['MENU_SEPARATOR'])
            prompt_options.append((key, prompt))
        
        print(f"{len(prompt_options) + 1}. Ввести свой промпт")
        print(f"{len(prompt_options) + 2}. Не использовать промпты (отправлять логи как есть)")
        print(CONFIG['MENU_SEPARATOR'])
        
        while True:
            try:
                choice = int(input("\nВыберите шаблон промпта (0 для отмены): "))
                if choice == 0:
                    return None
                elif 1 <= choice <= len(prompt_options):
                    return prompt_options[choice - 1][1]
                elif choice == len(prompt_options) + 1:
                    custom_prompt = input("\nВведите свой шаблон промпта (используйте {} для вставки текста лога):\n")
                    return custom_prompt
                elif choice == len(prompt_options) + 2:
                    print("\nВыбрано: отправка логов агенту без использования промптов")
                    return "NO_PROMPT"  # Специальный маркер для отсутствия промпта
                else:
                    print(CONFIG['MESSAGES']['invalid_choice'])
            except ValueError:
                print("Пожалуйста, введите число.")
    
    def start_processing(self):
        """Запуск обработки логов"""
        if self.processing_flag:
            print("Обработка логов уже запущена!")
            return False
            
        # Выбор агента для обработки логов
        self.current_agent = self.rag_menu.select_agent()
        if not self.current_agent:
            return False
            
        # Создание новой сессии с агентом
        try:
            self.current_session = self.current_agent.create_session()
            print(f"\nСоздан новый сеанс с агентом '{self.current_agent.title}' для обработки логов")
            print(f"ID сеанса: {self.current_session.id}")
        except Exception as e:
            print(f"Ошибка при создании сеанса: {str(e)}")
            return False
            
        # Выбор шаблона промпта
        self.prompt_template = self.select_prompt_template()
        if not self.prompt_template:
            print("Обработка отменена: не выбран шаблон промпта.")
            return False
            
        # Загрузка логов из файла
        log_count = self.load_logs_from_file(LOG_FILE_PATH)
        if log_count == 0:
            print(f"Обработка отменена: файл логов пуст или не найден ({LOG_FILE_PATH}).")
            return False
            
        print(f"\nЗагружено {log_count} строк логов из файла {LOG_FILE_PATH}")
        
        # Создание записи о сессии обработки в БД
        self.current_stats_id = self.db.create_log_stats_session(log_count)
        if not self.current_stats_id:
            print("Ошибка при создании записи статистики в базе данных.")
            return False
            
        # Запуск потока обработки
        self.processing_flag = True
        self.paused = False
        self.processor_thread = threading.Thread(target=self.process_logs)
        self.processor_thread.daemon = True
        self.processor_thread.start()
        
        print("\nОбработка логов запущена...")
        return True
    
    def stop_processing(self):
        """Остановка обработки логов"""
        if not self.processing_flag:
            print("Обработка логов не запущена!")
            return False
            
        self.processing_flag = False
        if self.processor_thread:
            print("\nОстановка обработки логов...")
            self.processor_thread.join(timeout=3)  # Ожидание завершения потока
            
        # Обновление статуса в БД
        if self.current_stats_id:
            self.db.update_log_stats(self.current_stats_id, status="stopped")
            
        print("Обработка логов остановлена.")
        self.processor_thread = None
        return True
    
    def pause_processing(self):
        """Приостановка обработки логов"""
        if not self.processing_flag:
            print("Обработка логов не запущена!")
            return False
            
        if self.paused:
            print("Обработка уже приостановлена.")
            return False
            
        self.paused = True
        print("Обработка логов приостановлена. Используйте 'Возобновить' для продолжения.")
        return True
    
    def resume_processing(self):
        """Возобновление обработки логов"""
        if not self.processing_flag:
            print("Обработка логов не запущена!")
            return False
            
        if not self.paused:
            print("Обработка не приостановлена.")
            return False
            
        self.paused = False
        print("Обработка логов возобновлена.")
        return True
    
    def get_status(self):
        """Получение текущего статуса обработки"""
        if not self.processing_flag:
            return "Обработка не запущена"
            
        if self.paused:
            return "Обработка приостановлена"
            
        return "Обработка запущена"
    
    def process_logs(self):
        """Основная функция обработки логов в отдельном потоке"""
        processed_count = 0
        successful_count = 0
        failed_count = 0
        total_logs = self.log_queue.qsize()
        
        try:
            while self.processing_flag and not self.log_queue.empty():
                # Проверка приостановки
                if self.paused:
                    time.sleep(1)
                    continue
                      # Получение строки лога из очереди
                log_line = self.log_queue.get_nowait()
                current_log_number = total_logs - self.log_queue.qsize()
                  # Формирование промпта для агента
                if self.prompt_template == "NO_PROMPT":
                    # Отправляем строку лога как есть, без использования промпта
                    prompt = log_line
                    print(f"\n[{current_log_number}/{total_logs}] Отправка строки лога как есть: {log_line[:50]}...")
                else:
                    # Используем шаблон промпта
                    prompt = self.prompt_template.format(log_line)
                    print(f"\n[{current_log_number}/{total_logs}] Использование промпта для строки: {log_line[:50]}...")
                
                # Обработка строки лога
                try:
                    # Измерение времени обработки
                    start_time = time.time()
                    
                    # Реальный запрос к агенту
                    content = ""
                    try:
                        print("\nОжидание ответа от агента...", flush=True)
                        
                        # Строго синхронная обработка с блокировкой до получения ответа
                        # Увеличенный таймаут для ожидания ответа от агента
                        response = self.current_session.ask(prompt, stream=True)
                        
                        # Получение и отображение потокового ответа от агента
                        response_parts = []
                        for resp in response:
                            if resp and hasattr(resp, 'content'):
                                new_content = resp.content[len(content):]
                                content = resp.content
                                response_parts.append(new_content)
                                print(f"\rПолучен ответ от агента ({len(content)} символов)", end="", flush=True)
                                
                        # Объединение всех частей ответа
                        content = "".join(response_parts) if response_parts else ""
                        
                        if content:
                            print(f"\nПолучен полный ответ от агента ({len(content)} символов)")
                            print(f"Первые 100 символов ответа: {content[:100]}...")
                        else:
                            print("\nПолучен пустой ответ от агента!")
                            
                    except Exception as e:
                        logging.error(f"Ошибка при запросе к агенту: {e}")
                        print(f"\nОшибка при запросе к агенту: {e}")
                        raise
                            
                    # Расчет затраченного времени
                    end_time = time.time()
                    processing_time = end_time - start_time
                    print(f"Время обработки: {processing_time:.2f} секунд")
                    
                    # Сохранение результата в базу данных
                    if content:
                        # Сохраняем результат и ждем завершения операции
                        print("Сохранение результата в базу данных...")
                        result_id = self.db.save_log_analysis(
                            self.current_agent.title,
                            log_line,
                            content,
                            processing_time
                        )
                        
                        if result_id:
                            logging.info(f"Успешно обработана строка лога: {log_line[:50]}... (ID: {result_id})")
                            print(f"Результат сохранен в базу данных (ID: {result_id})")
                            successful_count += 1
                        else:
                            logging.error(f"Не удалось сохранить результат для лога: {log_line[:50]}...")
                            print("Не удалось сохранить результат в базу данных")
                            failed_count += 1
                    else:
                        # Если ответ пустой, считаем это неудачей
                        failed_count += 1
                        logging.warning(f"Пустой ответ от агента для лога: {log_line[:50]}...")
                        print("Сохранение информации о пустом ответе в базу данных...")
                        # Сохраняем информацию о пустом ответе в БД
                        self.db.save_log_analysis(
                            self.current_agent.title,
                            log_line,
                            "ERROR: Пустой ответ от агента",
                            processing_time
                        )
                        
                except Exception as e:
                    failed_count += 1
                    error_message = f"Ошибка при обработке лога: {str(e)}"
                    logging.error(error_message)
                    print(f"\n{error_message}")
                    
                    # Добавляем запись об ошибке в БД
                    try:
                        print("Сохранение информации об ошибке в базу данных...")
                        self.db.save_log_analysis(
                            self.current_agent.title if self.current_agent else "Unknown",
                            log_line,
                            f"ERROR: {str(e)}",
                            0.0
                        )
                        print("Информация об ошибке сохранена")
                    except Exception as db_error:
                        logging.error(f"Не удалось сохранить ошибку в БД: {db_error}")
                        print(f"Не удалось сохранить информацию об ошибке: {db_error}")
                
                # Увеличиваем счетчик обработанных строк
                processed_count += 1
                
                # Обновление статистики в БД для каждой обработанной строки
                try:
                    print("Обновление статистики обработки...")
                    self.db.update_log_stats(
                        self.current_stats_id, 
                        processed=1,
                        successful=1 if successful_count > 0 else 0,
                        failed=1 if failed_count > 0 else 0
                    )
                    print("Статистика обновлена")
                    # Сбрасываем счетчики после обновления
                    successful_count = 0
                    failed_count = 0
                except Exception as e:
                    logging.error(f"Ошибка при обновлении статистики: {e}")
                    print(f"Ошибка при обновлении статистики: {e}")
                
                print("\n" + CONFIG['MENU_SEPARATOR'])
                # Задержка между обработками для снижения нагрузки
                time.sleep(LOG_PROCESSING_DELAY)
            
            # Завершение обработки
            if self.processing_flag:  # Если обработка не была остановлена принудительно
                # Финальное обновление статистики
                print("\nЗавершение обработки логов и обновление статистики...")
                self.db.update_log_stats(
                    self.current_stats_id,
                    status="completed"
                )
                logging.info("Обработка логов завершена")
                print("Обработка логов успешно завершена!")
                self.processing_flag = False
                
        except Exception as e:
            logging.error(f"Критическая ошибка в процессе обработки логов: {str(e)}")
            print(f"\nКритическая ошибка: {str(e)}")
            # Обновление статуса в БД
            try:
                self.db.update_log_stats(self.current_stats_id, status="error")
                print("Статус обработки в БД обновлен на 'error'")
            except Exception:
                pass
            self.processing_flag = False
    
    def show_statistics(self):
        """Отображение статистики обработки логов"""
        # Получение сводной статистики
        summary = self.db.get_stats_summary()
        if not summary:
            print("Нет данных о статистике обработки логов.")
            return
            
        print("\nОбщая статистика обработки логов:")
        print(CONFIG['MENU_SEPARATOR'])
        print(f"Всего сессий: {summary['total_sessions']}")
        print(f"Всего строк логов: {summary['total_logs']}")
        print(f"Обработано строк: {summary['processed_logs']} ({summary['processed_logs']/max(1, summary['total_logs'])*100:.1f}%)")
        print(f"Успешно обработано: {summary['successful_logs']}")
        print(f"Ошибок обработки: {summary['failed_logs']}")
        print(f"Среднее время обработки: {summary['avg_time']:.2f} сек.")
        print(CONFIG['MENU_SEPARATOR'])
        
        # Получение последних сессий
        recent_stats = self.db.get_recent_stats(5)
        if recent_stats:
            print("\nПоследние сессии обработки:")
            for stats in recent_stats:
                duration = "N/A"
                if stats["end_time"]:
                    start = datetime.datetime.fromisoformat(stats["start_time"])
                    end = datetime.datetime.fromisoformat(stats["end_time"])
                    duration = str(end - start)
                
                print(CONFIG['MENU_SEPARATOR'])
                print(f"Сессия #{stats['id']} ({stats['status']})")
                print(f"Начало: {stats['start_time']}")
                print(f"Продолжительность: {duration}")
                print(f"Обработано: {stats['processed_logs']}/{stats['total_logs']} строк")
                print(f"Успешно: {stats['successful_logs']}, Ошибок: {stats['failed_logs']}")
                if stats['average_time']:
                    print(f"Среднее время: {stats['average_time']:.2f} сек.")
                    
        print(CONFIG['MENU_SEPARATOR'])


def main():
    """Основная функция для запуска меню RAGFlow"""
    try:
        # Парсинг аргументов командной строки
        args = parse_arguments()
        
        # Применение настроек из аргументов командной строки
        if args.no_references:
            CONFIG['SHOW_REFERENCES'] = False
        if args.no_streaming:
            CONFIG['ENABLE_STREAMING'] = False
        
        # Обработка CLI команд
        if args.list_agents:
            # Показать список агентов
            success = cli_list_agents()
            sys.exit(0 if success else 1)
            
        elif args.create_session:
            # Создать сеанс с агентом
            agent, session = cli_create_session(args.agent_id, args.agent_title)
            sys.exit(0 if agent and session else 1)
            
        elif args.send:
            # Отправить сообщение агенту
            success = cli_send_message(
                message=args.send,
                agent_id=args.agent_id,
                agent_title=args.agent_title,
                session_id=args.session_id,
                create_new_session=args.new_session
            )
            sys.exit(0 if success else 1)
            
        else:
            # Если аргументы не переданы, запускаем интерактивное меню
            menu = RAGFlowMenu()
            menu.show_menu()
            
    except KeyboardInterrupt:
        print("\nПрограмма завершена пользователем")
        sys.exit(0)
    except Exception as e:
        print(f"\nКритическая ошибка: {str(e)}")
        sys.exit(1)


if __name__ == "__main__":
    main()
