// Testes da criação da tarefa a partir do chamado (fase 4), com um ClickUp simulado no fetch.
// Uso: deno test supabase/testes/criacao.test.ts

import { deepStrictEqual as assertEquals, ok as assert, rejects } from "node:assert";
import { ClienteClickUp } from "../functions/_compartilhado/clickup-api.ts";
import {
  criarTarefaDoChamado, type DadosChamado, ehTarefaBase, montarDescricao, nomeDoArquivo, nomeDoMes, opcaoOrigem,
} from "../functions/_compartilhado/clickup-criacao.ts";
import { CLICKUP } from "../functions/_compartilhado/clickup-traducao.ts";

const CHAMADO: DadosChamado = {
  id: "c1", codigo: "CH-00099", canal: "formulario_consultor", titulo: "Ajuste DANFE", descricao: "A DANFE sai sem o lote.",
  tipo: "Ajuste / correção", prioridade: "alta", origem_solicitacao: "Projeto de implantação",
  cliente: "Semalo", parceiro_id_externo: "0a128c94-0f50-442c-a1d5-5b74a4b15222",
  contato_nome: "Maria", contato_info: "maria@semalo.com.br",
  chamado_sankhya_aberto: true, ticket_sankhya: "123456", retorno_sankhya: null,
  gerente: "Filipe Capulo", criado_em: "2026-10-26T13:00:00Z", tarefa_criada_id_externo: null,
  lista: { id: "f1", id_externo: "L", nome: "Semalo 28371 Avulso" },
  desenvolvedor: { id: "d", nome: "Iago Proença", id_externo: "222" },
  consultor: { id: "k", nome: "André Acunha", id_externo: "555" },
  pedido_por: "Rodrigo Reis",
  evidencias: [
    { ordem: 1, texto: "Abrir a nota", etapa: "abertura", anexos: [
      { id: "a2", ordem: 2, caminho: "c1/01-02.png", tipo: "image/png", enviado: false },
      { id: "a1", ordem: 1, caminho: "c1/01-01.jpg", tipo: "image/jpeg", enviado: false }] },
    { ordem: 2, texto: "Imprimir", etapa: "complemento", anexos: [] },
  ],
};

interface Pedido { metodo: string; url: URL; corpo: any }

/** ClickUp de mentira: cada rota devolve o que o teste mandar; guarda os pedidos na ordem. */
function simular(rotas: Record<string, (p: Pedido) => unknown>) {
  const pedidos: Pedido[] = [];
  const original = globalThis.fetch;
  globalThis.fetch = (async (url: URL, init: RequestInit) => {
    const corpo = init.body instanceof FormData ? init.body : init.body ? JSON.parse(String(init.body)) : null;
    const p = { metodo: init.method ?? "GET", url, corpo };
    pedidos.push(p);
    const chave = `${p.metodo} ${url.pathname.replace(/^\/api\/v[23]/, "")}`;
    const rota = rotas[chave];
    if (!rota) return new Response(`sem rota ${chave}`, { status: 404 });
    const r = rota(p);
    return r instanceof Response ? r : new Response(JSON.stringify(r ?? {}), { status: 200 });
  }) as typeof fetch;
  return { pedidos, desfazer: () => { globalThis.fetch = original; } };
}

const marcados: string[] = [];
const ganchos = {
  baixar: (c: string) => Promise.resolve(new Blob([c])),
  anexoEnviado: (id: string) => { marcados.push(id); return Promise.resolve(); },
};

Deno.test("regras puras: mês, base, origem e nome do arquivo", () => {
  assertEquals(nomeDoMes("2026-11-03"), "2026-11 Novembro");
  assertEquals(nomeDoMes(new Date("2026-11-01T02:00:00Z")), "2026-10 Outubro");   // 22h do dia 31 no MS
  assert(ehTarefaBase("1-Atendimento Base") && ehTarefaBase("1 - ATENDIMENTO da Base") && ehTarefaBase("1-Atendimento da Base"));
  assert(!ehTarefaBase("2-Atendimento Folha") && !ehTarefaBase("Atendimento"));
  assertEquals(opcaoOrigem({ canal: "formulario_consultor", origem_solicitacao: "Outra" }), CLICKUP.opcoesOrigem["Consultor"]);
  assertEquals(opcaoOrigem({ canal: "portal_cliente", origem_solicitacao: "e-mail" }), CLICKUP.opcoesOrigem["E-mail"]);
  assertEquals(opcaoOrigem({ canal: "portal_cliente", origem_solicitacao: "Portal do cliente" }), null);
  assertEquals(nomeDoArquivo(3, 2, "image/png"), "passo-03-print-2.png");
  assertEquals(nomeDoArquivo(1, 1, "application/pdf"), "passo-01-arquivo-1.pdf");
  const desc = montarDescricao(CHAMADO, { linkTriagem: "https://x.github.io/triagem.html" });
  assert(desc.includes("**Chamado CH-00099**") && desc.includes("123456") && desc.includes("Criado por Rodrigo Reis via Gestão BP-MS"));
  assert(desc.indexOf("passo-01-print-1.jpg") < desc.indexOf("passo-01-print-2.png"), "prints em ordem");
  assert(desc.includes("**Passo 2** (complemento)"));
});

