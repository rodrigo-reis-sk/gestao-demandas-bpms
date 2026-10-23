' Abre o Lançar ClickUp: sobe o serviço local (escondido) e abre o navegador.
Set fso = CreateObject("Scripting.FileSystemObject")
pasta = fso.BuildPath(fso.GetParentFolderName(WScript.ScriptFullName), "central")
Set sh = CreateObject("WScript.Shell")
sh.CurrentDirectory = pasta
py = "pyw"
On Error Resume Next
sh.Run "where pyw", 0, True
If Err.Number <> 0 Then py = "pythonw"
On Error GoTo 0
sh.Run py & " servico\servidor.py", 0, False
