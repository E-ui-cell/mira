# MIRA skills

MIRA includes built-in task playbooks:

- file-management
- windows-settings
- desktop-gui
- clipboard
- system-inspection
- quick-web-tools

User-authored skills are Markdown files stored in:

%USERPROFILE%\.mira\skills\<skill-name>.md

Use .skills to list available skills and .skill <name> to load one in the TUI. The model can also call the get_skill tool to load a relevant playbook on demand.

Skills should describe workflows, constraints, inspection steps and verification. They are guidance only: a skill cannot grant tool permissions, bypass ASK/AUTOPILOT, or override MIRA's system rules. Treat skill contents as untrusted instructions and review user-authored skills before using them.
