# Edge Functions

Funções no servidor do Supabase (TypeScript/Deno). Usam os tokens do ClickUp fora do navegador.
São as **únicas** peças com "clickup" no nome: no dia em que sairmos do ClickUp, basta desligá-las (D10).

| Função | Fase | Situação | O que faz |
|---|---|---|---|
| `clickup-conectar` | 1 | pronta | Conecta a conta do gestor: OAuth (código → token) ou token pessoal `pk_` (D19). Confere `GET /user` = e-mail de login, grava o token no Vault e a linha em `contas_integracao` |
| `clickup-sync` | 1 | pronta | Varredura (pg_cron a cada 20 min ou botão): membros → consultores, pastas/listas → `clientes_faps`, tarefas alteradas de consultor **e** lista marcados, registros de tempo. Log em `sincronizacoes`. Também registra o webhook (`{"acao":"registrar_webhook"}`) |
| `clickup-webhook` | 1 | pronta | Confere `X-Signature`, busca a tarefa completa e grava; tarefa apagada é marcada; grava quem alterou em `tarefas_historico` |
| `formulario` | 3 | a criar | Formulário do consultor e portal do cliente |
| `clickup-criar` | 4 | a criar | Cria a tarefa no ClickUp com o token do gestor que clicou (`ler_token_usuario`) |

`_compartilhado/`: `base.ts` (banco, login, CORS), `clickup-api.ts` (chamadas com limite de cota, tempo
máximo, repetição e trava de páginas — lições do legado), `clickup-traducao.ts` (formato do ClickUp →
formato genérico do banco; constantes copiadas de `config/clickup.json`).

**Quem pode chamar:** todas têm `verify_jwt = false` em `supabase/config.toml` e conferem o acesso no
código — `clickup-conectar` exige gestor logado; `clickup-sync` exige gestor logado **ou** a chave do
agendamento (Vault); `clickup-webhook` exige a assinatura do ClickUp.

**Segredos** (`npx supabase secrets set ...`): `CLICKUP_CLIENT_ID`, `CLICKUP_CLIENT_SECRET`. Opcionais:
`CLICKUP_TEAM_ID`, `CLICKUP_TOKEN` (plano B, D12). Tokens dos gestores, segredo do webhook e chave do
agendamento ficam no Supabase Vault (D21). URL e chave de serviço do Supabase já existem nas funções.

**Publicar:** `npx supabase@latest functions deploy --use-api`. **Testar:** `bash supabase/testes/rodar.sh`
(com Deno instalado) ou `deno test --allow-write=supabase/testes supabase/testes/funcoes.test.ts`.
