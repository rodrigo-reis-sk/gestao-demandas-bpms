# Telas

HTML + JavaScript simples com `supabase-js` (chave pública + RLS), sem build. Funcionam no celular,
tema claro e escuro. Publicadas no GitHub Pages pelo workflow `.github/workflows/pages.yml` (D25; modelo em `infra/pages.yml`).
Configuração pública em `config.js` (URL do Supabase, chave anon e Client ID do OAuth — nada secreto).

| Arquivo | Fase | Acesso | Conteúdo |
|---|---|---|---|
| `login.html` | 1 | aberto | Entrar com e-mail e senha (D20) |
| `index.html` | 1 | Gestor | Início: contadores, última sincronização, contas conectadas. Vira o kanban na fase 2 |
| `listas.html` | 1 | Gestor | Listas descobertas: a analisar no topo, sincronizar / não sincronizar (uma a uma ou em lote), cliente da lista |
| `consultores.html` | 1 | Gestor | Consultores: sincronizar, ativo, papel; mostra se já está ligado ao ClickUp |
| `sincronizacoes.html` | 1 | Gestor | Log das varreduras e do webhook; sincronizar agora; carga completa de 90 dias |
| `perfil.html` | 1 | Gestor | Conectar a própria conta do ClickUp (OAuth ou token pessoal), escolher a conta da sincronização, registrar o webhook |
| `repositorio.html` | 2 | Gestor | Tarefas pendentes e sugestões de agrupamento |
| `demanda.html` | 2 | Gestor | Detalhe da demanda, tarefas, histórico, horas manuais |
| `triagem.html` | 3 | Gestor | Chamados novos: direcionar ou enviar ao ClickUp |
| `cadastros.html` | 2 | Gestor | Clientes (cor), colunas do kanban, parâmetros |
| `formulario.html` | 3 | Link aberto | Formulário de demanda do consultor |
| `portal.html` | 3 | Link exclusivo do cliente | Abrir e acompanhar chamados |

Código comum: `assets/comum.js` (login, menu com contador de listas a analisar, chamadas às Edge
Functions) e `assets/estilo.css`.
