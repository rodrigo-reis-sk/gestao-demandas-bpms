// Testes da consulta ao vivo "Personalização / Customização" com um ClickUp simulado no fetch.
// Uso: deno test --allow-env=CLICKUP_TEAM_ID supabase/testes/consulta.test.ts
import { deepStrictEqual as assertEquals, ok as assert } from "node:assert";
import { ClienteClickUp } from "../functions/_compartilhado/clickup-api.ts";
import { consultarPersonalizacao } from "../functions/_compartilhado/clickup-consulta.ts";
import { CLICKUP } from "../functions/_compartilhado/clickup-traducao.ts";

const OPC_PERS = "op-pers", OPC_AVULSO = "op-avulso";
const etapa = (id: string | null) => ({
  id: CLICKUP.campos.etapa, name: "Etapa", type: "drop_down", value: id,
  type_config: { options: [{ id: OPC_AVULSO, name: "Atendimento Avulso", orderindex: 0 }, { id: OPC_PERS, name: "Personalização / Customização", orderindex: 1 }] },
});
const tarefa = (id: string, nome: string, et: string | null, quem: number[], pai: string | null = null) => ({
  id, name: nome, status: { status: "em andamento", type: "custom" }, url: `https://app.clickup.com/t/${id}`, parent: pai,
  list: { id: "L1", name: "Semalo 28371 Avulso" }, folder: { id: "F1", name: "SEMALO - FC" },
  assignees: quem.map((q) => ({ id: q, username: q === 1 ? "Iago Proença" : "Outra Pessoa" })),
  custom_fields: [etapa(et)], date_updated: "1761000000000", time_estimate: 7200000, time_spent: 3600000,
});

Deno.test("personalização: etapa certa, revisar as das pessoas com outra etapa, sem estrutura e sem repetir", async () => {
  const pedidos: URL[] = [];
  const original = globalThis.fetch;
  globalThis.fetch = ((url: URL) => {
    pedidos.push(url);
    const p = url.pathname.replace(/^\/api\/v2/, "");
    let corpo: unknown = {};
    if (p === "/team") corpo = { teams: [{ id: 9, members: [{ user: { id: 1, email: "iago@x", username: "Iago Proença" } }] }] };
    else if (p === "/team/9/task" && url.searchParams.get("custom_fields")) {
      corpo = { tasks: [tarefa("P1", "Tela de comissão", OPC_PERS, [2]), tarefa("P2", "Relatório DRE", OPC_PERS, [1])], last_page: true };
    } else if (p === "/team/9/task") {
      corpo = { tasks: [
        tarefa("P2", "Relatório DRE", OPC_PERS, [1]),                  // já está na etapa: não repete
        tarefa("R1", "Ajuste rotina", OPC_AVULSO, [1], "P1"),          // outra etapa, mãe em Personalização
        tarefa("R2", "Sem etapa", null, [1]),
        tarefa("B1", "1-Atendimento Base", null, [1]),                 // estrutura: fora
        tarefa("M1", "2026-10 Outubro", null, [1]),                    // estrutura: fora
      ], last_page: true };
    }
    return Promise.resolve(new Response(JSON.stringify(corpo)));
  }) as typeof fetch;
  try {
    const r = await consultarPersonalizacao(new ClienteClickUp("pk"), ["iago@x", "ninguem@x"], new Date("2026-01-01T00:00:00-04:00"), false);
    const por = Object.fromEntries(r.itens.map((i: any) => [i.id, i]));
    assertEquals(Object.keys(por).sort(), ["P1", "P2", "R1", "R2"]);
    assertEquals([por.P1.grupo, por.P2.grupo, por.R1.grupo, por.R2.grupo], ["personalizacao", "personalizacao", "revisar", "revisar"]);
    assertEquals(por.R1.etapa, "Atendimento Avulso");
    assert(por.R1.mae_na_etapa && !por.R2.mae_na_etapa);
    assertEquals(r.pessoas, [{ email: "iago@x", id: "1", nome: "Iago Proença" }, { email: "ninguem@x", id: null, nome: null }]);
    const filtro = pedidos.find((u) => u.searchParams.get("custom_fields"))!;
    assertEquals(JSON.parse(filtro.searchParams.get("custom_fields")!), [{ field_id: CLICKUP.campos.etapa, operator: "=", value: OPC_PERS }]);
    assert(filtro.searchParams.getAll("space_ids[]").includes(CLICKUP.espacoId));
    const dasPessoas = pedidos.find((u) => u.pathname.endsWith("/team/9/task") && !u.searchParams.get("custom_fields"))!;
    assertEquals(dasPessoas.searchParams.getAll("assignees[]"), ["1"]);
    assertEquals(dasPessoas.searchParams.get("include_closed"), "false");
  } finally {
    globalThis.fetch = original;
  }
});
