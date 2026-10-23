# Gestão de Demandas BP-MS

Sistema simples para gerir as demandas de desenvolvimento e personalização da equipe BP-MS.
Ele sincroniza as tarefas dos consultores no ClickUp, agrupa tarefas repetidas em demandas
e organiza essas demandas num kanban com controle de horas.

> **Situação:** fase 1 com código pronto e testado localmente (22/10/2026): banco, sincronização com o
> ClickUp e telas mínimas. Falta implantar (ver `docs/08-implantacao.md`) e validar o piloto.

## O que o sistema vai fazer

1. **Sincronizar o ClickUp**: busca as tarefas dos consultores e das listas marcados como
   "sincronizar" e mantém tudo atualizado quando a tarefa muda no ClickUp. Cada gestor conecta
   a própria conta do ClickUp, para ficar registrado quem criou ou alterou.
2. **Repositório de tarefas**: caixa de entrada das tarefas sincronizadas, onde cada tarefa é
   classificada e agrupada. O sistema sugere o agrupamento ("provável continuação da DEM-0042").
3. **Kanban configurável**: cada card é uma demanda e mostra o cliente, o consultor, as
   tarefas agrupadas, as horas e o ticket Sankhya.
4. **Horas**: o tempo registrado no ClickUp e o tempo informado pelo gestor, lado a lado, por
   demanda e por consultor.
5. **Entrada de demandas**: formulário por link externo para consultores e portal de chamados
   para clientes. Cada chamado passa por triagem: vira demanda para um desenvolvedor ou vira
   tarefa nova no ClickUp.

## Como esta pasta está organizada

| Pasta / arquivo | Conteúdo |
|---|---|
| `CLAUDE.md` | Memória do projeto para o Claude: contexto, regras e convenções. Leia primeiro. |
| `docs/` | Escopo, arquitetura, modelo de dados, integração, regras de agrupamento, fases e decisões |
| `supabase/migrations/` | Scripts SQL do banco: estrutura (0001) e sincronização (0002). Testados localmente |
| `supabase/testes/` | Testes do banco e das funções (`bash supabase/testes/rodar.sh`) |
| `supabase/config.toml` | Configuração do Supabase CLI (`npx supabase ...`) |
| `supabase/seed.sql` | Dados iniciais: colunas do kanban, consultores, clientes e FAPs |
| `supabase/functions/` | Funções no servidor: conectar conta, sincronização e webhook do ClickUp |
| `web/` | Telas (login, início, listas, consultores, log, meu perfil). Publicadas no GitHub Pages |
| `infra/pages.yml` | Publicação automática da pasta `web/` no GitHub Pages (copiar para `.github/workflows/`) |
| `config/clickup.json` | IDs do ClickUp (espaço, campos, opções, status). Não contém senha nem token |
| `referencia/` | Material de apoio: o pacote "Lançar ClickUp" que já funciona e o protótipo do formulário |
| `.env.example` | Variáveis de ambiente necessárias (sem valores reais) |

## Como trabalhar com o Claude neste projeto

- Uma conversa por fase. Comece com: *"Leia o CLAUDE.md e o docs/06-fases.md. Vamos fazer a fase X."*
- Toda decisão nova vai para `docs/07-decisoes.md`. Toda pendência resolvida sai de
  `docs/01-escopo.md` → *Pendências*.
- Nunca coloque token do ClickUp, chave do Supabase ou senha em arquivo desta pasta.
  Use `.env` (que fica fora do git) ou os segredos do Supabase.

## Como colocar no ar

Siga `docs/08-implantacao.md` (Supabase, segredos, funções, agendamento, primeiro acesso, GitHub Pages
e validação do piloto).
