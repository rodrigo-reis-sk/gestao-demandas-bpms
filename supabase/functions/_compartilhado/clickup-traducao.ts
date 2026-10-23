// Tradução dos objetos do ClickUp para o formato genérico que o banco recebe
// (funções gravar_* da migração 0002). Todo o conhecimento do formato do ClickUp fica aqui;
// o banco não sabe de onde os dados vieram (D10).
//
// Constantes copiadas de config/clickup.json (as Edge Functions só enxergam esta pasta).
// Se mudar lá, mude aqui.

export const CLICKUP = {
  espacoId: "90133723590",
  campos: {
    parceiro: "d993c20b-a9b6-4fd4-bedc-c03b77e15ae5",
    usuarioCliente: "773bc404-9cb0-4935-80e5-baadda33bf0b",
    detalhamento: "e74bba2f-032d-4e2e-8f37-ec19011312c0",
    origem: "a194dde3-5aca-4df7-9f94-d6a6f52fee85",
    periodo: "3d629467-1fc7-46d6-b925-42afba66df92",
    etapa: "2bffbedf-89bd-4b12-ba60-dff41f8d3cff",
    agenda: "af3cf86c-a293-4d1c-9916-180ad84f0a7b",
  },
  pastasAdministrativas: ["1-BP-MS", "2- Horas Cruzadas", "3- Planos de Ação"],
  tarefaBase: "1-Atendimento Base",
  regexFap: /\b(\d{4,6})\b/,
  // eventos do webhook que interessam
  eventosWebhook: [
    "taskCreated", "taskUpdated", "taskDeleted", "taskPriorityUpdated", "taskStatusUpdated",
    "taskAssigneeUpdated", "taskDueDateUpdated", "taskMoved", "taskTimeEstimateUpdated", "taskTimeTrackedUpdated",
  ],
};

// ------------------------------------------------------------------ utilitários

/** Texto sem acento, minúsculo, só letras e números (igual a normalizar_texto do banco). */
export function normalizar(t: string | null | undefined): string {
  return (t ?? "").normalize("NFD").replace(/[̀-ͯ]/g, "").toLowerCase().replace(/[^a-z0-9]+/g, " ").trim();
}

/** Datas do ClickUp chegam em milissegundos (texto). */
export function dataIso(ms: string | number | null | undefined): string | null {
  if (ms === null || ms === undefined || ms === "") return null;
  const n = Number(ms);
  return Number.isFinite(n) && n > 0 ? new Date(n).toISOString() : null;
}

const minutos = (ms: string | number | null | undefined) =>
  ms === null || ms === undefined || ms === "" ? null : Math.round(Number(ms) / 60_000);

export function extrairFap(nome: string | null | undefined): string | null {
  return nome?.match(CLICKUP.regexFap)?.[1] ?? null;
}

/** Regra do legado: nome começando com "Z" ou contendo "conclu" = encerrada. */
export function encerrada(nome: string | null | undefined): boolean {
  const n = (nome ?? "").trim();
  return n.toUpperCase().startsWith("Z") || normalizar(n).includes("conclu");
}

// ------------------------------------------------------------------ campos personalizados

function campo(tarefa: any, id: string): any | undefined {
  return (tarefa.custom_fields ?? []).find((c: any) => c.id === id);
}

/** Opção escolhida num dropdown. O valor pode vir como índice (orderindex) ou como id da opção. */
function opcao(tarefa: any, id: string): { id: string; nome: string } | null {
  const c = campo(tarefa, id);
  if (!c || c.value === undefined || c.value === null || c.value === "") return null;
  const opcoes: any[] = c.type_config?.options ?? [];
  const o = opcoes.find((o) => o.id === c.value || (typeof c.value === "number" && o.orderindex === c.value)
    || String(o.orderindex) === String(c.value));
  return o ? { id: o.id, nome: o.name } : null;
}

function texto(tarefa: any, id: string): string | null {
  const v = campo(tarefa, id)?.value;
  return typeof v === "string" && v.trim() ? v.trim() : null;
}

