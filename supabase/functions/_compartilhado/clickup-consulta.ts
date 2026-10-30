// Consulta ao vivo "Personalização / Customização" (desvio do escopo, 30/10/2026). Nada é gravado no banco.
// Usada pela Edge Function clickup-consulta; testada em supabase/testes/consulta.test.ts.

import { type ClienteClickUp, escolherEquipe } from "./clickup-api.ts";
import { CLICKUP, ehTarefaEstrutura, normalizar, traduzirTarefa } from "./clickup-traducao.ts";

const ETAPA_ALVO = "personalizacao customizacao";     // "Personalização / Customização" normalizado

/** Id do campo Etapa e da opção "Personalização / Customização" (procurados pelo nome: não dependem de configuração). */
async function opcaoAlvo(api: ClienteClickUp, amostra: any[]): Promise<string | null> {
  const achar = (campos: any[]) => {
    const etapa = campos.find((c: any) => c.id === CLICKUP.campos.etapa);
    return (etapa?.type_config?.options ?? []).find((o: any) => normalizar(o.name) === ETAPA_ALVO)?.id ?? null;
  };
  for (const t of amostra) { const id = achar(t.custom_fields ?? []); if (id) return id; }
  // sem tarefa de amostra: lê os campos da primeira lista do espaço
  const pastas = await api.pastas(CLICKUP.espacoId);
  const lista = pastas.flatMap((p: any) => p.lists ?? [])[0] ?? (await api.listasSemPasta(CLICKUP.espacoId))[0];
  return lista ? achar(await api.camposDaLista(String(lista.id))) : null;
}

export async function consultarPersonalizacao(api: ClienteClickUp, emails: string[], desde: Date, incluirFechadas: boolean) {
  const inicio = Date.now();
  const equipe = escolherEquipe(await api.equipes());
  const equipeId = String(equipe.id);

  // pessoas informadas → ids no ClickUp (pelo e-mail)
  const membros = (equipe.members ?? []).map((m: any) => m.user).filter(Boolean);
  const pessoas = emails.map((e) => {
    const u = membros.find((m: any) => String(m.email ?? "").toLowerCase() === e);
    return { email: e, id: u?.id ? String(u.id) : null, nome: u?.username ?? null };
  });
  const ids = pessoas.filter((p) => p.id).map((p) => p.id as string);

  // 1. tarefas das pessoas (desde a data)
  const dasPessoas = ids.length
    ? await api.buscarTarefas(equipeId, { espacos: [CLICKUP.espacoId], responsaveis: ids, desde, incluirFechadas })
    : [];

  // 2. tudo com a etapa Personalização (sem corte de data: é o retrato da etapa)
  const opcao = await opcaoAlvo(api, dasPessoas);
  if (!opcao) throw new Error('Não achei a opção "Personalização / Customização" no campo Etapa do ClickUp.');
  const naEtapa = await api.buscarTarefas(equipeId, {
    espacos: [CLICKUP.espacoId], incluirFechadas,
    campos: [{ field_id: CLICKUP.campos.etapa, operator: "=", value: opcao }],
  });

  // monta a lista (sem repetir) e classifica
  const itens = new Map<string, any>();
  const linha = (t: any) => {
    const x = traduzirTarefa(t);
    const naAlvo = normalizar(x.etapa) === ETAPA_ALVO;
    return {
      id: x.id_externo, nome: x.nome, url: x.url, status: x.status, status_tipo: x.status_tipo,
      etapa: x.etapa, cliente: x.parceiro_nome ?? x.pasta_nome, lista: x.lista_nome, pasta: x.pasta_nome,
      responsaveis: (t.assignees ?? []).map((a: any) => ({ id: String(a.id), nome: a.username ?? a.email ?? "?" })),
      pai: x.tarefa_pai_id_externo, data_inicio: x.data_inicio, data_vencimento: x.data_vencimento,
      atualizada: x.atualizada_na_origem, fechada: x.fechada_na_origem,
      minutos_estimados: x.minutos_estimados, minutos_registrados: x.minutos_registrados,
      grupo: naAlvo ? "personalizacao" : "revisar",
    };
  };
  for (const t of naEtapa) if (!ehTarefaEstrutura(t)) itens.set(String(t.id), linha(t));
  for (const t of dasPessoas) {
    if (ehTarefaEstrutura(t) || itens.has(String(t.id))) continue;
    const l = linha(t);
    if (l.grupo === "revisar") itens.set(l.id, l);
  }
  // ajuda na revisão: a tarefa-mãe já está em Personalização?
  for (const l of itens.values()) l.mae_na_etapa = !!(l.pai && itens.get(l.pai)?.grupo === "personalizacao");

  return {
    consultado_em: new Date().toISOString(), segundos: Math.round((Date.now() - inicio) / 1000),
    chamadas_api: api.chamadas, desde: desde.toISOString(), incluir_fechadas: incluirFechadas,
    pessoas, itens: [...itens.values()],
  };
}