Deno.test("cria na base e no mês existentes, libera acesso do consultor e anexa os prints em ordem", async () => {
  marcados.length = 0;
  const s = simular({
    "GET /list/L/member": () => ({ members: [{ id: 222 }] }),
    "GET /list/L": () => ({ id: "L", folder: { id: "F1", name: "SEMALO - FC", hidden: false } }),
    "GET /team": () => ({ teams: [{ id: 9 }] }),
    "PATCH /workspaces/9/folder/F1/acls": () => ({}),
    "GET /list/L/task": () => ({ tasks: [{ id: "X", name: "Outra" }, { id: "B", name: "1-Atendimento da Base" }], last_page: true }),
    "GET /task/B": () => ({ id: "B", subtasks: [{ id: "M9", name: "2026-09 Setembro" }, { id: "M", name: "2026-10 Outubro" }] }),
    "PUT /task/M": () => ({}),
    [`POST /task/M/field/${CLICKUP.campos.parceiro}`]: () => ({}),
    "POST /list/L/task": (p) => ({ id: "T1", name: p.corpo.name, url: "https://app.clickup.com/t/T1" }),
    "POST /task/T1/attachment": () => ({}),
  });
  try {
    const criadas: string[] = [];
    const r = await criarTarefaDoChamado(new ClienteClickUp("pk_gestor"), CHAMADO, { hoje: new Date("2026-10-26T15:00:00Z") },
      { ...ganchos, tarefaCriada: (t) => { criadas.push(t.id); return Promise.resolve(); } });
    assertEquals(r.tarefa.id, "T1");
    assertEquals(criadas, ["T1"]);
    assertEquals([r.baseId, r.mesId, r.printsEnviados, r.printsPendentes], ["B", "M", 2, 0]);
    assert(r.avisos.some((a) => a.includes("André Acunha") && a.includes("SEMALO - FC")));

    const acl = s.pedidos.find((p) => p.metodo === "PATCH")!;
    assert(acl.url.href.startsWith("https://api.clickup.com/api/v3/"), "acesso pela API v3");
    assertEquals(acl.corpo.entries, [{ kind: "user", id: "555", permission_level: 1 }]);
    assertEquals(s.pedidos.find((p) => p.metodo === "PUT")!.corpo, { status: "em andamento" });   // mês reaberto

    const nova = s.pedidos.find((p) => p.metodo === "POST" && p.url.pathname.endsWith("/list/L/task"))!.corpo;
    assertEquals(nova.name, "CH-00099 - Ajuste DANFE");
    assertEquals(nova.parent, "M");
    assertEquals(nova.status, "backlog base");
    assertEquals(nova.assignees, [222, 555]);
    assert(!("due_date" in nova) && !("time_estimate" in nova));
    const campo = (id: string) => nova.custom_fields.find((c: any) => c.id === id)?.value;
    assertEquals(campo(CLICKUP.campos.etapa), CLICKUP.valoresFixos.etapa);
    assertEquals(campo(CLICKUP.campos.modulo), CLICKUP.valoresFixos.modulo);
    assertEquals(campo(CLICKUP.campos.agenda), CLICKUP.valoresFixos.agendaRemoto);
    assertEquals(campo(CLICKUP.campos.apontamento), CLICKUP.valoresFixos.apontamentoOsExperience);
    assertEquals(campo(CLICKUP.campos.parceiro), CHAMADO.parceiro_id_externo);
    assertEquals(campo(CLICKUP.campos.usuarioCliente), "Maria");
    assertEquals(campo(CLICKUP.campos.detalhamento), "A DANFE sai sem o lote.");
    assertEquals(campo(CLICKUP.campos.origem), CLICKUP.opcoesOrigem["Consultor"]);
    assert(nova.markdown_description.includes("passo-01-print-1.jpg"));

    const anexos = s.pedidos.filter((p) => p.url.pathname.endsWith("/attachment"));
    assertEquals(anexos.map((p) => (p.corpo as FormData).get("attachment") instanceof File ? ((p.corpo as FormData).get("attachment") as File).name : "?"),
      ["passo-01-print-1.jpg", "passo-01-print-2.png"]);
    assertEquals(marcados, ["a1", "a2"]);
  } finally {
    s.desfazer();
  }
});

