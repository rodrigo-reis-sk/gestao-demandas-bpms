// Código das telas SEM login (formulário do consultor e complemento; depois o portal do cliente):
//   • editor de evidências em passos, com prints na sequência (arrastar, colar com Ctrl+V ou escolher);
//   • compressão das imagens no navegador antes de enviar;
//   • rascunho que sobrevive a fechar a tela (R5.4): textos no localStorage, prints no IndexedDB;
//   • chamada à Edge Function "formulario".
// Não usa supabase-js nem a sessão de login: quem grava é a Edge Function (CLAUDE.md, regras técnicas).

const CFG = window.CONFIG || {};
export const URL_FUNCAO = `${CFG.supabaseUrl}/functions/v1/formulario`;

export const $ = (sel, raiz = document) => raiz.querySelector(sel);
export function esc(v) {
  return String(v ?? "").replace(/[&<>"']/g, (c) => ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;", "'": "&#39;" }[c]));
}

/** Mensagem rápida no canto da tela (mesmo visual das telas de gestão). */
export function aviso(msg, tipo = "") {
  let caixa = $("#aviso");
  if (!caixa) { caixa = document.createElement("div"); caixa.id = "aviso"; caixa.setAttribute("role", "status"); document.body.append(caixa); }
  const d = document.createElement("div");
  d.className = tipo;
  d.textContent = msg;
  caixa.append(d);
  setTimeout(() => d.remove(), tipo === "erro" ? 9000 : 4500);
}

// ------------------------------------------------------------------ Edge Function
/** Chamada com JSON (leitura das listas). Devolve o JSON ou lança erro com a mensagem. */
export async function consultar(corpo) {
  return tratar(await fetch(URL_FUNCAO, {
    method: "POST",
    headers: { "Content-Type": "application/json", apikey: CFG.supabaseChavePublica || "" },
    body: JSON.stringify(corpo),
  }));
}

/** Envio com arquivos (FormData). */
export async function enviar(form) {
  return tratar(await fetch(URL_FUNCAO, { method: "POST", headers: { apikey: CFG.supabaseChavePublica || "" }, body: form }));
}

async function tratar(resp) {
  let corpo = null;
  try { corpo = await resp.json(); } catch { /* sem corpo */ }
  if (!resp.ok) {
    const e = new Error(corpo?.erro || `Falha no servidor (${resp.status}).`);
    e.status = resp.status;
    throw e;
  }
  return corpo;
}

// ------------------------------------------------------------------ compressão
const ALVO_KB = 300;          // configuracoes.anexos.comprimir_para_kb
const LADO_MAX = 1920;
const PDF_MAX = 5 * 1024 * 1024;

/** Imagem → JPEG de até ~300 KB (reduz qualidade e, se precisar, o tamanho). PDF passa como está. */
export async function comprimir(arquivo) {
  if (arquivo.type === "application/pdf") {
    if (arquivo.size > PDF_MAX) throw new Error(`O PDF ${arquivo.name} passa de 5 MB.`);
    return arquivo;
  }
  if (!arquivo.type.startsWith("image/")) throw new Error("Use imagem (PNG, JPG) ou PDF.");
  if (arquivo.size <= ALVO_KB * 1024 && arquivo.type === "image/jpeg") return arquivo;
  const img = await carregarImagem(arquivo);
  let escala = Math.min(1, LADO_MAX / Math.max(img.width, img.height));
  let qualidade = 0.85;
  for (let tentativa = 0; tentativa < 8; tentativa++) {
    const blob = await desenhar(img, escala, qualidade);
    if (blob.size <= ALVO_KB * 1024 || tentativa === 7) {
      return new File([blob], (arquivo.name || "print").replace(/\.\w+$/, "") + ".jpg", { type: "image/jpeg" });
    }
    if (qualidade > 0.6) qualidade -= 0.1; else escala *= 0.8;
  }
}

function carregarImagem(arquivo) {
  return new Promise((ok, falha) => {
    const url = URL.createObjectURL(arquivo);
    const img = new Image();
    img.onload = () => { URL.revokeObjectURL(url); ok(img); };
    img.onerror = () => { URL.revokeObjectURL(url); falha(new Error(`Não foi possível ler a imagem ${arquivo.name || ""}.`)); };
    img.src = url;
  });
}

function desenhar(img, escala, qualidade) {
  const c = document.createElement("canvas");
  c.width = Math.max(1, Math.round(img.width * escala));
  c.height = Math.max(1, Math.round(img.height * escala));
  const ctx = c.getContext("2d");
  ctx.fillStyle = "#fff";                    // PNG transparente fica com fundo branco
  ctx.fillRect(0, 0, c.width, c.height);
  ctx.drawImage(img, 0, 0, c.width, c.height);
  return new Promise((ok) => c.toBlob(ok, "image/jpeg", qualidade));
}

// ------------------------------------------------------------------ rascunho (IndexedDB para os prints)
const BANCO_LOCAL = "gestao-bpms-rascunho";

