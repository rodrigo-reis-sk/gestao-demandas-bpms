// Criação da tarefa no ClickUp a partir de um chamado aprovado (fase 4, D65–D70).
// Reproduz criar_demanda_padrao() do pacote legado
// (referencia/clickup-lancar-legado/motores/clickup_tasks/lancar_tarefas_clickup.py):
//   1. lista do cliente (escolhida na triagem; o banco já conferiu que é do cliente, ativa e marcada);
//   2. desenvolvedor e consultor enxergam a pasta (senão libera "Apenas exibição" pela API v3);
//   3. acha ou cria "1-Atendimento Base";
//   4. acha ou cria a subtarefa do mês "AAAA-MM Mês" (mês do vencimento, se houver) e a deixa "em andamento";
//   5. cria a tarefa "CH-xxxxx - Título" com Etapa/Módulo "Atendimento Avulso", Agenda "Remoto",
//      Apontamento "OS Experience", Parceiro, Usuário cliente, Detalhamento, Origem e os dois responsáveis;
//      sem data → status "backlog base"; com data → status padrão da lista;
//   6. anexa os prints do chamado, em ordem (passo-01-print-1.jpg ...).
// Nada aqui fala com o banco: quem chama passa os dados e as funções de baixar/marcar os prints.

import { type ClienteClickUp, ErroClickUp, escolherEquipe } from "./clickup-api.ts";
import { CLICKUP, normalizar } from "./clickup-traducao.ts";

export interface Pessoa { id: string; nome: string; id_externo: string | null }
export interface Anexo { id: string; ordem: number; caminho: string; tipo: string; enviado: boolean }
export interface Passo { ordem: number; texto: string | null; etapa: string; anexos: Anexo[] }

/** O que o banco devolve em dados_criacao_tarefa / reservar_criacao_tarefa. */
export interface DadosChamado {
  id: string; codigo: string; canal: string; titulo: string; descricao: string | null;
  tipo: string | null; prioridade: string; origem_solicitacao: string | null;
  cliente: string | null; parceiro_id_externo: string | null;
  contato_nome: string | null; contato_info: string | null;
  chamado_sankhya_aberto: boolean; ticket_sankhya: string | null; retorno_sankhya: string | null;
  gerente: string | null; criado_em: string; tarefa_criada_id_externo: string | null;
  lista: { id: string; id_externo: string; nome: string } | null;
  desenvolvedor: Pessoa | null; consultor: Pessoa | null; pedido_por: string | null;
  evidencias: Passo[];
}

/** Escolhas feitas na triagem além dos responsáveis. */
export interface Opcoes {
  vencimento?: string | null;       // "AAAA-MM-DD"
  estimativaMinutos?: number | null;
  linkTriagem?: string | null;      // vai no fim da descrição
  hoje?: Date;                       // para teste
}

export interface Ganchos {
  /** Baixa o arquivo do bucket privado. */
  baixar(caminho: string): Promise<Blob>;
  /** Avisa que o print foi anexado (o banco marca para não enviar de novo). */
  anexoEnviado(anexoId: string): Promise<void>;
  /** Avisa assim que a tarefa nasce, ANTES dos prints (o banco guarda o id: nunca cria duas vezes). */
  tarefaCriada?(tarefa: any): Promise<void>;
}

export interface Resultado {
  tarefa: any;                 // tarefa criada (como a API devolve)
  baseId: string;
  mesId: string;
  avisos: string[];
  printsEnviados: number;
  printsPendentes: number;
}

const MESES = ["Janeiro", "Fevereiro", "Março", "Abril", "Maio", "Junho", "Julho", "Agosto", "Setembro",
  "Outubro", "Novembro", "Dezembro"];
const FUSO = "America/Campo_Grande";          // MS (UTC-4), igual às views do banco
const TEMPO_MAXIMO_PRINTS_MS = 90_000;        // a Edge Function tem ~150 s; o resto fica para "Reenviar prints"

// ------------------------------------------------------------------ regras puras

/** Nome da subtarefa do mês no padrão "AAAA-MM Mês". `data` = "AAAA-MM-DD" ou um Date (hoje, no fuso MS). */
export function nomeDoMes(data: string | Date): string {
  const iso = typeof data === "string" ? data : new Intl.DateTimeFormat("en-CA", { timeZone: FUSO }).format(data);
  const [ano, mes] = iso.split("-").map(Number);
  return `${ano}-${String(mes).padStart(2, "0")} ${MESES[mes - 1]}`;
}

