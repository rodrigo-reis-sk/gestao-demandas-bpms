# Edge Functions

Funções no servidor do Supabase (TypeScript/Deno). Usam os tokens do ClickUp fora do navegador.
São as **únicas** peças com "clickup" no nome: no dia em que sairmos do ClickUp, basta desligá-las (D10).

| Função | Fase | Situação | O que faz |
|---|---|---|---|
| `clickup-conectar` | 1 | pronta | Conecta a conta do gestor: OAuth (código → token) ou token pessoal `pk_` (D19). Confere `GET /user` = e-mail de login, grava o token no Vault e a linha em `contas_integracao` |
| `clickup-sync` | 1 | pronta | Varredura (pg_cron a cada 20 min ou botão): membros → consultores, pastas/listas → `clientes_faps`, tarefas alteradas de consultor **e** lista marcados, registros de tempo. Log em `sincronizacoes`. Também registra o webhook (`{"acao":"registrar_webhook"}`) |
| `clickup-webhook` | 1 | pronta | Confere `X-Signature`, busca a tarefa completa e grava; tarefa apagada é marcada; grava quem alterou em `tarefas_historico` |
| `formulario` | 3 | pronta (falta publicar) | Formulário do consultor e complemento (D57–D60): confere a chave do link, campo-armadilha e limite por IP; confere o tipo real dos prints, guarda no bucket privado `evidencias` e grava o chamado. Portal do cliente (D62–D64): ações `portal` (lista do cliente) e `abrir_portal` (chamado do cliente) |
| `clickup-criar` | 4 | pronta (falta publicar) | Botão "Aprovar e criar no ClickUp" da triagem (D65–D70): token do gestor que clicou (`ler_token_usuario`; reserva `CLICKUP_TOKEN`), regra do legado (acesso à pasta, `1-Atendimento Base`, mês, tarefa `CH-xxxxx - Título` com campos, dev + consultor, descrição) e prints anexados; ação `reenviar_prints` |
| `acessos` | 4 | pronta (falta publicar) | Tela Consultores (D75): cria/reativa o login no Supabase Auth com o e-mail do cadastro e senha temporária, nova senha e tirar acesso; regras no banco (0013). Sem nome de ferramenta externa: não é integração |
| `clickup-consulta` | desvio | pronta (falta publicar) | Consulta **ao vivo** no ClickUp, sem gravar no banco (tela `personalizacao.html`): tudo com a etapa "Personalização / Customização" + tarefas das pessoas da lista com outra etapa (revisar). Regra em `_compartilhado/clickup-consulta.ts` (teste `consulta.test.ts`) |

`_compartilhado/`: `base.ts` (banco, login, CORS), `clickup-api.ts` (chamadas com limite de cota, tempo
máximo, repetição e trava de páginas — lições do legado), `clickup-traducao.ts` (formato do ClickUp →
formato genérico do banco; constantes copiadas de `config/clickup.json`), `clickup-criacao.ts` (regra de criação
do legado, testada em `supabase/testes/criacao.test.ts`).

**Quem pode chamar:** todas têm `verify_jwt = false` em `supabase/config.toml` e conferem o acesso no
código — `clickup-conectar` exige gestor logado; `clickup-sync` exige gestor logado **ou** a chave do
agendamento (Vault); `clickup-webhook` exige a assinatura do ClickUp; `formulario` exige a chave do link (ou o token do complemento);
`clickup-criar` e `acessos` exigem gestor logado.
Regras do formulário sem banco em `_compartilhado/formulario-regras.ts` (testadas em `supabase/testes/formulario.test.ts`).

**Segredos** (`npx supabase secrets set ...`): `CLICKUP_CLIENT_ID`, `CLICKUP_CLIENT_SECRET`. Opcionais:
`CLICKUP_TEAM_ID`, `CLICKUP_TOKEN` (plano B, D12). Tokens dos gestores, segredo do webhook e chave do
agendamento ficam no Supabase Vault (D21). URL e chave de serviço do Supabase já existem nas funções.

**Publicar:** `npx supabase@latest functions deploy --use-api`. **Testar:** `bash supabase/testes/rodar.sh`
(com Deno instalado) ou `deno test --allow-write=supabase/testes supabase/testes/funcoes.test.ts`.
