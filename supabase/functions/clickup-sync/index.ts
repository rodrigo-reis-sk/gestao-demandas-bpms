// Edge Function clickup-sync — varredura do ClickUp (rede de segurança do webhook, D4).
//
// Quem pode chamar:
//   • o pg_cron, a cada 20 min (cabeçalho x-chave-agendamento);
//   • um gestor logado, pela tela ("Sincronizar agora", "Registrar webhook").
//
// Corpo (JSON):
//   { "tipo": "periodica" | "manual" | "carga_inicial" }    → sincroniza (responde na hora, roda em 2º plano)
//   { "acao": "registrar_webhook" }                          → cria/recria o webhook no ClickUp (só gestor)
//   { "acao": "situacao_webhook" }                           → mostra o webhook registrado (só gestor)
//   { "acao": "sincronizar_demanda", "tarefa_id": "<uuid>" }  → atualiza na hora UMA demanda, suas etapas e
//                                                               agendas (só gestor; responde ao terminar)
//
// Passos da sincronização:
//   1. membros do workspace → consultores (pelo e-mail);
//   2. pastas e listas do espaço PMO BP-MS → clientes_faps (novas entram "a analisar");
//   3. tarefas alteradas dos consultores E listas marcados (carga de 90 dias quando preciso);
//   4. registros de tempo da janela (14 dias; 90 na carga completa).
// Tudo vai para o log em "sincronizacoes".

import {
  type Banco, bancoAdmin, chamadaDoAgendamento, CORS, ehGestor, emSegundoPlano, mensagemDeErro, responder, rpc,
  usuarioDaRequisicao,
} from "../_compartilhado/base.ts";
import { ClienteClickUp, clienteDaSincronizacao, ErroClickUp, escolherEquipe } from "../_compartilhado/clickup-api.ts";
import {
  CLICKUP, traduzirListas, traduzirMembros, traduzirRegistrosTempo, traduzirTarefa,
} from "../_compartilhado/clickup-traducao.ts";

const LOTE = 100; // tarefas por chamada ao banco

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: CORS });
  if (req.method !== "POST") return responder(405, { erro: "Use POST." });

  const banco = bancoAdmin();
  try {
    const doAgendamento = await chamadaDoAgendamento(req, banco);
    const usuario = doAgendamento ? null : await usuarioDaRequisicao(req, banco);
    if (!doAgendamento && !ehGestor(usuario)) return responder(401, { erro: "Acesso só para gestores." });

    const corpo = await req.json().catch(() => ({}));

    if (corpo.acao === "registrar_webhook" || corpo.acao === "situacao_webhook") {
      if (!usuario) return responder(403, { erro: "Ação só pela tela, por um gestor." });
      return responder(200, await tratarWebhook(banco, corpo.acao === "registrar_webhook"));
    }

    if (corpo.acao === "sincronizar_demanda") {
      if (!usuario) return responder(403, { erro: "Ação só pela tela, por um gestor." });
      if (typeof corpo.tarefa_id !== "string" || !corpo.tarefa_id) return responder(400, { erro: "Informe tarefa_id." });
      const r = await sincronizarDemanda(banco, corpo.tarefa_id, usuario.email ?? null);
      return responder(r.erro ? 400 : 200, r);
    }

    const tipo = ["periodica", "manual", "carga_inicial"].includes(corpo.tipo) ? corpo.tipo : "manual";

    // Evita duas varreduras ao mesmo tempo (ex.: agendamento + botão).
    const { data: emAndamento } = await banco.from("sincronizacoes").select("id")
      .eq("sistema", "clickup").neq("tipo", "webhook").is("finalizado_em", null)
      .gt("iniciado_em", new Date(Date.now() - 5 * 60_000).toISOString()).limit(1);
    if (emAndamento?.length) {
      return responder(409, { erro: "Já existe uma sincronização em andamento.", sincronizacao_id: emAndamento[0].id });
    }

    // "Carga completa" pedida pela tela: todas as listas marcadas voltam a ser carregadas desde a data de corte
    if (tipo === "carga_inicial") {
      await banco.from("clientes_faps").update({ carregada_em: null }).eq("situacao_sincronizacao", "sincronizar");
    }

    const { data: log, error } = await banco.from("sincronizacoes")
      .insert({ sistema: "clickup", tipo, parametros: { pedido_por: usuario?.email ?? "agendamento" } })
      .select("id").single();
    if (error) throw new Error(error.message);

    await emSegundoPlano(sincronizar(banco, log.id, tipo));
    return responder(202, { ok: true, sincronizacao_id: log.id, mensagem: "Sincronização iniciada. Acompanhe no log." });
  } catch (e) {
    console.error(e);
    return responder(500, { erro: mensagemDeErro(e) });
  }
});

