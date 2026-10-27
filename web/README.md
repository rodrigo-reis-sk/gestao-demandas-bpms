# Telas

HTML + JavaScript simples com `supabase-js` (chave pública + RLS), sem build. Funcionam no celular,
tema claro e escuro. Publicadas no GitHub Pages pelo workflow `.github/workflows/pages.yml` (D25; modelo em `infra/pages.yml`).
Configuração pública em `config.js` (URL do Supabase, chave anon e Client ID do OAuth — nada secreto).

| Arquivo | Fase | Acesso | Conteúdo |
|---|---|---|---|
| `login.html` | 1 | aberto | Entrar com e-mail e senha (D20) |
| `index.html` | 1 | Gestor | Início: contadores, última sincronização, contas conectadas. Vira o kanban na fase 2 |
| `demandas.html` | 2 | Gestor | **Tela única** (D44): Cliente → Lista (sincronizar no ClickUp) → Demanda (conta/não) → Agendas, horas realizadas × agendadas × planejadas |
| `kanban.html` | 2 | Gestor | Kanban espelhando o status do ClickUp (D52): filtros consultor/cliente/gerente, horas e próxima agenda no card |
| `horas.html` | 2 | Gestor | Painel de horas consultor × mês (D53), abre por cliente; realizadas, agendadas e atrasadas |
| `listas.html` | 1 | — | Só redireciona para Demandas (D44). Antes:  Listas descobertas: a analisar no topo, sincronizar / não sincronizar (uma a uma ou em lote), cliente da lista |
| `consultores.html` | 1 | Gestor | Consultores: sincronizar, ativo, papel; mostra se já está ligado ao ClickUp |
| `sincronizacoes.html` | 1 | Gestor | Log das varreduras e do webhook; sincronizar agora; carga completa de 90 dias |
| `perfil.html` | 1 | Gestor | Conectar a própria conta do ClickUp (OAuth ou token pessoal), escolher a conta da sincronização, registrar o webhook |
| `repositorio.html` | 2 | Gestor | Tarefas pendentes e sugestões de agrupamento |
| `demanda.html` | 2 | Gestor | Detalhe da demanda, tarefas, histórico, horas manuais |
| `triagem.html` | 3 | Gestor | Chamados (D54, D58–D61): ver passos e prints, escolher dev/consultor, aprovar (nome `CH-xxxxx - Título` para criar no ClickUp), recusar, pedir informação (link do complemento); link do formulário com "Trocar chave". Contador no menu (D55) |
| `cadastros.html` | 2 | Gestor | Clientes (cor), colunas do kanban, parâmetros |
| `formulario.html` | 3 | Link com chave `?k=` (D57) | Formulário de demanda do consultor: passos com prints, compressão, rascunho no navegador |
| `complementar.html` | 3 | Link exclusivo `?c=` (D59) | Consultor responde ao pedido de informação e acrescenta passos |
| `portal.html` | 3 | Link exclusivo do cliente `?t=` (D62) | Cliente abre chamado (passos com prints) e acompanha todos os chamados dele em situação simplificada (D63); "Responder" leva ao complemento (D64). Links criados na Triagem |

Código comum: `assets/comum.js` (login, menu com contadores, chamadas às Edge Functions) e `assets/estilo.css`.
Telas sem login (formulário, complemento e, depois, o portal): `assets/evidencias.js` — editor de passos com prints,
compressão das imagens, rascunho (textos no localStorage, prints no IndexedDB) e envio à Edge Function `formulario`.
Elas **não** usam `comum.js` nem gravam no banco direto.

## Identidade visual (D26)

"Grafite + lima": cores definidas como variáveis no topo de `assets/estilo.css` (tema claro em `:root`,
escuro em `:root[data-tema="escuro"]`). Para mudar a cor de algo, troque a variável, não o elemento.
`assets/tema.js` aplica o tema antes de desenhar a página e cria o seletor ☀ / 🖥 / ☾ do menu.
Toda página nova deve ter no `<head>`: as fontes (Inter + Sora), `assets/estilo.css`, `assets/tema.js` e o favicon `assets/logo.svg`.

## Ordenação das listagens

Tabelas: `criarOrdenacao(tela, padrão, redesenhar)` em `assets/comum.js` — cabeçalho clicável (▲/▼),
vazios sempre no fim, escolha guardada no navegador. Em uso em Consultores e Log; a tela Listas
(agrupada por pasta) tem o seletor "Ordenar" (a analisar primeiro, cliente A→Z / Z→A, gerente,
mais listas, descoberta mais recente, FAP). Toda listagem nova deve usar o mesmo padrão.
