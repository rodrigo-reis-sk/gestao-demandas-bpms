# 08 — Implantação (passo a passo)

Roteiro para colocar a fase 1 no ar. Comandos no **PowerShell**, dentro de
`C:\github\Gestao-Demandas-BPMS`. Precisa do **Node.js 18+** (para o `npx`). Não precisa de Docker.

> **Segredos nunca vão para arquivo nem para o chat.** Senha do banco, Client Secret do ClickUp,
> token `pk_` e chave `service_role` ficam só no gerenciador de senhas e nos segredos do Supabase.

## 1. Supabase

1. supabase.com → **New project**: nome `gestao-demandas-bpms`, região **South America (São Paulo)**,
   plano Free. Guarde a senha do banco.
2. *Authentication → Sign In / Providers*: deixe **Email** ligado e **desligue "Allow new users to sign up"**.
   O login é por **e-mail e senha** (D20): o envio de e-mails do plano Free é muito limitado.
3. Anote o **project ref** (o pedaço `xxxx` de `https://xxxx.supabase.co`).

## 2. Banco (migrações + dados iniciais)

```powershell
npx supabase@latest login
npx supabase@latest link --project-ref SEU_REF        # pede a senha do banco
npx supabase@latest db push --include-seed            # roda 0001, 0002 e o seed.sql
```

Conferir no painel (*Table Editor*): `consultores` com 18 pessoas, `clientes_faps` com 31 FAPs "a_analisar".

## 3. Segredos das Edge Functions

Caminho principal (D11 — app OAuth criado no teste P9):

```powershell
npx supabase@latest secrets set CLICKUP_CLIENT_ID=... CLICKUP_CLIENT_SECRET=...
```

Opcionais:

| Segredo | Quando usar |
|---|---|
| `CLICKUP_TEAM_ID` | Se o token enxergar mais de um workspace (sem ele, usa o primeiro, como o legado) |
| `CLICKUP_TOKEN` | **Plano B (D12)**: token único `pk_` de reserva, usado só quando não há conta da sincronização conectada |

Não é preciso configurar o segredo do webhook: ele vai sozinho para o Vault quando o webhook é registrado pela tela.

## 4. Edge Functions

```powershell
npx supabase@latest functions deploy --use-api
```

Publica `clickup-conectar`, `clickup-sync` e `clickup-webhook` (configuração em `supabase/config.toml`).

## 5. Agendamento (a cada 20 min)

No *SQL Editor* do Supabase:

```sql
select public.agendar_sincronizacao('https://SEU_REF.supabase.co');
```

Cria dois agendamentos no `pg_cron`: a varredura e a limpeza semanal do log (guarda 90 dias).
Para mudar o intervalo: altere `intervalo_minutos` em `configuracoes` (chave `sincronizacao`) e rode de novo.

## 6. Primeiro acesso (gestor admin)

1. *Authentication → Users → Add user → Create new user*: e-mail **igual ao do ClickUp**, senha, marque *Auto Confirm User*.
2. No *SQL Editor*:

```sql
insert into public.usuarios_sistema (id, nome, email, papel)
select id, 'Rodrigo Reis', email, 'admin' from auth.users where email = 'rodrigo.reis@sankhya.com.br';
```

Outros gestores: mesmo caminho, com `papel = 'gestor'`. Esqueceu a senha: o admin troca em *Authentication → Users*.

## 7. Telas no GitHub Pages

1. Preencha `web/config.js` com a URL do projeto, a **anon/publishable key** e o **Client ID** do app OAuth
   (são valores públicos; podem ir para o git).
2. Copie `infra/pages.yml` para `.github/workflows/pages.yml` (o Claude não consegue gravar na pasta
   `.github` pela ponte com o seu computador). No PowerShell:
   `New-Item -ItemType Directory -Force .github\workflows; Copy-Item infra\pages.yml .github\workflows\pages.yml`
3. Primeiro push para o repositório no GitHub (branch `main`):
   ```powershell
   git init -b main
   git add .
   git commit -m "Fase 1: banco, sincronização com o ClickUp e telas mínimas"
   git remote add origin https://github.com/rodrigo-reis-sk/gestao-demandas-bpms.git
   git push -u origin main
   ```
4. No GitHub: *Settings → Pages → Source = **GitHub Actions***. O workflow `.github/workflows/pages.yml`
   publica a pasta `web/` a cada push. Endereço: `https://rodrigo-reis-sk.github.io/gestao-demandas-bpms/`.
   (Pages em repositório privado exige plano pago do GitHub; em repositório público não há problema,
   porque nenhum segredo vai para o git.)
5. No app OAuth do ClickUp, a Redirect URL deve ser o domínio `rodrigo-reis-sk.github.io`.

## 8. Ligar a sincronização (pela tela)

1. Entrar → **Meu perfil** → *Conectar com o ClickUp*. A primeira conta conectada vira a
   **conta da sincronização** (dá para trocar na mesma tela; use a de um gestor admin do ClickUp).