async function sincronizar(banco: Banco, logId: number, tipo: string) {
  let contaId: string | null = null;
  let cliente: ClienteClickUp | null = null;
  const parametros: Record<string, unknown> = {};
  const totais = { tarefas_lidas: 0, tarefas_novas: 0, tarefas_alteradas: 0, registros_tempo: 0, listas_novas: 0 };
  const avisos: string[] = [];

  try {
    ({ cliente, contaId } = await clienteDaSincronizacao(banco));
    parametros.conta = contaId ? "conta da sincronização" : "token único (plano B)";

    const { data: cfgLinha } = await banco.from("configuracoes").select("valor").eq("chave", "sincronizacao").single();
    const cfg = cfgLinha?.valor ?? {};
    const espacoId = String(cfg.espaco_id ?? CLICKUP.espacoId);

    // 1. Membros → consultores
    const equipe = escolherEquipe(await cliente.equipes());
    parametros.equipe_id = String(equipe.id);
    const membros = await rpc<any>(banco, "gravar_membros", { p_membros: traduzirMembros(equipe) });
    if (membros?.novos) avisos.push(`${membros.novos} pessoa(s) nova(s) no cadastro de consultores (desmarcadas)`);

    // 2. Pastas e listas → clientes_faps
    const listas = traduzirListas(await cliente.pastas(espacoId), await cliente.listasSemPasta(espacoId));
    const resultadoListas = await rpc<any>(banco, "gravar_listas", { p_listas: listas });
    totais.listas_novas = resultadoListas?.novas_a_analisar ?? 0;

    // 3. Tarefas e subtarefas — TUDO das listas marcadas (D32), por lista:
    //    • lista ainda não carregada → desde a data de corte (01/01/2026), inclusive concluídas;
    //    • lista já carregada → só o que mudou desde a última varredura.
    //    A carga respeita um tempo máximo por execução; o que faltar continua na próxima (D33).
    const inicioExecucao = Date.now();
    const LIMITE_MS = 100_000;
    const corte = new Date(String(cfg.carga_desde ?? "2026-01-01") + "T00:00:00-04:00");
    const [inicio] = await rpc<{ desde: string }[]>(banco, "inicio_busca_tarefas", { p_sistema: "clickup" });
    const desdeIncremental = new Date(Math.max(new Date(inicio.desde).getTime(), corte.getTime()));
    const marcadas = await rpc<{ lista_id_externo: string; carregada: boolean }[]>(banco, "listas_para_sincronizar");
    const carregadas = marcadas.filter((l) => l.carregada).map((l) => l.lista_id_externo);
    const pendentes = marcadas.filter((l) => !l.carregada).map((l) => l.lista_id_externo);
    Object.assign(parametros, { listas: marcadas.length, listas_a_carregar: pendentes.length,
      desde_incremental: desdeIncremental.toISOString(), carga_desde: corte.toISOString() });

    const gravar = async (brutas: any[]) => {
      const tarefas = brutas.map(traduzirTarefa);
      for (let i = 0; i < tarefas.length; i += LOTE) {
        const r = await rpc<any>(banco, "gravar_tarefas", { p_origem: "clickup", p_tarefas: tarefas.slice(i, i + LOTE) });
        totais.tarefas_lidas += r.lidas;
        totais.tarefas_novas += r.novas;
        totais.tarefas_alteradas += r.alteradas;
      }
    };

    if (!marcadas.length) {
      avisos.push("Nenhuma lista marcada para sincronizar: tarefas não buscadas");
    } else {
      // listas já carregadas: só alterações (uma busca para todas)
      if (carregadas.length) {
        await gravar(await cliente.tarefasAlteradas(parametros.equipe_id as string, {
          responsaveis: [], listas: carregadas, desde: desdeIncremental,
        }));
      }
      // listas a carregar: uma por vez, até o tempo máximo
      let feitas = 0;
      for (const lista of pendentes) {
        if (Date.now() - inicioExecucao > LIMITE_MS) break;
        await gravar(await cliente.tarefasAlteradas(parametros.equipe_id as string, {
          responsaveis: [], listas: [lista], desde: corte,
        }));
        await rpc(banco, "marcar_listas_carregadas", { p_listas: [lista] });
        feitas++;
      }
      parametros.listas_carregadas_agora = feitas;
      if (feitas < pendentes.length) {
        avisos.push(`Carga em andamento: faltam ${pendentes.length - feitas} lista(s), continua na próxima varredura`);
      }

      // 3b. Tarefas-mãe que faltam (não mudaram desde o corte, então a busca por alteração não trouxe).
      //     Busca uma a uma, subindo até o topo; a que não existir/não puder ser lida fica 1 dia sem tentar (D39).
      const lerIds = (r: unknown[]) => (r ?? []).map((x) => typeof x === "string" ? x : String(Object.values(x as object)[0]));
      for (let rodada = 0; rodada < 6 && Date.now() - inicioExecucao < 120_000; rodada++) {
        const faltam = lerIds(await rpc<unknown[]>(banco, "pais_faltando", { p_origem: "clickup", p_limite: 40 }));
        if (!faltam.length) break;
        const achadas: any[] = [];
        for (const id of faltam) {
          try {
            achadas.push(await cliente.tarefa(id));
          } catch (e) {
            if (!(e instanceof ErroClickUp && (e.status === 404 || e.status === 403))) throw e;
          }
        }
        if (achadas.length) await gravar(achadas);
        const resto = new Set(lerIds(await rpc<unknown[]>(banco, "pais_faltando", { p_origem: "clickup", p_limite: 1000 })));
        const ausentes = faltam.filter((id) => resto.has(id));
        if (ausentes.length) {
          await rpc(banco, "registrar_tarefas_ausentes", { p_origem: "clickup", p_ids: ausentes, p_motivo: "não encontrada ou sem acesso" });
        }
        parametros.maes_buscadas = Number(parametros.maes_buscadas ?? 0) + achadas.length;
      }

      // 4. Registros de tempo (cronômetro do ClickUp; aparece à parte das horas das agendas)
      const filtros = await rpc<{ usuarios: string[] }>(banco, "filtros_sincronizacao");
      if (filtros.usuarios.length) {
        const fim = new Date(Date.now() + 86_400_000);
        const inicioTempo = new Date(Date.now() - Number(cfg.janela_tempo_dias ?? 14) * 86_400_000);
        const entradas = await cliente.registrosTempo(parametros.equipe_id as string, {
          usuarios: filtros.usuarios, inicio: inicioTempo, fim, espacoId,
        });
        const rt = await rpc<any>(banco, "gravar_registros_tempo", {
          p_origem: "clickup", p_inicio: inicioTempo.toISOString(), p_fim: fim.toISOString(),
          p_usuarios: filtros.usuarios, p_registros: traduzirRegistrosTempo(entradas),
        });
        totais.registros_tempo = rt.gravados;
        if (rt.excluidos) avisos.push(`${rt.excluidos} registro(s) de tempo apagado(s) na origem`);
      }
    }

    if (contaId) await rpc(banco, "registrar_uso_conta", { p_conta_id: contaId });
    await finalizar(banco, logId, true, totais, cliente.chamadas, parametros,
      [`OK: ${totais.tarefas_novas} nova(s), ${totais.tarefas_alteradas} alterada(s), ${totais.listas_novas} lista(s) a analisar`,
        ...avisos].join(" · "));
  } catch (e) {
    console.error(e);
    let msg = mensagemDeErro(e);
    if (e instanceof ErroClickUp && e.status === 401) {
      msg = "O ClickUp recusou o token da conta da sincronização. Reconecte a conta em Meu perfil. " + msg;
      if (contaId) await rpc(banco, "registrar_uso_conta", { p_conta_id: contaId, p_erro: msg }).catch(() => {});
    }
    await finalizar(banco, logId, false, totais, cliente?.chamadas ?? 0, parametros, msg);
  }
}

