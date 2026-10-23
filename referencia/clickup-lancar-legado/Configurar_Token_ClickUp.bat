@echo off
cd /d "%~dp0"
where pyw >nul 2>nul && (start "" pyw configurar_token.py) || (start "" pythonw configurar_token.py)