/** Data "AAAA-MM-DD" em ms ao meio-dia do MS (o fuso não joga o dia para trás — lição do legado). */
export function dataParaMs(iso: string): number {
  return new Date(`${iso}T12:00:00-04:00`).getTime();
}

/** Nome da tarefa: o mesmo que a triagem mostra para copiar no modo manual (D54). */
export function nomeDaTarefa(d: Pick<DadosChamado, "codigo" | "titulo">): string {
  return `${d.codigo} - ${d.titulo}`.slice(0, 250);
}

/** Nome do anexo na tarefa: passo-01-print-1.jpg (a descrição cita esses nomes). */
export function nomeDoArquivo(passo: number, n: number, tipo: string): string {
  const ext = { "image/jpeg": "jpg", "image/png": "png", "image/webp": "webp", "image/gif": "gif", "application/pdf": "pdf" }[tipo] ?? "bin";
  return `passo-${String(passo).padStart(2, "0")}-${tipo === "application/pdf" ? "arquivo" : "print"}-${n}.${ext}`;
}

/** "1-Atendimento Base", "1 - ATENDIMENTO da Base"... (o legado procura "1-ATENDIMENTO" no nome). */
export function ehTarefaBase(nome: string | null | undefined): boolean {
  return /^1 atendimento\b/.test(normalizar(nome));   // normalizar troca o "-" por espaço
}

/** Opção do dropdown Origem: a origem do chamado, se for uma das opções; senão "Consultor" para o formulário. */
export function opcaoOrigem(d: Pick<DadosChamado, "canal" | "origem_solicitacao">): string | null {
  const alvo = normalizar(d.origem_solicitacao);
  for (const [nome, id] of Object.entries(CLICKUP.opcoesOrigem)) if (alvo && normalizar(nome) === alvo) return id;
  return d.canal === "formulario_consultor" ? CLICKUP.opcoesOrigem["Consultor"] : null;
}

const PRIORIDADE: Record<string, string> = { baixa: "Baixa", media: "Média", alta: "Alta", urgente: "Urgente" };
const dataBr = (iso: string) => new Date(iso).toLocaleDateString("pt-BR", { timeZone: FUSO });

/** Descrição da tarefa em Markdown: dados do chamado, descrição, passo a passo com os prints e o autor (D12). */
export function montarDescricao(d: DadosChamado, opcoes: Opcoes = {}): string {
  const canal = d.canal === "portal_cliente" ? "pelo portal do cliente" : "pelo formulário do consultor";
  const linhas: string[] = [`**Chamado ${d.codigo}** · aberto em ${dataBr(d.criado_em)} ${canal}`, ""];
  const item = (rotulo: string, valor: string | null | undefined) => { if (valor) linhas.push(`- **${rotulo}:** ${valor}`); };
  item("Cliente", d.cliente);
  item("Contato", [d.contato_nome, d.contato_info].filter(Boolean).join(" · "));
  item("Gerente de projetos", d.gerente);
  item("Desenvolvedor", d.desenvolvedor?.nome);
  item("Consultor", d.consultor?.nome);
  item("Prioridade", PRIORIDADE[d.prioridade] ?? d.prioridade);
  item("Tipo", d.tipo);
  item("Origem", d.origem_solicitacao);
  if (d.chamado_sankhya_aberto) item("Chamado Sankhya", [d.ticket_sankhya, d.retorno_sankhya].filter(Boolean).join(" · ") || "aberto");
  if (d.descricao) linhas.push("", "### Descrição", "", d.descricao);

  if (d.evidencias.length) {
    linhas.push("", "### Passo a passo");
    for (const p of d.evidencias) {
      linhas.push("", `**Passo ${p.ordem}**${p.etapa === "complemento" ? " (complemento)" : ""} — ${p.texto ?? ""}`.trimEnd());
      const nomes = [...p.anexos].sort((a, b) => a.ordem - b.ordem).map((a) => `\`${nomeDoArquivo(p.ordem, a.ordem, a.tipo)}\``);
      if (nomes.length) linhas.push(`Anexos: ${nomes.join(", ")}`);
    }
  }

  linhas.push("", "---", `Criado por ${d.pedido_por ?? "gestor"} via Gestão BP-MS`
    + (opcoes.linkTriagem ? ` · [abrir na triagem](${opcoes.linkTriagem})` : ""));
  return linhas.join("\n");
}

