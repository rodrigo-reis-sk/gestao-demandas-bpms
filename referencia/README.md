# Referências

Material de apoio. **Não é código do sistema novo**: serve para consulta e para reaproveitar regras.

## `clickup-lancar-legado/`

Cópia (22/10/2026) do pacote **"Lançar ClickUp BP-MS"** que está em uso hoje
(autoria: Marcelo Fragoso, v1.1.0). Ele cria tarefas no ClickUp pelo navegador
(`http://127.0.0.1:8766`) com um serviço Python local e o token pessoal guardado no cofre do
Windows. Nenhum token ou senha vem no pacote. O `firebase-config.js` só identifica o projeto
Firebase da Central BP-MS e não dá acesso a nada.

O que reaproveitar:

| Arquivo | O que tem de útil |
|---|---|
| `motores/clickup_sync/config.py` | IDs dos campos, opções, espaço PMO BP-MS, pastas ignoradas, De-Para de consultores, caso "BPMS" por FAP |
| `motores/clickup_sync/clickup_client.py` | Chamadas com repetição, controle de limite (429) e tempo máximo |
| `motores/clickup_sync/list_discovery.py` | Descoberta de pastas/listas e extração da FAP |
| `motores/clickup_sync/text_matching.py` | Comparação tolerante de nomes (acentos, erros de digitação) |
| `motores/clickup_tasks/lancar_tarefas_clickup.py` | Regra de criação: Atendimento Base → subtarefa do mês → tarefa; opções de Parceiro, Origem e Período |
| `central/servico/app_lancar.py` | Validações do lançamento e envio de anexos |

Os dados úteis já foram extraídos para `config/clickup.json` e `supabase/seed.sql`.
Se o legado mudar (campo novo, opção nova), atualize os dois.

## `prototipos/formulario-demandas.html`

Protótipo do formulário de demandas publicado como artifact no claude.ai (versão 2):
campos do pedido, evidências em passos com prints na sequência, rascunho salvo no
navegador e lista de demandas com status. Na fase 3 ele vira `web/formulario.html`,
gravando no Supabase pela Edge Function `formulario`.
