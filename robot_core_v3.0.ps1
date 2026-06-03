@echo off
chcp 1251 > nul

rem ================================================
rem  AZS_Mail_Robot_v3.0 - ИНСТАЛЛЯТОР
rem ================================================

net session >nul 2>&1
if %errorLevel% neq 0 (
    echo [ОШИБКА] Запустите от имени администратора!
    pause
    exit /b
)

if not exist "%~dp0robot_core_v3.0.ps1" (
    echo [ОШИБКА] Файл robot_core_v3.0.ps1 не найден!
    pause
    exit /b
)

rem ================================================
rem  ОЧИСТКА СТАРОЙ ВЕРСИИ
rem ================================================
echo.
echo ================================================
echo    ОЧИСТКА СТАРОЙ ВЕРСИИ
echo ================================================

echo [*] Остановка старых процессов...
taskkill /F /IM powershell.exe >nul 2>&1
echo [OK] Процессы остановлены

echo [*] Удаление старых задач...
set "OLD_TASKS=AZS_Report_Send AZS_Mail_Robot AZS_Mail_Robot_v2 AZS_Watcher AZS_Gumrak_Watcher_Send AZS_Gumrak_Downloader_Receive"
for %%t in (%OLD_TASKS%) do (
    schtasks /Delete /TN "%%t" /F >nul 2>&1
)
echo [OK] Старые задачи удалены

rem ================================================
rem  УСТАНОВКА
rem ================================================

echo [*] Создание папок...
if not exist "C:\Scripts" mkdir "C:\Scripts"
if not exist "C:\Scripts\Logs" mkdir "C:\Scripts\Logs"
if not exist "C:\Scripts\Отчеты" mkdir "C:\Scripts\Отчеты"
echo [OK] Папки созданы

rem Запрос параметров
echo.
echo ================================================
echo    НАСТРОЙКА AZS MAIL ROBOT v3.0
echo ================================================
echo.

set /p "AZS_NAME_RU=Название АЗС (рус): "
if "%AZS_NAME_RU%"=="" exit /b

set /p "AZS_NAME_EN=Название АЗС (англ): "
if "%AZS_NAME_EN%"=="" exit /b

set /p "SENDER_EMAIL=Email отправителя: "
if "%SENDER_EMAIL%"=="" exit /b

set /p "EMAIL_PASSWORD=Пароль: "
if "%EMAIL_PASSWORD%"=="" exit /b

set /p "TARGET_EMAIL=Email получателя [obmenazs@vtk34.ru]: "
if "%TARGET_EMAIL%"=="" set "TARGET_EMAIL=obmenazs@vtk34.ru"

set /p "EXPORT_PATH=Путь к папке Export: "
if "%EXPORT_PATH%"=="" exit /b

echo.
echo Настройки по умолчанию (нажмите Enter):
set /p "WORK_START=Время начала мониторинга [07:30]: "
if "%WORK_START%"=="" set "WORK_START=07:30"

set /p "WORK_END=Время окончания [09:30]: "
if "%WORK_END%"=="" set "WORK_END=09:30"

set /p "STARTUP_DELAY=Задержка после загрузки (сек) [7200]: "
if "%STARTUP_DELAY%"=="" set "STARTUP_DELAY=7200"

set /p "UPDATE_URL=URL сервера обновлений [https://adminvtk34.github.io/azs-updates]: "
if "%UPDATE_URL%"=="" set "UPDATE_URL=https://adminvtk34.github.io/azs-updates"

rem Создание config_azs.json
echo [*] Создание config_azs.json...
(
echo {
echo     "azs_name_ru": "%AZS_NAME_RU%",
echo     "azs_name_en": "%AZS_NAME_EN%",
echo     "watch_folder": "%EXPORT_PATH:\=\\%",
echo     "smtp_server": "mail.hosting.reg.ru",
echo     "smtp_port": 587,
echo     "sender_email": "%SENDER_EMAIL%",
echo     "password": "%EMAIL_PASSWORD%",
echo     "target_email": "%TARGET_EMAIL%",
echo     "work_start_time": "%WORK_START%",
echo     "work_end_time": "%WORK_END%",
echo     "startup_delay": %STARTUP_DELAY%,
echo     "idle_interval": 600,
echo     "active_interval": 30,
echo     "update_server": "%UPDATE_URL%",
echo     "current_version": "3.0",
echo     "install_date": "%DATE%"
echo }
) > "C:\Scripts\config_azs.json"
echo [OK] Конфиг создан

rem Копирование скрипта
echo [*] Установка скрипта...
copy "%~dp0robot_core_v3.0.ps1" "C:\Scripts\robot_core_v3.0.ps1" /Y > nul
echo [OK] Скрипт установлен

rem Настройка PowerShell
echo [*] Настройка PowerShell...
powershell -Command "Set-ExecutionPolicy Unrestricted -Force" > nul
echo [OK] Готово

rem Создание задачи
echo [*] Создание задачи в планировщике...
schtasks /Create ^
    /TN "AZS_Mail_Robot_v3" ^
    /TR "powershell.exe -ExecutionPolicy Bypass -WindowStyle Hidden -File 'C:\Scripts\robot_core_v3.0.ps1'" ^
    /SC ONSTART ^
    /RL HIGHEST ^
    /F > nul
echo [OK] Задача создана

rem Запуск
echo [*] Запуск робота...
schtasks /Run /TN "AZS_Mail_Robot_v3" > nul
echo [OK] Робот запущен

rem Сохранение информации
(
echo ================================================
echo   AZS Mail Robot v3.0
echo   Дата установки: %DATE% %TIME%
echo ================================================
echo АЗС: %AZS_NAME_RU% (%AZS_NAME_EN%)
echo Отправитель: %SENDER_EMAIL%
echo Получатель: %TARGET_EMAIL%
echo Папка Export: %EXPORT_PATH%
echo Мониторинг: %WORK_START% - %WORK_END%
echo Сервер обновлений: %UPDATE_URL%
echo Скрипт: C:\Scripts\robot_core_v3.0.ps1
echo Конфиг: C:\Scripts\config_azs.json
echo Задача: AZS_Mail_Robot_v3
echo ================================================
) > "C:\Scripts\install_info.txt"

echo.
echo ====================================================
echo  [УСПЕХ] АЗС "%AZS_NAME_RU%" настроена!
echo  Версия: 3.0 (с автообновлением)
echo  Сервер обновлений: %UPDATE_URL%
echo ====================================================
pause