Deno.test("sem base: cria a base e o mês do vencimento; com data vai sem status e com estimativa", async () => {
  const s = simular({
    "GET /list/L/member": () => ({ members: [{ id: 222 }, { id: 555 }] }),
    "GET /list/L/task": () => ({ tasks: [], last_page: true }),
    "POST /list/L/task": (p) => p.corpo.name === "1-Atendimento Base" ? { id: "B" }
      : p.corpo.name === "2026-11 Novembro" ? { id: "M" } : { id: "T2", name: p.corpo.name },
    "GET /task/B": () => ({ id: "B", subtasks: [] }),
    "POST /task/T2/attachment": () => ({}),
  });
  try {
    const d = { ...CHAMADO, consultor: null, evidencias: [] };
    const r = await criarTarefaDoChamado(new ClienteClickUp("pk_gestor"), d, { vencimento: "2026-11-03", estimativaMinutos: 240 }, ganchos);
    assertEquals([r.baseId, r.mesId, r.tarefa.id], ["B", "M", "T2"]);
    const criacoes = s.pedidos.filter((p) => p.metodo === "POST").map((p) => p.corpo);
    assertEquals(criacoes[0].status, "em andamento");
    assertEquals(criacoes[1].parent, "B");
    const nova = criacoes[2];
    assertEquals(nova.assignees, [222]);
    assert(!("status" in nova), "com data: status padrão da lista");
    assertEquals(nova.due_date, new Date("2026-11-03T12:00:00-04:00").getTime());
    assertEquals(nova.due_date_time, false);
    assertEquals(nova.time_estimate, 240 * 60_000);
    assert(!s.pedidos.some((p) => p.metodo === "PATCH"), "todos já enxergam: não libera acesso");
  } finally {
    s.desfazer();
  }
});

Deno.test("sem conseguir liberar o acesso, não cria nada (regra do legado)", async () => {
  const s = simular({
    "GET /list/L/member": () => ({ members: [] }),
    "GET /list/L": () => ({ id: "L", folder: { id: "F1", name: "SEMALO" } }),
    "GET /team": () => ({ teams: [{ id: 9 }] }),
    "PATCH /workspaces/9/folder/F1/acls": () => new Response("sem permissão", { status: 403 }),
  });
  try {
    await rejects(criarTarefaDoChamado(new ClienteClickUp("pk"), CHAMADO, {}, ganchos), /não tem acesso à pasta/);
    assert(!s.pedidos.some((p) => p.metodo === "POST"), "nenhuma tarefa criada");
  } finally {
    s.desfazer();
  }
});

Deno.test("print que falha fica pendente e vira aviso; a tarefa continua criada", async () => {
  marcados.length = 0;
  let n = 0;
  const s = simular({
    "GET /list/L/member": () => ({ members: [{ id: 222 }, { id: 555 }] }),
    "GET /list/L/task": () => ({ tasks: [{ id: "B", name: "1-Atendimento Base" }], last_page: true }),
    "GET /task/B": () => ({ id: "B", subtasks: [{ id: "M", name: "2026-10 Outubro" }] }),
    "PUT /task/M": () => ({}),
    [`POST /task/M/field/${CLICKUP.campos.parceiro}`]: () => ({}),
    "POST /list/L/task": () => ({ id: "T3", name: "x" }),
    "POST /task/T3/attachment": () => (++n === 1 ? new Response("arquivo ruim", { status: 400 }) : {}),
  });
  try {
    const r = await criarTarefaDoChamado(new ClienteClickUp("pk"), CHAMADO, { hoje: new Date("2026-10-26T15:00:00Z") }, ganchos);
    assertEquals([r.printsEnviados, r.printsPendentes], [1, 1]);
    assertEquals(marcados, ["a2"]);
    assert(r.avisos.some((a) => a.includes("Reenviar prints")));
  } finally {
    s.desfazer();
  }
});
