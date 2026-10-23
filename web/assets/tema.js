// Tema claro / escuro / automático.
// Carregado no <head> de cada página (sem "type=module") para aplicar o tema ANTES de desenhar,
// evitando o "piscar" de claro para escuro. A escolha fica salva só neste navegador.
(function () {
  var CHAVE = "gestao-bpms-tema";               // "claro" | "escuro" | "auto"
  var sistemaEscuro = window.matchMedia("(prefers-color-scheme: dark)");

  function lerEscolha() {
    try { return localStorage.getItem(CHAVE) || "auto"; } catch (e) { return "auto"; }
  }
  function aplicar(escolha) {
    var efetivo = escolha === "auto" ? (sistemaEscuro.matches ? "escuro" : "claro") : escolha;
    document.documentElement.setAttribute("data-tema", efetivo);
    document.documentElement.setAttribute("data-tema-escolha", escolha);
  }

  aplicar(lerEscolha());
  // No automático, acompanha a troca de tema do Windows na hora.
  sistemaEscuro.addEventListener("change", function () { if (lerEscolha() === "auto") aplicar("auto"); });

  var ICONES = {
    claro: '<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round"><circle cx="12" cy="12" r="4"/><path d="M12 2v2M12 20v2M4.9 4.9l1.4 1.4M17.7 17.7l1.4 1.4M2 12h2M20 12h2M4.9 19.1l1.4-1.4M17.7 6.3l1.4-1.4"/></svg>',
    auto: '<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2"><rect x="3" y="4" width="18" height="12" rx="2"/><path d="M8 20h8M12 16v4" stroke-linecap="round"/></svg>',
    escuro: '<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linejoin="round"><path d="M21 12.8A9 9 0 1 1 11.2 3a7 7 0 0 0 9.8 9.8z"/></svg>',
  };
  var NOMES = { claro: "Tema claro", auto: "Automático (segue o sistema)", escuro: "Tema escuro" };

  /** Cria o seletor de tema (3 botões) e devolve o elemento. */
  window.criarSeletorTema = function () {
    var grupo = document.createElement("div");
    grupo.className = "tema";
    grupo.setAttribute("role", "group");
    grupo.setAttribute("aria-label", "Tema");
    ["claro", "auto", "escuro"].forEach(function (opcao) {
      var b = document.createElement("button");
      b.type = "button";
      b.title = NOMES[opcao];
      b.setAttribute("aria-label", NOMES[opcao]);
      b.dataset.tema = opcao;
      b.innerHTML = ICONES[opcao];
      b.onclick = function () {
        try { localStorage.setItem(CHAVE, opcao); } catch (e) { /* navegador sem armazenamento */ }
        aplicar(opcao);
        marcar();
      };
      grupo.appendChild(b);
    });
    function marcar() {
      var atual = lerEscolha();
      grupo.querySelectorAll("button").forEach(function (b) {
        b.setAttribute("aria-pressed", String(b.dataset.tema === atual));
      });
    }
    marcar();
    return grupo;
  };
})();