/** Só id, nome e valor legível dos campos preenchidos (sem a lista de opções, que é grande). */
function camposResumidos(tarefa: any) {
  return (tarefa.custom_fields ?? [])
    .filter((c: any) => c.value !== undefined && c.value !== null && c.value !== "")
    .map((c: any) => ({ id: c.id, nome: c.name, valor: c.type === "drop_down" ? opcao(tarefa, c.id)?.nome ?? c.value : c.value }));
}

// ------------------------------------------------------------------ tarefas

/**
 * Tarefas de estrutura (não são atendimentos):
 *   • "1-Atendimento Base" / "1-Atendimento da Base" (no ClickUp aparecem as duas grafias),
 *     ou qualquer tarefa no status "atendimento base";
 *   • a subtarefa do mês ("2026-10 Outubro").
 */
export function ehTarefaEstrutura(tarefa: any): boolean {
  const nome = (tarefa.name ?? "").trim();
  return /^\d+ atendimento (da )?base$/.test(normalizar(nome))
    || normalizar(tarefa.status?.status) === "atendimento base"
    || /^\d{4}-\d{2}\s+\S+$/.test(nome);
}

export function traduzirTarefa(t: any) {
  const parceiro = opcao(t, CLICKUP.campos.parceiro);
  // resposta da API sem as listas de opções dos campos (economiza espaço no banco)
  const { custom_fields: _cf, ...resto } = t;
  return {
    id_externo: String(t.id),
    codigo_externo: t.custom_id ?? null,
    nome: t.name ?? "",
    detalhamento: texto(t, CLICKUP.campos.detalhamento) ?? (t.text_content?.trim() || t.description?.trim() || null),
    status: t.status?.status ?? null,
    status_tipo: t.status?.type ?? null,
    url: t.url ?? null,
    lista_id_externo: t.list?.id ? String(t.list.id) : null,
    lista_nome: t.list?.name ?? null,
    pasta_id_externo: t.folder?.id ? String(t.folder.id) : null,
    pasta_nome: t.folder?.name ?? null,
    tarefa_pai_id_externo: t.parent ?? null,
    fap: extrairFap(t.list?.name),
    parceiro_id_externo: parceiro?.id ?? null,
    parceiro_nome: parceiro?.nome ?? null,
    usuario_cliente: texto(t, CLICKUP.campos.usuarioCliente),
    origem_solicitacao: opcao(t, CLICKUP.campos.origem)?.nome ?? null,
    periodo: opcao(t, CLICKUP.campos.periodo)?.nome ?? null,
    etapa: opcao(t, CLICKUP.campos.etapa)?.nome ?? null,
    agenda_tipo: opcao(t, CLICKUP.campos.agenda)?.nome ?? null,
    // nó de estrutura ("1-Atendimento (da) Base", subtarefa do mês): vai para o banco só para montar
    // a hierarquia; nunca vira demanda nem agenda (D31)
    estrutura: ehTarefaEstrutura(t),
    data_inicio: dataIso(t.start_date),
    data_vencimento: dataIso(t.due_date),
    criada_na_origem: dataIso(t.date_created),
    atualizada_na_origem: dataIso(t.date_updated),
    fechada_na_origem: dataIso(t.date_closed ?? t.date_done),
    minutos_registrados: minutos(t.time_spent) ?? 0,
    minutos_estimados: minutos(t.time_estimate),
    campos_personalizados: camposResumidos(t),
    criada_por_id_externo: t.creator?.id ? String(t.creator.id) : null,
    criada_por_nome: t.creator?.username ?? null,
    responsaveis: (t.assignees ?? []).map((a: any) => ({ usuario_id_externo: String(a.id), nome_externo: a.username ?? a.email })),
    dados_origem: resto,
  };
}

// ------------------------------------------------------------------ listas, membros, tempo

