"""
Credenciais do pacote "Lançar ClickUp": só o token PESSOAL do ClickUp de quem usa,
guardado no Gerenciador de Credenciais do Windows (rode Configurar_Token_ClickUp.bat).
"""
import keyring

SERVICO = "sankhya_experience_sync"
CLICKUP_TOKEN = keyring.get_password(SERVICO, "CLICKUP_TOKEN")
EXPERIENCE_USER = keyring.get_password(SERVICO, "EXPERIENCE_USER")  # não usado no Lançar
EXPERIENCE_PASS = keyring.get_password(SERVICO, "EXPERIENCE_PASS")  # não usado no Lançar

if not CLICKUP_TOKEN:
    raise RuntimeError("Token do ClickUp não configurado. Rode Configurar_Token_ClickUp.bat.")
