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

## 11. Fase 3 — portal do cliente (26/10/2026)

```powershell
npx supabase@latest db push                                   # aplica a 0010_portal.sql
npx supabase@latest functions deploy formulario --use-api     # função com as ações do portal
git add CLAUDE.md docs supabase web
git commit -m "Fase 3: portal do cliente (D62-D64)"
git push
```

Testes (marcar ao conferir):

- [ ] **Criar link:** Triagem → *Links do portal dos clientes* → escolher o cliente → *Criar link* (o link é copiado).
- [ ] **Portal:** abrir o link numa aba anônima → aparece "Chamados · <cliente>" com os chamados já abertos pelos consultores.
- [ ] **Abrir chamado:** *+ Abrir chamado* com um print colado → aparece na lista como *Recebido* e na Triagem com o selo **portal**.
- [ ] **Pedir informação:** na Triagem, pedir informação no chamado do portal → no portal aparece *Precisamos de informação* →
      *Responder* → enviar → *Voltar ao portal*: o chamado volta para *Recebido* e, na Triagem, para *Novo*.
- [ ] **Andamento:** depois de aprovar e criar a tarefa no ClickUp com o código → *Em atendimento*; concluir a tarefa → *Concluído*.
- [ ] **Recusa:** recusar com motivo → o portal mostra *Não aprovado* e o motivo.
- [ ] **Desativar:** desativar o link → o portal mostra "Este link do portal não vale mais".

## 12. Fase 4 — criar no ClickUp pela triagem (26/10/2026)

Se o §11 (portal) ainda não foi publicado, o mesmo `db push` aplica a 0010 e a 0011 juntas.

```powershell
npx supabase@latest db push                                      # aplica a 0011_criacao_tarefa.sql
npx supabase@latest functions deploy clickup-criar --use-api     # função nova
git add supabase web docs CLAUDE.md
git commit -m "Fase 4: criar no ClickUp pela triagem (D65-D72)"
git push                                                         # publica a triagem nova no Pages
```

Antes de testar: a sua conta do ClickUp conectada em **Meu perfil** e a lista do cliente marcada para sincronizar.
Use um chamado de teste numa lista de teste (ou num cliente piloto) e apague a tarefa no ClickUp depois.

Testes (marcar ao conferir):

- [ ] **Criar:** chamado novo com 2 prints → escolher dev e consultor, a lista e *Aprovar e criar no ClickUp* → aviso "Tarefa criada";
      no ClickUp: lista certa → `1-Atendimento Base` → `2026-10 Outubro` → `CH-xxxxx - Título`, criada por você, com os dois
      responsáveis, Etapa/Módulo "Atendimento Avulso", Agenda "Remoto", Apontamento "OS Experience", Parceiro, Usuário cliente,
      Detalhamento, status **backlog base**, descrição com os passos e os 2 prints anexados em ordem.
- [ ] **Ligação:** na Triagem o chamado fica "Tarefa criada" na hora (sem esperar a varredura) e aparece em Demandas/Kanban.
- [ ] **Com data:** outro chamado com vencimento no mês que vem e estimativa de 4 h → tarefa no mês do vencimento, com data, no status
      padrão da lista e estimativa 4 h.
- [ ] **Sem acesso:** responsável que não enxerga a pasta → ganha "Apenas exibição" (aviso na tela).
- [ ] **Clique duplo:** clicar duas vezes seguidas → só uma tarefa.
- [ ] **Sem conta:** gestor sem ClickUp conectado → botão desligado com o motivo; *Aprovar, crio à mão* continua funcionando.
- [ ] **Renomear:** renomear a tarefa criada antes da sincronização → continua ligada (pelo id).

## 13. Fase 4 — relatório de horas e visão do consultor (28/10/2026)

```powershell
npx supabase@latest db push --linked        # aplica a 0012_relatorio_e_consultor.sql
git add CLAUDE.md docs supabase web
git commit -m "Fase 4: relatório no painel de Horas e visão do consultor (D73, D74)"
git push                                     # publica Horas, Kanban e o menu do consultor no Pages
```

**Acesso de um consultor:** desde a D75 é pela tela **Consultores → Dar acesso** (§14). O caminho antigo, por SQL, fica como reserva:
1. *Authentication → Users → Add user → Create new user*: e-mail **igual ao do ClickUp** (o mesmo do cadastro de Consultores), senha,
   marque *Auto Confirm User*.
2. No *SQL Editor* (troque o e-mail):

```sql
insert into public.usuarios_sistema (id, nome, email, papel, consultor_id)
select u.id, c.nome, u.email, 'consultor', c.id
  from auth.users u join public.consultores c on lower(c.email) = lower(u.email)
 where lower(u.email) = lower('fulano@sankhya.com.br');
```

Se voltar "INSERT 0 0", o e-mail do login não bate com o do cadastro de Consultores. Para tirar o acesso: `update public.usuarios_sistema
set ativo = false where email = '...';`

Testes (marcar ao conferir):

- [ ] **Período:** Horas → *Este mês* / *Mês passado* / datas à mão → os totais mudam; *Desde o corte* volta para tudo.
- [ ] **Rastreadas:** um consultor que usa o cronômetro do ClickUp mostra "rastr." nas células e a diferença na última coluna.
- [ ] **Demandas:** consultor → cliente → aparecem as demandas com link para o ClickUp.
- [ ] **CSV:** *Exportar CSV* abre no Excel com colunas separadas e horas com vírgula.
- [ ] **Consultor:** entrar com o login do consultor → menu só com Kanban e Horas; no Kanban só as demandas dele; nas Horas só as
      horas dele; abrir `triagem.html` na barra de endereço → volta para o Kanban.

