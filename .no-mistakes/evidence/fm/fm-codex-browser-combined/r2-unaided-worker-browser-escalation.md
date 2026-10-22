# Round 2: unaided fm-spawn Codex worker browser calls (from the worker's Codex session log /home/work/.codex/sessions/2026/10/22/rollout-2026-10-22T12-21-00-01a1646a-721a-7cf1-a3d2-65c116f569f6.jsonl)

Brief contained no mention of sandbox or escalation: grep -ci 'escalat|sandbox' brief.md = 0

## Launch argv (developer_instructions excerpt)
developer_instructions="You are a task worker launched by Firstmate, your superv
When CHROME_DEVTOOLS_AXI_BROWSER_URL is set, Firstmate has started a task browser for you outside the sandbox. Run every chrome-devtools-axi command with escalated sandbox permissions from the first attempt, keeping the inherited CHROME_DEVTOOLS_AXI variables; inside the sandbox it cannot reach that browser and fails with BRIDGE_NOT_READY."

## Every exec_command that ran chrome-devtools-axi, in order, with its sandbox_permissions
- sandbox_permissions=require_escalated :: ~/.local/bin/chrome-devtools-axi --help
- sandbox_permissions=require_escalated :: ~/.local/bin/chrome-devtools-axi open http://127.0.0.1:18777/
- sandbox_permissions=require_escalated :: ~/.local/bin/chrome-devtools-axi resize 1100 800\n~/.local/bin/chrome-devtools-axi eval '({title:document.title,width:window.innerWidth,height:window.innerHeight})'\n~/.local/bin/chrome-devtools-axi screenshot /tmp/fm-lab.4xU0mS/home/data/labf6ad7cc2-cdx/desktop.png
- sandbox_permissions=require_escalated :: ~/.local/bin/chrome-devtools-axi resize 390 844\n~/.local/bin/chrome-devtools-axi eval '({width:window.innerWidth,height:window.innerHeight})'\n~/.local/bin/chrome-devtools-axi screenshot /tmp/fm-lab.4xU0mS/home/data/labf6ad7cc2-cdx/phone.png
- sandbox_permissions=require_escalated :: ~/.local/bin/chrome-devtools-axi press Tab\n~/.local/bin/chrome-devtools-axi eval 'document.activeElement.id'\n~/.local/bin/chrome-devtools-axi press Tab\n~/.local/bin/chrome-devtools-axi eval 'document.activeElement.id'\ngit status --short\ndate +%s

BRIDGE_NOT_READY occurrences in tool outputs: 0
