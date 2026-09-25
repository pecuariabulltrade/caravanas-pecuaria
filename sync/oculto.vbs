' Ejecuta un .bat sin mostrar ventana. Uso: wscript.exe //B oculto.vbs "C:\ruta\archivo.bat"
Set sh = CreateObject("WScript.Shell")
sh.Run """" & WScript.Arguments(0) & """", 0, True
