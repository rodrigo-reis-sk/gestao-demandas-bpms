"""
Sincronização ClickUp <-> Sankhya Experience -- organizado por funcionalidade:

  config.py          - credenciais, IDs de campos, opções, PARCEIRO_FAP
  clickup_client.py  - chamadas diretas à API do ClickUp
  text_matching.py   - normalização e comparação aproximada de texto
  list_discovery.py  - descoberta de listas por nome + extração de FAP
  scheduling.py       - período e conflito de horário
  sync_engine.py      - motor de decisão (Criar/Alterar/Excluir/Ignorar)
  report.py           - impressão do relatório final
  ui_prompts.py        - pop-ups de entrada e confirmação

Ver main.py na raiz do projeto para o ponto de entrada.
"""
