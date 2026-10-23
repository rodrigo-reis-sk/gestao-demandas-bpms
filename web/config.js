// Configuração das telas. SÓ valores PÚBLICOS (podem ir para o git):
//   • URL do projeto e chave pública (anon/publishable) do Supabase — o RLS protege os dados;
//   • Client ID do app OAuth do ClickUp — o Client Secret fica SÓ nos segredos do Supabase.
// Nunca coloque aqui a chave service_role, senha do banco, token ou Client Secret.
window.CONFIG = {
  supabaseUrl: "https://bucicoxjvokbsnynsmfh.supabase.co",
  supabaseChavePublica: "eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZSIsInJlZiI6ImJ1Y2ljb3hqdm9rYnNueW5zbWZoIiwicm9sZSI6ImFub24iLCJpYXQiOjE3OTI3MTk1NjcsImV4cCI6MjEwODI5NTU2N30.k6sofJq47jrNb1Z2v6HYxwiC2KDD0Q05BmrPNdKmVMM",
  clickupClientId: "", // vazio = OAuth não configurado (a tela oferece o token pessoal)
};