function abrirBancoLocal() {
  return new Promise((ok, falha) => {
    const r = indexedDB.open(BANCO_LOCAL, 1);
    r.onupgradeneeded = () => r.result.createObjectStore("prints");
    r.onsuccess = () => ok(r.result);
    r.onerror = () => falha(r.error);
  });
}
async function local(modo, acao) {
  try {
    const db = await abrirBancoLocal();
    return await new Promise((ok, falha) => {
      const tx = db.transaction("prints", modo);
      const req = acao(tx.objectStore("prints"));
      tx.oncomplete = () => ok(req?.result);
      tx.onerror = () => falha(tx.error);
    });
  } catch { return undefined; }             // navegador sem IndexedDB (aba anônima): segue sem rascunho de prints
}
const guardarPrint = (id, blob) => local("readwrite", (s) => s.put(blob, id));
const lerPrint = (id) => local("readonly", (s) => s.get(id));
const apagarPrint = (id) => local("readwrite", (s) => s.delete(id));

export function lerRascunho(chave) {
  try { return JSON.parse(localStorage.getItem(chave) || "null"); } catch { return null; }
}
export function gravarRascunho(chave, valor) {
  try { if (valor === null) localStorage.removeItem(chave); else localStorage.setItem(chave, JSON.stringify(valor)); } catch { /* sem espaço */ }
}

// ------------------------------------------------------------------ editor de passos
const novoId = () => Math.random().toString(36).slice(2, 10) + Date.now().toString(36);

/**
 * Editor de evidências em passos.
 *   const ed = criarEditorPassos($("#passos"), { aoMudar: salvarRascunho });
 *   ed.estado()            → [{ texto, prints: [id...] }] para guardar no rascunho
 *   await ed.restaurar(estado)
 *   ed.montarEnvio(form)   → acrescenta os arquivos ao FormData e devolve [{ texto, arquivos: ["a0"...] }]
 *   ed.limpar()            → apaga passos e prints do rascunho
 *   ed.ocupado()           → true enquanto comprime prints
 */