/**
 * "Sincronizar" de uma demanda pela tela: busca no ClickUp a demanda e tudo abaixo dela, sem esperar a varredura.
 *   • desce pelas subtarefas (cada tarefa vem com a lista das filhas diretas);
 *   • inclui também as agendas que o banco já liga à demanda (atendimentos repetidos juntados, D38);
 *   • tarefa que sumiu na origem → excluida_na_origem (D8).
 * Os registros de tempo (cronômetro) continuam vindo pela varredura: a gravação deles é por período e usuário.
 */
async function sincronizarDemanda(banco: Banco, tarefaId: string, pedidoPor: string | null) {
  const MAX_TAREFAS = 80, LIMITE_MS = 45_000;
  const inicio = Date.now(), iniciadoEm = new Date().toISOString();

  const { data: demanda } = await banco.from("tarefas").select("id, id_externo, origem, nome")
    .eq("id", tarefaId).maybeSingle();
  if (!demanda) return { erro: "Demanda não encontrada." };
  if (demanda.origem !== "clickup" || !demanda.id_externo) return { erro: "Esta demanda não veio do ClickUp." };

  const { data: ligadas } = await banco.from("tarefas").select("id_externo")
    .eq("demanda_tarefa_id", demanda.id).eq("origem", "clickup").not("id_externo", "is", null);

  const fila = [demanda.id_externo as string, ...(ligadas ?? []).map((t) => t.id_externo as string)];
  const vistos = new Set<string>();
  const achadas: any[] = [], sumiram: string[] = [];
  let incompleta = false, sucesso = true, mensagem = "", chamadas = 0;
  let resumo = { tarefas_lidas: 0, tarefas_novas: 0, tarefas_alteradas: 0 };

  try {
    const { cliente, contaId } = await clienteDaSincronizacao(banco);
    try {
      while (fila.length) {
        const id = fila.shift()!;
        if (vistos.has(id)) continue;
        if (vistos.size >= MAX_TAREFAS || Date.now() - inicio > LIMITE_MS) { incompleta = true; break; }
        vistos.add(id);
        try {
          const t = await cliente.tarefaComSubtarefas(id);
          for (const f of t.subtasks ?? []) if (f?.id && !vistos.has(String(f.id))) fila.push(String(f.id));
          delete t.subtasks;              // a tradução usa a tarefa como vem da busca normal
          achadas.push(t);
        } catch (e) {
          if (e instanceof ErroClickUp && (e.status === 404 || e.status === 403)) sumiram.push(id);
          else throw e;
        }
      }
    } finally {
      chamadas = cliente.chamadas;
    }

    if (achadas.length) {
      const r = await rpc<any>(banco, "gravar_tarefas", { p_origem: "clickup", p_tarefas: achadas.map(traduzirTarefa) });
      resumo = { tarefas_lidas: r.lidas, tarefas_novas: r.novas, tarefas_alteradas: r.alteradas };
    }
    for (const id of sumiram) await rpc(banco, "marcar_tarefa_excluida", { p_origem: "clickup", p_id_externo: id });
    if (contaId) await rpc(banco, "registrar_uso_conta", { p_conta_id: contaId });

    mensagem = `Demanda "${demanda.nome}": ${achadas.length} tarefa(s) lida(s), ${resumo.tarefas_novas} nova(s), `
      + `${resumo.tarefas_alteradas} alterada(s)`
      + (sumiram.length ? `, ${sumiram.length} apagada(s) na origem` : "")
      + (incompleta ? " · parou no limite; o resto vem na varredura" : "");
  } catch (e) {
    console.error(e);
    sucesso = false;
    mensagem = `Demanda "${demanda.nome}": ERRO: ` + mensagemDeErro(e);
  }

  await banco.from("sincronizacoes").insert({
    sistema: "clickup", tipo: "manual", iniciado_em: iniciadoEm, finalizado_em: new Date().toISOString(),
    sucesso, chamadas_api: chamadas, mensagem: mensagem.slice(0, 2000), ...resumo,
    parametros: { acao: "sincronizar_demanda", demanda: demanda.id_externo, pedido_por: pedidoPor },
  });
  return sucesso ? { ok: true, mensagem, ...resumo, apagadas: sumiram.length, incompleta } : { erro: mensagem };
}

