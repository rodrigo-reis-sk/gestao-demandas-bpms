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
  CLICKUP, ehTarefaEstrutura, traduzirListas, traduzirMembros, traduzirRegistrosTempo, traduzirTarefa,
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

    const tipo = ["periodica", "manual", "carga_inicial"].includes(corpo.tipo) ? corpo.tipo : "manual";

    // Evita duas varreduras ao mesmo tempo (ex.: agendamento + botão).
    const { data: emAndamento } = await banco.from("sincronizacoes").select("id")
      .eq("sistema", "clickup").neq("tipo", "webhook").is("finalizado_em", null)
      .gt("iniciado_em", new Date(Date.now() - 5 * 60_000).toISOString()).limit(1);
    if (emAndamento?.length) {
      return responder(409, { erro: "Já existe uma sincronização em andamento.", sincronizacao_id: emAndamento[0].id });
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

    // 3. Tarefas
    const filtros = await rpc<{ usuarios: string[]; listas: string[] }>(banco, "filtros_sincronizacao");
    const [inicio] = await rpc<{ desde: string; carga_completa: boolean }[]>(banco, "inicio_busca_tarefas", { p_sistema: "clickup" });
    const cargaCompleta = tipo === "carga_inicial" || inicio.carga_completa;
    const desde = tipo === "carga_inicial"
      ? new Date(Date.now() - Number(cfg.carga_inicial_dias ?? 90) * 86_400_000)
      : new Date(inicio.desde);
    Object.assign(parametros, { desde: desde.toISOString(), carga_completa: cargaCompleta,
      consultores: filtros.usuarios.length, listas: filtros.listas.length });

    if (!filtros.usuarios.length || !filtros.listas.length) {
      avisos.push("Nenhum consultor ou nenhuma lista marcados para sincronizar: tarefas não buscadas");
    } else {
      const tarefas = (await cliente.tarefasAlteradas(parametros.equipe_id as string, {
        responsaveis: filtros.usuarios, listas: filtros.listas, desde,
      })).filter((t) => !ehTarefaEstrutura(t)).map(traduzirTarefa);

      for (let i = 0; i < tarefas.length; i += LOTE) {
        const r = await rpc<any>(banco, "gravar_tarefas", { p_origem: "clickup", p_tarefas: tarefas.slice(i, i + LOTE) });
        totais.tarefas_lidas += r.lidas;
        totais.tarefas_novas += r.novas;
        totais.tarefas_alteradas += r.alteradas;
      }

      // 4. Registros de tempo
      const fim = new Date(Date.now() + 86_400_000);
      const inicioTempo = cargaCompleta ? desde : new Date(Date.now() - Number(cfg.janela_tempo_dias ?? 14) * 86_400_000);
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
