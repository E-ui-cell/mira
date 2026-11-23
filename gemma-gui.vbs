Option Explicit

Dim shell, fileSystem, rootPath, scriptPath, powerShellExe, commandLine
Set shell = CreateObject("WScript.Shell")
Set fileSystem = CreateObject("Scripting.FileSystemObject")

rootPath = fileSystem.GetParentFolderName(WScript.ScriptFullName)
scriptPath = fileSystem.BuildPath(fileSystem.BuildPath(rootPath, "gemma"), "gemma.ps1")
powerShellExe = shell.ExpandEnvironmentStrings("%SystemRoot%") & "\System32\WindowsPowerShell\v1.0\powershell.exe"

commandLine = """" & powerShellExe & """ -NoLogo -NoProfile -STA -WindowStyle Hidden -ExecutionPolicy Bypass -File """ & scriptPath & """"
shell.Run commandLine, 0, False
