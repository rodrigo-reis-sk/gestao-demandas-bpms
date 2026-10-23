// Testes das peças das Edge Functions que não precisam de Supabase nem de ClickUp de verdade.
// Uso: deno test supabase/testes/funcoes.test.ts
// Gera também supabase/testes/.saida_tarefa.json, usado por rodar.sh para testar a gravação no banco.

import { deepStrictEqual as assertEquals, ok as assert } from "node:assert";
import { ClienteClickUp } from "../functions/_compartilhado/clickup-api.ts";
import {
  ehTarefaEstrutura, encerrada, extrairFap, traduzirHistorico, traduzirListas, traduzirRegistrosTempo, traduzirTarefa,
} from "../functions/_compartilhado/clickup-traducao.ts";

// Tarefa no formato da API v2 (resumida), como vem de GET /team/{id}/task
const TAREFA = {
  id: "86abc123", custom_id: null, name: "Ajuste no relatório de comissão",
  text_content: "texto da descrição", description: "texto da descrição",
  status: { status: "em andamento", type: "custom" },
  date_created: "1760000000000", date_updated: "1760100000000", date_closed: null,
  due_date: "1760200000000", start_date: null, time_spent: 5400000, time_estimate: null,
  creator: { id: 222, username: "Iago Proença" },
  assignees: [{ id: 222, username: "Iago Proença", email: "iago.proenca@sankhya.com.br" }],
  parent: "86parent", url: "https://app.clickup.com/t/86abc123",
  list: { id: "L1", name: "Germipasto 32221 Avulso" }, folder: { id: "P1", name: "Germipasto" },
  custom_fields: [
    { id: "d993c20b-a9b6-4fd4-bedc-c03b77e15ae5", name: "Parceiro", type: "drop_down", value: 1,
      type_config: { options: [
        { id: "25f4e223-f214-4893-809f-5c5e7f0f80c2", name: "Agrosalles", orderindex: 0 },
        { id: "65c6af23-8e9d-4e75-a802-6e97de4f9530", name: "Germipasto", orderindex: 1 }] } },
    { id: "3d629467-1fc7-46d6-b925-42afba66df92", name: "Período", type: "drop_down",
      value: "1192005b-c2b8-44b1-bca2-758779ecda3b",
      type_config: { options: [{ id: "1192005b-c2b8-44b1-bca2-758779ecda3b", name: "08h-10h", orderindex: 11 }] } },
    { id: "e74bba2f-032d-4e2e-8f37-ec19011312c0", name: "Detalhamento", type: "text", value: " Detalhe do campo " },
    { id: "773bc404-9cb0-4935-80e5-baadda33bf0b", name: "Usuário cliente", type: "short_text" },
  ],
};

Deno.test("tradução da tarefa", async () => {
  const t = traduzirTarefa(TAREFA);
  assertEquals(t.parceiro_nome, "Germipasto");          // dropdown por índice
  assertEquals(t.periodo, "08h-10h");                   // dropdown por id
  assertEquals(t.detalhamento, "Detalhe do campo");     // campo vence a descrição
  assertEquals(t.fap, "32221");
  assertEquals(t.minutos_registrados, 90);
  assertEquals(t.responsaveis, [{ usuario_id_externo: "222", nome_externo: "Iago Proença" }]);
  assertEquals(t.criada_na_origem, new Date(1760000000000).toISOString());
  assertEquals(t.usuario_cliente, null);
  assert(!("custom_fields" in t.dados_origem), "dados_origem não deve guardar as opções dos campos");
  await Deno.writeTextFile(new URL("./.saida_tarefa.json", import.meta.url), JSON.stringify([t]));
});

Deno.test("regras de listas (legado)", () => {
  assertEquals(extrairFap("Amidos 32699 Avulso"), "32699");
  assertEquals(extrairFap("Planos de ação"), null);
  assert(encerrada("Z-Antigo 123 Avulso"));
  assert(encerrada("zebra"));                           // legado: upper().startswith("Z")
  assert(encerrada("Projeto Concluído"));
  assert(!encerrada("Germipasto 32221 Avulso"));
  const linhas = traduzirListas(
    [{ id: "P1", name: "PRO-INFO - ED", lists: [{ id: "L9", name: "Por-Info 31826 Avulso" }, { id: "L5", name: "ICCAP 28124 P2" }] },
     { id: "P2", name: "3- Planos de Ação", lists: [{ id: "L8", name: "Planos" }] },
     { id: "P3", name: "Z Cliente Antigo", lists: [{ id: "L7", name: "Antigo 11111 Avulso" }] }],
    [{ id: "L6", name: "Solta" }],
  );
  assertEquals(linhas.map((l) => [l.lista_id_externo, l.fap, l.tipo, l.ativa, l.administrativa, l.nome_cliente, l.sigla_gerente]), [
    ["L9", "31826", "avulso", true, false, "Por-Info", "ED"],
    ["L5", "28124", "projeto", true, false, "ICCAP", "ED"],
    ["L8", null, "outro", true, true, "3- Planos de Ação", null],
    ["L7", "11111", "avulso", false, false, "Antigo", null],
    ["L6", null, "outro", true, false, null, null],
  ]);
});

