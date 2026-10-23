@echo off
rem Instala as bibliotecas do Python usadas pelo Lançar ClickUp.
where py >nul 2>nul && (set "PY=py") || (set "PY=python")
%PY% --version >nul 2>nul || (echo Python nao encontrado. Instale em https://www.python.org/downloads/ marcando "Add python.exe to PATH". & pause & exit /b 1)
%PY% -m pip install --user requests keyring
echo.
echo Pronto. Agora rode Configurar_Token_ClickUp.bat.
pause