export function criarEditorPassos(raiz, { aoMudar = () => {}, dicaPrimeiro = "" } = {}) {
  let passos = [];                         // [{ id, texto, prints: [{ id, url, tipo, carregando }] }]
  let ativo = 0;
  let comprimindo = 0;
  const entrada = Object.assign(document.createElement("input"), { type: "file", multiple: true, hidden: true, accept: "image/*,application/pdf" });
  raiz.after(entrada);
  let destino = 0;
  entrada.onchange = () => { adicionarArquivos(entrada.files, destino); entrada.value = ""; };

  const botaoNovo = document.createElement("button");
  botaoNovo.type = "button";
  botaoNovo.className = "botao-passo";
  botaoNovo.textContent = "+ Adicionar passo";
  botaoNovo.onclick = () => { passos.push({ id: novoId(), texto: "", prints: [] }); desenhar(passos.length - 1); aoMudar(); };
  raiz.after(botaoNovo);

  // Ctrl+V com imagem: vai para o passo em que o cursor está (ou o último usado)
  document.addEventListener("paste", (ev) => {
    if (!raiz.isConnected || raiz.closest("[hidden]")) return;
    const arquivos = [...(ev.clipboardData?.items || [])].filter((i) => i.kind === "file").map((i) => i.getAsFile()).filter(Boolean);
    if (!arquivos.length) return;
    ev.preventDefault();
    const alvo = ev.target?.dataset?.passo !== undefined ? Number(ev.target.dataset.passo) : Math.min(ativo, passos.length - 1);
    adicionarArquivos(arquivos, Math.max(0, alvo));
  });

  function desenhar(focar) {
    if (!passos.length) passos.push({ id: novoId(), texto: "", prints: [] });
    raiz.innerHTML = "";
    passos.forEach((p, i) => {
      const caixa = document.createElement("div");
      caixa.className = "passo";
      caixa.innerHTML = `
        <div class="passo-topo"><span class="passo-n">Passo ${i + 1}</span><span class="espaco"></span>
          <button type="button" class="icone" data-a="subir" title="Mover para cima" aria-label="Mover passo ${i + 1} para cima" ${i === 0 ? "disabled" : ""}>↑</button>
          <button type="button" class="icone" data-a="descer" title="Mover para baixo" aria-label="Mover passo ${i + 1} para baixo" ${i === passos.length - 1 ? "disabled" : ""}>↓</button>
          <button type="button" class="icone" data-a="remover" title="Remover passo" aria-label="Remover passo ${i + 1}">×</button></div>
        <textarea data-passo="${i}" aria-label="Texto do passo ${i + 1}" placeholder="${esc(i === 0 && dicaPrimeiro ? dicaPrimeiro : "O que acontece neste passo?")}"></textarea>
        <div class="prints"></div>
        <button type="button" class="botao-print">+ Adicionar print <span class="suave">(ou cole com Ctrl+V / arraste aqui)</span></button>`;
      const texto = $("textarea", caixa);
      texto.value = p.texto;
      texto.oninput = () => { p.texto = texto.value; aoMudar(); };
      texto.onfocus = () => { ativo = i; };
      const lugar = $(".prints", caixa);
      p.prints.forEach((pr, j) => {
        const d = document.createElement("div");
        d.className = "print" + (pr.carregando ? " carregando" : "");
        if (pr.carregando) d.textContent = "Preparando o print…";
        else {
          d.innerHTML = pr.tipo === "application/pdf"
            ? `<div class="pdf">PDF anexado</div>`
            : `<img src="${pr.url}" alt="Print ${j + 1} do passo ${i + 1}">`;
          const rm = document.createElement("button");
          rm.type = "button"; rm.className = "tirar"; rm.textContent = "Remover";
          rm.onclick = () => { apagarPrint(pr.id); URL.revokeObjectURL(pr.url); p.prints.splice(j, 1); desenhar(); aoMudar(); };
          d.append(rm);
        }
        lugar.append(d);
      });
      $(".botao-print", caixa).onclick = () => { destino = i; entrada.click(); };
      caixa.querySelectorAll("button.icone").forEach((b) => b.onclick = () => {
        if (b.dataset.a === "subir") [passos[i - 1], passos[i]] = [passos[i], passos[i - 1]];
        if (b.dataset.a === "descer") [passos[i + 1], passos[i]] = [passos[i], passos[i + 1]];
        if (b.dataset.a === "remover") { p.prints.forEach((pr) => apagarPrint(pr.id)); passos.splice(i, 1); }
        desenhar(); aoMudar();
      });
      ["dragenter", "dragover"].forEach((t) => caixa.addEventListener(t, (ev) => {
        if (ev.dataTransfer?.types?.includes("Files")) { ev.preventDefault(); caixa.classList.add("sobre"); }
      }));
      ["dragleave", "drop"].forEach((t) => caixa.addEventListener(t, () => caixa.classList.remove("sobre")));
      caixa.addEventListener("drop", (ev) => { ev.preventDefault(); adicionarArquivos(ev.dataTransfer.files, i); });
      raiz.append(caixa);
    });
    if (focar !== undefined) raiz.querySelectorAll("textarea")[focar]?.focus();
  }

  async function adicionarArquivos(lista, i) {
    const p = passos[i];
    if (!p) return;
    for (const arquivo of lista) {
      const marcador = { id: novoId(), carregando: true };
      p.prints.push(marcador);
      comprimindo++; desenhar(); aoMudar();
      try {
        const pronto = await comprimir(arquivo);
        await guardarPrint(marcador.id, pronto);
        Object.assign(marcador, { carregando: false, url: URL.createObjectURL(pronto), tipo: pronto.type, arquivo: pronto });
      } catch (e) {
        p.prints.splice(p.prints.indexOf(marcador), 1);
        aviso(e.message || "Não foi possível usar este arquivo.", "erro");
      } finally {
        comprimindo--; desenhar(); aoMudar();
      }
    }
  }

  return {
    ocupado: () => comprimindo > 0,
    vazio: () => !passos.some((p) => p.texto.trim() || p.prints.length),
    estado: () => passos.map((p) => ({ texto: p.texto, prints: p.prints.filter((x) => !x.carregando).map((x) => ({ id: x.id, tipo: x.tipo })) })),
    async restaurar(estado) {
      passos = [];
      for (const s of estado || []) {
        const prints = [];
        for (const pr of s.prints || []) {
          const blob = await lerPrint(pr.id);
          if (blob) prints.push({ id: pr.id, tipo: blob.type || pr.tipo, url: URL.createObjectURL(blob), arquivo: blob });
        }
        passos.push({ id: novoId(), texto: s.texto || "", prints });
      }
      desenhar();
    },
    montarEnvio(form) {
      let n = 0;
      return passos.map((p) => ({
        texto: p.texto.trim(),
        arquivos: p.prints.filter((x) => x.arquivo).map((x) => {
          const campo = "a" + n++;
          form.append(campo, x.arquivo, x.arquivo.name || `${campo}.${x.tipo === "application/pdf" ? "pdf" : "jpg"}`);
          return campo;
        }),
      })).filter((p) => p.texto || p.arquivos.length);
    },
    limpar() {
      passos.forEach((p) => p.prints.forEach((pr) => { apagarPrint(pr.id); if (pr.url) URL.revokeObjectURL(pr.url); }));
      passos = [];
      desenhar();
    },
    desenhar,
  };
}

/** Cabeçalho simples das telas públicas: logo + seletor de tema. */
export function montarTopoPublico(subtitulo) {
  const topo = document.createElement("header");
  topo.className = "topo";
  topo.innerHTML = `<span class="marca"><img src="assets/logo.svg" width="30" height="30" alt="">
      <span class="marca-nome">Demandas<small>${esc(subtitulo || "BP-MS")}</small></span></span>
    <span class="direita"><span id="lugar-tema"></span></span>`;
  document.body.prepend(topo);
  if (window.criarSeletorTema) $("#lugar-tema").replaceWith(window.criarSeletorTema());
}