/** Pastas (com listas) + listas soltas → formato de gravar_listas. */
export function traduzirListas(pastas: any[], listasSoltas: any[]) {
  const linhas: any[] = [];
  const administrativas = CLICKUP.pastasAdministrativas.map(normalizar);
  const montar = (lista: any, pasta: any | null) => {
    const fap = extrairFap(lista.name);
    const nomeLista: string = lista.name ?? "";
    const n = normalizar(nomeLista);
    // "GERMIPASTO - FC" → sigla do gerente de projetos "FC" e nome do cliente "GERMIPASTO"
    const sufixo = pasta?.name?.match(/\s-\s*([A-Z]{2,3})\s*$/);
    return {
      lista_id_externo: String(lista.id),
      nome_lista: nomeLista,
      pasta_id_externo: pasta ? String(pasta.id) : null,
      pasta_nome: pasta?.name ?? null,
      fap,
      // Avulso pelo nome; com FAP mas sem "Avulso" (ex.: "ICCAP 28124 P2") = projeto
      tipo: n.includes("avulso") ? "avulso" : (fap || n.includes("projeto")) ? "projeto" : "outro",
      ativa: !encerrada(nomeLista) && !(pasta && encerrada(pasta.name)),
      administrativa: !!pasta && administrativas.includes(normalizar(pasta.name)),
      // "Germipasto 32221 Avulso" → "Germipasto" (ajuda a achar o cliente quando a pasta tem outro nome)
      nome_cliente: fap ? nomeLista.split(fap)[0].trim() : (pasta?.name ?? "").replace(/\s-\s*[A-Z]{2,3}\s*$/, "").trim() || null,
      sigla_gerente: sufixo?.[1] ?? null,
    };
  };
  for (const pasta of pastas) for (const lista of pasta.lists ?? []) linhas.push(montar(lista, pasta));
  for (const lista of listasSoltas) linhas.push(montar(lista, null));
  return linhas;
}

export function traduzirMembros(equipe: any) {
  return (equipe.members ?? []).map((m: any) => ({
    usuario_id_externo: String(m.user?.id),
    nome: m.user?.username ?? null,
    email: m.user?.email ?? null,
  })).filter((m: any) => m.usuario_id_externo !== "undefined");
}

/** Registros de tempo (time entries). Cronômetro ainda rodando (duração negativa) fica de fora. */
export function traduzirRegistrosTempo(entradas: any[]) {
  return entradas
    .filter((e) => e.task?.id && Number(e.duration) >= 0)
    .map((e) => ({
      id_externo: String(e.id),
      tarefa_id_externo: String(e.task.id),
      usuario_id_externo: String(e.user?.id),
      inicio: dataIso(e.start),
      fim: dataIso(e.end),
      minutos: minutos(e.duration) ?? 0,
      descricao: e.description || null,
      faturavel: typeof e.billable === "boolean" ? e.billable : null,
    }));
}

// ------------------------------------------------------------------ histórico (webhook)

function valorLegivel(v: any): string | null {
  if (v === null || v === undefined || v === "") return null;
  if (typeof v !== "object") return String(v);
  return v.status ?? v.username ?? v.name ?? v.email ?? JSON.stringify(v);
}

const EVENTOS: Record<string, string> = {
  status: "status", name: "nome", assignee_add: "responsavel", assignee_rem: "responsavel",
  due_date: "datas", start_date: "datas", time_spent: "tempo", time_estimate: "tempo",
  custom_field: "campo", task_creation: "criada", section_moved: "lista", priority: "prioridade",
  content: "descricao",
};

/** history_items do webhook → formato de gravar_historico_tarefa ("quem alterou o quê", D13). */
export function traduzirHistorico(itens: any[]) {
  return (itens ?? []).map((h) => ({
    id_externo: String(h.id),
    evento: EVENTOS[h.field] ?? h.field ?? "alterada",
    campo: h.field === "custom_field" ? (h.custom_field?.name ?? h.field) : h.field ?? null,
    valor_anterior: valorLegivel(h.before),
    valor_novo: valorLegivel(h.after),
    autor_id_externo: h.user?.id ? String(h.user.id) : null,
    autor_nome: h.user?.username ?? h.user?.email ?? null,
    ocorrido_em: dataIso(h.date),
  }));
}