Deno.test("tarefas de estrutura ficam de fora", () => {
  assert(ehTarefaEstrutura({ name: "1-Atendimento Base" }));
  assert(ehTarefaEstrutura({ name: "1-Atendimento da Base" }));                       // grafia real no ClickUp
  assert(ehTarefaEstrutura({ name: "Base do cliente", status: { status: "atendimento base" } }));
  assert(!ehTarefaEstrutura({ name: "2-Serviços", status: { status: "em andamento" } }));
  assert(ehTarefaEstrutura({ name: "2026-10 Outubro" }));
  assert(ehTarefaEstrutura({ name: "2026-03 Março" }));
  assert(!ehTarefaEstrutura({ name: "2026-10 Outubro ajuste nota" }));
});

Deno.test("registros de tempo e histórico", () => {
  const r = traduzirRegistrosTempo([
    { id: 1, task: { id: "86abc123" }, user: { id: 222 }, start: "1760000000000", end: "1760003600000", duration: "3600000", billable: true },
    { id: 2, task: { id: "86abc123" }, user: { id: 222 }, start: "1760000000000", duration: "-1760000000000" }, // rodando
    { id: 3, task: null, user: { id: 222 }, start: "1760000000000", duration: "60000" },                        // sem tarefa
  ]);
  assertEquals(r.length, 1);
  assertEquals(r[0].minutos, 60);
  const h = traduzirHistorico([{ id: "h1", field: "status", date: "1760000000000",
    before: { status: "backlog base" }, after: { status: "em andamento" }, user: { id: 222, username: "Iago" } }]);
  assertEquals([h[0].evento, h[0].valor_anterior, h[0].valor_novo, h[0].autor_nome], ["status", "backlog base", "em andamento", "Iago"]);
});

Deno.test("cliente da API: espera no 429, repete no 500, token pessoal sem Bearer", async () => {
  const original = globalThis.fetch;
  const respostas = [
    new Response("limite", { status: 429, headers: { "X-RateLimit-Reset": String(Math.floor(Date.now() / 1000)) } }),
    new Response("erro", { status: 500 }),
    new Response(JSON.stringify({ user: { id: 1, email: "a@b.c" } }), { status: 200 }),
  ];
  const cabecalhos: string[] = [];
  globalThis.fetch = ((_url: URL, init: RequestInit) => {
    cabecalhos.push((init.headers as Record<string, string>).Authorization);
    return Promise.resolve(respostas.shift()!);
  }) as typeof fetch;
  try {
    const c = new ClienteClickUp("pk_123");
    const u = await c.usuario();
    assertEquals(u.user.email, "a@b.c");
    assertEquals(c.chamadas, 3);
    assertEquals(cabecalhos[0], "pk_123");
    assertEquals(new ClienteClickUp("oauth_abc")["autorizacao"](), "Bearer oauth_abc");
  } finally {
    globalThis.fetch = original;
  }
});

Deno.test("cliente da API: paginação com trava e filtros em array", async () => {
  const original = globalThis.fetch;
  const urls: string[] = [];
  globalThis.fetch = ((url: URL) => {
    urls.push(url.toString());
    const pagina = Number(url.searchParams.get("page"));
    return Promise.resolve(new Response(JSON.stringify({ tasks: [{ id: pagina }], last_page: pagina === 1 })));
  }) as typeof fetch;
  try {
    const t = await new ClienteClickUp("x").tarefasAlteradas("9", { responsaveis: ["1", "2"], listas: ["L1"], desde: new Date(0) });
    assertEquals(t.length, 2);
    assert(urls[0].includes("assignees%5B%5D=1&assignees%5B%5D=2") && urls[0].includes("list_ids%5B%5D=L1"));
  } finally {
    globalThis.fetch = original;
  }
});