## 14. Acessos pela tela Consultores (28/10/2026, D75)

```powershell
npx supabase@latest db push --linked                          # aplica a 0013_acessos.sql
npx supabase@latest functions deploy acessos --use-api        # função nova
git add CLAUDE.md docs supabase web
git commit -m "Acessos pela tela Consultores (D75)"
git push
```

Testes (marcar ao conferir):

- [ ] **Dar acesso:** Consultores → numa pessoa sem acesso, *Dar acesso* → aparece "Acesso pronto" com endereço, e-mail e senha
      temporária → *Copiar*.
- [ ] **Primeiro login:** numa aba anônima, entrar com esses dados → abre "Trocar minha senha" sem o botão *Depois* → salvar → o
      consultor vê só Kanban e Horas. Na tela Consultores a pessoa deixa de mostrar "senha temporária".
- [ ] **Nova senha:** *Nova senha* → senha temporária nova; a antiga para de funcionar.
- [ ] **Tirar acesso:** *Tirar acesso* → *Confirmar?* → a pessoa aparece "desativado" e, ao recarregar, não vê mais nada.
      *Reativar* devolve o acesso com outra senha temporária.
- [ ] **Gestor:** como admin, escolher *Gestor* antes de *Dar acesso*. Um gestor que não é admin não vê essa escolha e não mexe em gestores.
- [ ] **Senha:** o botão *Senha* do menu troca a própria senha.

## 15. Só pessoas acompanhadas nos painéis (30/10/2026, D76)

```powershell
npx supabase@latest db push --linked        # aplica a 0014_pessoas_acompanhadas.sql
git add CLAUDE.md docs supabase web
git commit -m "Só pessoas acompanhadas nos painéis (D76)"
git push
```

Testes (marcar ao conferir):

- [ ] **Kanban:** a Elisangela (não marcada) não aparece mais em "Próxima" nem no filtro de consultor; as horas dela saem do card.
- [ ] **Marcar:** em Consultores, marcar *Acompanhar* numa pessoa → recarregar o Kanban → as agendas dela aparecem (sem esperar a sincronização).
      Desmarcar → somem de novo.
- [ ] **Demandas:** abrir as agendas de uma demanda com gente não marcada → a agenda aparece apagada com "pessoa não acompanhada".
- [ ] **Horas:** a pessoa não marcada some das linhas e do CSV.

## 16. Tela Personalização / Customização (30/10/2026, desvio — sem banco)

Não tem migração. Só a função e a tela:

```powershell
npx supabase@latest functions deploy clickup-consulta --use-api
git add CLAUDE.md docs supabase web
git commit -m "Tela Personalização / Customização (consulta ao vivo no ClickUp)"
git push
```

Conferir: menu **Personalização** → a consulta roda sozinha ao abrir (alguns segundos) → as 6 pessoas aparecem em verde
(em laranja = e-mail não achado no workspace do ClickUp) → *Revisar* no topo, com a etapa atual → *Atualizar* refaz a consulta.

## Problemas comuns

| Sintoma | O que fazer |
|---|---|
| Log: "Nenhuma conta do ClickUp conectada" | Conectar a conta em Meu perfil (ou configurar `CLICKUP_TOKEN`) |
| Log: "O ClickUp recusou o token" | A conta da sincronização ficou em "erro": reconectar em Meu perfil |
| Webhook não chega | Meu perfil → Ver situação. Se "failing"/"suspended", Registrar/refazer |
| "Acesso não liberado" no login | Falta a linha em `usuarios_sistema` (passo 6) |
| Formulário: "Link do formulário inválido" | A chave foi trocada: copie o link de novo na Triagem |
| Triagem sem os prints | Conferir o bucket `evidencias` e a política `gestor_le_evidencias` em `storage.objects` |
| Triagem: "Conecte a sua conta do ClickUp" | Meu perfil → conectar com o seu token pessoal (`pk_...`) |
| Triagem: "não está marcada para sincronizar" | Demandas → marcar a lista do cliente como Sincronizar |
| Triagem: "ainda não tem usuário ligado na origem" | Rodar a sincronização (traz os membros) ou conferir o e-mail no cadastro de Consultores |
| Triagem: tarefa criada, prints pendentes | Botão *Reenviar prints*; se repetir, ver o erro na própria mensagem |
| Consultor entra e vê "Acesso não liberado" | Dar (ou reativar) o acesso em Consultores (§14) |
| Consultores: "não tem e-mail no cadastro" | A sincronização de membros ainda não ligou a pessoa pelo e-mail do ClickUp; rodar a sincronização |
| Agenda/pessoa "sumiu" do Kanban ou das Horas | A pessoa não está marcada em Consultores → *Acompanhar* (D76) |
| Consultor vê o Kanban vazio | Ele não é responsável por nenhuma tarefa das listas marcadas, ou o cadastro dele em Consultores não tem o usuário do ClickUp |
| Varredura não roda sozinha | `select * from cron.job;` e `select * from net._http_response order by created desc limit 5;` |
