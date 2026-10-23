# 02 — Arquitetura

## Visão geral

```
            ┌──────────────── ClickUp (PMO BP-MS) ────────────────┐
            │  tarefas · registros de tempo · campos personalizados │
            └───────▲──────────────────────────────┬──────────────┘
     cria tarefa    │                              │ webhook (na hora)
     (fase 4)       │                              │ + sincronização a cada 15–30 min
                    │                              ▼
┌───────────────────┴───────────── Supabase (Free) ─────────────────────────┐
│ Edge Functions                                                            │
│  • clickup-webhook   recebe o aviso do ClickUp e atualiza a tarefa        │
│  • clickup-sync      busca alterações por período (rede de segurança)     │
│  • clickup-criar     cria a tarefa no ClickUp com o token do gestor       │
│  • clickup-conectar  conecta a conta ClickUp de cada gestor (OAuth)       │
│  • formulario        recebe o formulário externo e o portal do cliente   │
│ Postgres (RLS ligado)                                                     │
│  consultores · clientes · tarefas ClickUp · tempo · demandas · kanban ·   │
│  apontamentos · chamados · evidências · sugestões de agrupamento          │
│ Storage: prints dos chamados (bucket privado)                             │
│ Auth: login dos gestores (e-mail/senha ou link mágico)                    │
│ pg_cron: agenda a sincronização periódica                                 │
└───────────────────────────────▲───────────────────────────────────────────┘
                                │ supabase-js (chave pública + RLS)
┌───────────────────────────────┴───────── Hospedagem estática (Free) ──────┐
│ web/  Gestão (login): repositório · kanban · horas · triagem · cadastros  │
│       Formulário do consultor (link aberto) · Portal do cliente (link)    │
└───────────────────────────────────────────────────────────────────────────┘
```

## Componentes e motivo da escolha

| Peça | Escolha | Motivo |
|---|---|---|
| Banco | Supabase Postgres | SQL de verdade (views de horas, comparação de textos com `pg_trgm`), RLS, painel pronto |
| Funções no servidor | Supabase Edge Functions (TypeScript/Deno) | Fazem a conexão OAuth de cada gestor e usam os tokens do ClickUp fora do navegador. Recebem webhook. Grátis no plano Free |
| Agenda | `pg_cron` + `pg_net` do Supabase | Dispara a sincronização periódica e mantém o projeto ativo (evita a pausa por inatividade) |
| Arquivos | Supabase Storage, bucket privado | Prints das evidências. Comprimir a imagem no navegador antes de enviar |
| Telas | HTML + JavaScript simples (sem build) ou Vite, hospedado no **GitHub Pages**, **Cloudflare Pages** ou **Vercel** | Sem servidor para manter. A equipe já usa GitHub Pages na Central BP-MS |
| Login | Supabase Auth (e-mail e senha, D20) | Só gestores entram na gestão, com o **mesmo e-mail do ClickUp**. Formulário e portal não exigem login |
| Tokens | Supabase Vault | Token de cada gestor criptografado no banco; o navegador nunca vê |

## Limites do plano Free (conferir em supabase.com/pricing antes de criar)

Levantados em 22/10/2026, segundo fontes de terceiros:

- Banco: 500 MB · Arquivos: 1 GB · Tráfego: 5 GB/mês
- Edge Functions: 500 mil chamadas/mês · Auth: 50 mil usuários ativos/mês
- 2 projetos gratuitos por organização
- **Projeto pausa após 1 semana sem uso.** A sincronização agendada mantém o uso.

Estimativa de consumo (P4: ~10 consultores, ~150 tarefas/mês; piloto com 5 e ~50):
tarefas + tempo < 2 MB/ano; webhooks < 5 mil chamadas/mês; o maior consumo será de
prints → **comprimir para ~300 KB** cada (1 GB ≈ 3.000 prints).

## Fluxo da sincronização

1. **Webhook** (`clickup-webhook`): o ClickUp avisa quando uma tarefa é criada, alterada,
   apagada ou tem tempo registrado. A função confere a assinatura (`X-Signature`, HMAC
   SHA-256 com o segredo do webhook), busca a tarefa completa na API e grava.
2. **Varredura periódica** (`clickup-sync`): a cada 15–30 min busca as tarefas alteradas
   desde a última execução (`date_updated_gt`) dos consultores **e** listas marcados para
   sincronizar. Também descobre listas novas (entram "a analisar").
   Cobre webhook perdido ou fora do ar.
3. **Carga inicial**: a mesma função, com período maior (ex.: últimos 90 dias).
4. Cada tarefa nova entra no repositório como `pendente` e passa pela função de sugestão
   de agrupamento.

## Segurança

- Tokens do ClickUp: criptografados no Supabase Vault (um por gestor). Segredo do webhook e chave do agendamento também no Vault (D21); segredos do app OAuth e
  chave de serviço do Supabase: **somente** nos segredos das Edge Functions. O navegador usa só a chave pública (anon), limitada pelo RLS.
- Formulário externo e portal: o navegador envia para a Edge Function `formulario`, que
  valida os campos, limita o tamanho dos arquivos e grava. Anti-abuso: limite por IP e
  Cloudflare Turnstile (grátis) se aparecer spam.
- Portal do cliente: link com token exclusivo por cliente (`links_portal`), que pode ser
  desativado a qualquer momento. O cliente vê só os próprios chamados.
- Prints em bucket privado. As telas mostram com URL assinada de curta duração.

## Alternativa considerada: Firebase

A Central BP-MS já usa Firebase Auth (projeto `central-bpms`) e GitHub Pages. Reaproveitar
o Firebase evitaria uma plataforma nova, porém:
- as Cloud Functions (necessárias para webhook e para guardar o token) exigem o plano pago
  Blaze;
- o Firestore não faz bem somas e agrupamentos (horas por demanda e consultor) nem
  comparação de textos parecidos.

Por isso a recomendação é Supabase (decisão D1). Dá para manter o mesmo estilo visual e
hospedar as telas no mesmo GitHub Pages.