/** Corpo do POST /list/{id}/task da tarefa do atendimento. */
export function montarTarefa(d: DadosChamado, mesId: string, opcoes: Opcoes = {}) {
  const c = CLICKUP.campos, v = CLICKUP.valoresFixos;
  const campos: { id: string; value: unknown }[] = [
    { id: c.etapa, value: v.etapa },
    { id: c.modulo, value: v.modulo },
    { id: c.agenda, value: v.agendaRemoto },
    { id: c.apontamento, value: v.apontamentoOsExperience },
    { id: c.detalhamento, value: (d.descricao || d.titulo).slice(0, 2000) },
  ];
  if (d.contato_nome) campos.push({ id: c.usuarioCliente, value: d.contato_nome.slice(0, 200) });
  if (d.parceiro_id_externo) campos.push({ id: c.parceiro, value: d.parceiro_id_externo });
  const origem = opcaoOrigem(d);
  if (origem) campos.push({ id: c.origem, value: origem });

  const responsaveis = [d.desenvolvedor, d.consultor].filter((p): p is Pessoa => !!p?.id_externo)
    .map((p) => Number(p.id_externo));

  const corpo: Record<string, unknown> = {
    name: nomeDaTarefa(d),
    parent: mesId,
    markdown_description: montarDescricao(d, opcoes),
    assignees: [...new Set(responsaveis)],
    custom_fields: campos,
  };
  if (opcoes.vencimento) {
    corpo.due_date = dataParaMs(opcoes.vencimento);
    corpo.due_date_time = false;               // só a data, sem horário
  } else {
    corpo.status = CLICKUP.status.semData;     // regra PMO BP-MS: sem data → "backlog base"
  }
  if (opcoes.estimativaMinutos && opcoes.estimativaMinutos > 0) corpo.time_estimate = Math.round(opcoes.estimativaMinutos) * 60_000;
  return corpo;
}

// ------------------------------------------------------------------ passos com a API

/** Passo 2: responsável enxerga a lista? Senão libera "Apenas exibição" na pasta (nunca rebaixa quem já tem acesso). */
export async function garantirAcesso(api: ClienteClickUp, listaId: string, pessoas: Pessoa[], avisos: string[]) {
  const precisam = pessoas.filter((p) => p.id_externo);
  if (!precisam.length) return;
  let membros: string[];
  try {
    membros = await api.membrosDaLista(listaId);
  } catch (e) {
    if (e instanceof ErroClickUp && e.status === 401) throw e;
    avisos.push("Não consegui conferir o acesso dos responsáveis à pasta; a tarefa foi criada assim mesmo.");
    return;
  }
  const faltam = precisam.filter((p) => !membros.includes(String(p.id_externo)));
  if (!faltam.length) return;

  const lista = await api.lista(listaId);
  const pasta = lista.folder && lista.folder.id && !lista.folder.hidden ? lista.folder : null;
  const equipeId = String(escolherEquipe(await api.equipes()).id);   // mesmo workspace da varredura
  for (const p of faltam) {
    try {
      await api.liberarExibicao(equipeId, pasta ? "folder" : "list", String(pasta ? pasta.id : listaId), String(p.id_externo));
    } catch (e) {
      throw new Error(`${p.nome} não tem acesso à pasta do cliente e não consegui liberar automaticamente `
        + `(${e instanceof Error ? e.message : e}). Libere em "Compartilhar esta pasta" no ClickUp ou crie à mão.`);
    }
    avisos.push(`Acesso "Apenas exibição" liberado para ${p.nome} na ${pasta ? `pasta "${pasta.name}"` : "lista"}.`);
  }
}

/** Passo 3: "1-Atendimento Base" da lista (procura em até 10 páginas; cria se não houver). */
export async function obterOuCriarBase(api: ClienteClickUp, listaId: string, parceiro: string | null): Promise<any> {
  for (let pagina = 0; pagina < 10; pagina++) {
    const r = await api.tarefasDaLista(listaId, pagina);
    const base = (r.tasks ?? []).find((t: any) => ehTarefaBase(t.name) && !t.parent);
    if (base) return base;
    if (!r.tasks?.length || r.last_page !== false) break;
  }
  return await api.criarTarefa(listaId, {
    name: CLICKUP.tarefaBase, status: CLICKUP.status.emAndamento,
    custom_fields: parceiro ? [{ id: CLICKUP.campos.parceiro, value: parceiro }] : [],
  });
}