2. **Meu perfil** → *Registrar webhook*.
3. **Log** → *Sincronizar agora*: descobre membros (liga consultores pelo e-mail) e todas as listas.
4. **Consultores**: marque os 5 do piloto.
5. **Listas**: marque *Sincronizar* nas listas do piloto (as novas ficam no topo, em amarelo).
6. **Log** → *Sincronizar agora* de novo: como há consultor/lista recém-marcados, ele busca os últimos 90 dias.

## 9. Validação do piloto (listas do piloto)

Revisado em 23/10/2026 para as regras da fase 2 (D32, D39, D41, D48). Conferência de horas de 3 demandas
contra o ClickUp fica na fase 2.

- [ ] **Listas:** encerradas ("Z" / "Concluída") chegaram como *Não sincronizar* (D18); as novas, como *a analisar*.
- [ ] **Carga:** o Log mostra "Carga em andamento… faltam N lista(s)" até zerar, sem erro.
- [ ] **Demandas:** as tarefas das listas marcadas aparecem na tela Demandas; "1-Atendimento Base" e "AAAA-MM Mês" **não** aparecem como demanda.
- [ ] **Webhook:** mudar o status de uma tarefa no ClickUp → em segundos aparece no Log como *webhook · atualizada*, e em `tarefas_historico` com quem alterou.
- [ ] **↻ Sincronizar da demanda:** alterar algo no ClickUp e clicar no botão → o cartão atualiza na hora e o Log ganha uma linha *manual* (D48).
- [ ] **Tempo:** registrar tempo numa tarefa → na próxima varredura aparece em `registros_tempo`.
- [ ] **Exclusão:** apagar uma tarefa de teste no ClickUp → `excluida_na_origem = true` (a linha não some).
- [ ] **Lista não marcada:** tarefa de lista não marcada não entra (exceção: tarefa-mãe que falta, D39).
- [ ] **Conta BPMS:** tarefa da conta "BPMS" na FAP 32222 (Soldamaq) aparece com o Cleber como responsável.
- [ ] **Rotina:** o Log mostra varreduras a cada 20 min, sem erro, por 2–3 dias.

## 10. Fase 3 — formulário do consultor e triagem (26/10/2026)

```powershell
npx supabase@latest db push                                   # aplica a 0009_chamados.sql
npx supabase@latest functions deploy formulario --use-api     # publica a função nova
git push                                                      # publica formulario, complementar e triagem no Pages
```

Conferir no painel: bucket **evidencias** em *Storage* (privado) e a chave `chave_formulario` em *Vault*.
Se o `db push` recusar a política em `storage.objects`, rode o trecho "7. Bucket privado" da 0009 no SQL Editor.

Testes (marcar ao conferir):

- [ ] **Link:** Triagem → *Link do formulário* → abrir numa aba anônima. Sem `?k=` ou com chave errada: "Formulário indisponível".
- [ ] **Listas:** aparecem os clientes com lista marcada, os consultores marcados e os gerentes; escolher o cliente sugere o gerente.
- [ ] **Rascunho:** preencher, colar um print (Ctrl+V), fechar a aba e abrir de novo → volta tudo, com o print.
- [ ] **Envio:** registrar → aparece o código `CH-xxxxx`; o menu **Triagem** ganha o contador; os prints abrem na triagem.
- [ ] **Pedir informação:** escrever a pergunta → o link é copiado; abrir o link, responder com um print → o chamado volta para "Novo"
      com os passos marcados como *complemento*; abrir o link de novo → "não vale mais".
- [ ] **Aprovar:** escolher dev e consultor → *Aprovar* → copiar o nome; criar a tarefa no ClickUp na lista sugerida com esse nome
      → depois da sincronização (ou na hora, pelo webhook) o chamado fica "Tarefa criada" com o link da tarefa.
- [ ] **Recusar:** exige motivo; *Voltar para novo* desfaz.
- [ ] **Trocar chave:** o link antigo para de funcionar na hora.
- [ ] **Limite:** o 11º envio na mesma hora, do mesmo endereço, recebe "Muitos envios seguidos".
- [ ] **Prints grandes:** um envio com ~10 prints chega inteiro (se a função recusar pelo tamanho, baixar `max_total_kb` em `configuracoes.formulario`).

## Problemas comuns

| Sintoma | O que fazer |
|---|---|
| Log: "Nenhuma conta do ClickUp conectada" | Conectar a conta em Meu perfil (ou configurar `CLICKUP_TOKEN`) |
| Log: "O ClickUp recusou o token" | A conta da sincronização ficou em "erro": reconectar em Meu perfil |
| Webhook não chega | Meu perfil → Ver situação. Se "failing"/"suspended", Registrar/refazer |
| "Acesso não liberado" no login | Falta a linha em `usuarios_sistema` (passo 6) |
| Formulário: "Link do formulário inválido" | A chave foi trocada: copie o link de novo na Triagem |
| Triagem sem os prints | Conferir o bucket `evidencias` e a política `gestor_le_evidencias` em `storage.objects` |
| Varredura não roda sozinha | `select * from cron.job;` e `select * from net._http_response order by created desc limit 5;` |
