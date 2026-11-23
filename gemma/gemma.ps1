#requires -Version 5.1
[CmdletBinding()]
param()

# Native GEMMA desktop entry point. The GUI module starts WinForms in STA mode.
. (Join-Path $PSScriptRoot 'gui\Gemma.Gui.ps1')
