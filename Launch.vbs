' NetPulse launcher (hidden window, no console flash)
' Called by NetPulse.cmd; can also be double-clicked directly.
'
' Why VBS instead of mshta:
'   mshta's vbscript: URI requires quoting every " as "",
'   which breaks easily when the path contains spaces or CJK characters.
'
' NOTE: keep this file ASCII-only. VBScript is read in the system ANSI
' code page, so UTF-8 Chinese comments become mojibake and break parsing.

Option Explicit

Dim fso, sh, here, ui, ps, cmd
Set fso = CreateObject("Scripting.FileSystemObject")
Set sh  = CreateObject("WScript.Shell")

here = fso.GetParentFolderName(WScript.ScriptFullName)
ui   = here & "\Start-NetPulse.ps1"

If Not fso.FileExists(ui) Then
    MsgBox "Cannot find:" & vbCrLf & ui & vbCrLf & vbCrLf & _
           "Please make sure all files were extracted together.", 16, "NetPulse"
    WScript.Quit 1
End If

' Prefer PowerShell 7 when present, otherwise fall back to built-in 5.1
ps = "powershell.exe"
Dim pwshPath
pwshPath = sh.ExpandEnvironmentStrings("%ProgramFiles%") & "\PowerShell\7\pwsh.exe"
If fso.FileExists(pwshPath) Then
    ps = pwshPath
End If

cmd = """" & ps & """ -NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File """ & ui & """"

' 0 = hidden window, False = do not wait
sh.Run cmd, 0, False