/** Passo 4: subtarefa do mês abaixo da base. A que já existe volta para "em andamento" (legado). */
export async function obterOuCriarMes(api: ClienteClickUp, listaId: string, baseId: string, nomeMes: string,
  parceiro: string | null): Promise<any> {
  const base = await api.tarefaComSubtarefas(baseId);
  const existente = (base.subtasks ?? []).find((t: any) => normalizar(t.name) === normalizar(nomeMes));
  if (existente) {
    await api.alterarTarefa(existente.id, { status: CLICKUP.status.emAndamento });
    if (parceiro) await api.gravarCampo(existente.id, CLICKUP.campos.parceiro, parceiro);
    return existente;
  }
  return await api.criarTarefa(listaId, {
    name: nomeMes, parent: baseId, status: CLICKUP.status.emAndamento,
    custom_fields: parceiro ? [{ id: CLICKUP.campos.parceiro, value: parceiro }] : [],
  });
}

/** Passo 6: anexa os prints que ainda não foram, em ordem. Para no tempo máximo (o resto fica pendente). */
export async function enviarPrints(api: ClienteClickUp, tarefaId: string, d: DadosChamado, g: Ganchos,
  inicio = Date.now()): Promise<{ enviados: number; pendentes: number; erros: string[] }> {
  const fila = d.evidencias.flatMap((p) => [...p.anexos].sort((a, b) => a.ordem - b.ordem)
    .filter((a) => !a.enviado).map((a) => ({ passo: p.ordem, a })));
  let enviados = 0;
  const erros: string[] = [];
  for (const [i, { passo, a }] of fila.entries()) {
    if (Date.now() - inicio > TEMPO_MAXIMO_PRINTS_MS) {
      return { enviados, pendentes: fila.length - i, erros };
    }
    const nome = nomeDoArquivo(passo, a.ordem, a.tipo);
    try {
      await api.anexar(tarefaId, nome, await g.baixar(a.caminho));
      await g.anexoEnviado(a.id);
      enviados++;
    } catch (e) {
      if (e instanceof ErroClickUp && e.status === 401) throw e;
      erros.push(`${nome}: ${e instanceof Error ? e.message : e}`);
    }
  }
  return { enviados, pendentes: erros.length, erros };
}

/** Tudo: passos 2 a 6. Erros antes da tarefa nascer sobem; depois disso viram avisos (a tarefa existe). */
export async function criarTarefaDoChamado(api: ClienteClickUp, d: DadosChamado, opcoes: Opcoes, g: Ganchos): Promise<Resultado> {
  const inicio = Date.now();
  if (!d.lista?.id_externo) throw new Error("Escolha a lista do cliente.");
  if (!d.desenvolvedor?.id_externo) throw new Error("O desenvolvedor não tem usuário ligado no ClickUp.");
  const listaId = d.lista.id_externo;
  const avisos: string[] = [];

  await garantirAcesso(api, listaId, [d.desenvolvedor, d.consultor].filter((p): p is Pessoa => !!p), avisos);
  const base = await obterOuCriarBase(api, listaId, d.parceiro_id_externo);
  const nomeMes = nomeDoMes(opcoes.vencimento ?? opcoes.hoje ?? new Date());
  const mes = await obterOuCriarMes(api, listaId, String(base.id), nomeMes, d.parceiro_id_externo);
  const tarefa = await api.criarTarefa(listaId, montarTarefa(d, String(mes.id), opcoes));
  if (!tarefa?.id) throw new Error("O ClickUp não devolveu a tarefa criada.");
  if (g.tarefaCriada) await g.tarefaCriada(tarefa);

  let r = { enviados: 0, pendentes: 0, erros: [] as string[] };
  try {
    r = await enviarPrints(api, String(tarefa.id), d, g, inicio);
  } catch (e) {
    avisos.push(`Os prints não foram anexados: ${e instanceof Error ? e.message : e}`);
    r.pendentes = d.evidencias.reduce((s, p) => s + p.anexos.filter((a) => !a.enviado).length, 0);
  }
  if (r.erros.length) avisos.push(`Prints com erro: ${r.erros.join("; ")}`);
  if (r.pendentes) avisos.push(`${r.pendentes} print(s) não anexado(s): use "Reenviar prints".`);
  return { tarefa, baseId: String(base.id), mesId: String(mes.id), avisos, printsEnviados: r.enviados, printsPendentes: r.pendentes };
}