async function finalizar(
  banco: Banco, logId: number, sucesso: boolean, totais: Record<string, number>, chamadas: number,
  parametros: Record<string, unknown>, mensagem: string,
) {
  await banco.from("sincronizacoes").update({
    ...totais, sucesso, chamadas_api: chamadas, parametros, mensagem: mensagem.slice(0, 2000),
    finalizado_em: new Date().toISOString(),
  }).eq("id", logId);
}

/** Registra (ou mostra) o webhook do espaço PMO BP-MS. O segredo devolvido pelo ClickUp vai para o Vault. */
async function tratarWebhook(banco: Banco, registrar: boolean) {
  const { cliente } = await clienteDaSincronizacao(banco);
  const equipe = escolherEquipe(await cliente.equipes());
  const endpoint = `${Deno.env.get("SUPABASE_URL")}/functions/v1/clickup-webhook`;
  const existentes = (await cliente.webhooks(String(equipe.id))).filter((w) => w.endpoint === endpoint);

  if (!registrar) {
    return { registrado: existentes.length > 0, endpoint, webhooks: existentes.map((w) => ({
      id: w.id, situacao: w.health?.status ?? null, falhas: w.health?.fail_count ?? 0, eventos: w.events })) };
  }

  // recria do zero (o segredo só é mostrado na criação)
  for (const w of existentes) await cliente.apagarWebhook(w.id);
  const criado = await cliente.criarWebhook(String(equipe.id), endpoint, CLICKUP.espacoId, CLICKUP.eventosWebhook);
  const webhook = criado.webhook ?? criado;
  if (!webhook?.secret) throw new Error("O ClickUp não devolveu o segredo do webhook.");
  await rpc(banco, "salvar_segredo", { p_nome: "webhook_clickup", p_valor: webhook.secret, p_descricao: "Assinatura do webhook" });
  await banco.from("configuracoes").upsert({
    chave: "webhook", descricao: "Webhook registrado na origem",
    valor: { sistema: "clickup", id_externo: webhook.id, endpoint, registrado_em: new Date().toISOString() },
  });
  return { registrado: true, endpoint, id: webhook.id, apagados: existentes.length };
}
