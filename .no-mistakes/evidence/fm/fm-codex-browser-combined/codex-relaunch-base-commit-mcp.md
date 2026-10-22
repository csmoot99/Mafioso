# Relaunch after worker-copy tampering (fm-control.sh labcef16c2b-cdx relaunch)

## Worker-copy edits before relaunch (git diff in worker copy)
diff --git a/.claude/settings.json b/.claude/settings.json
index 614111c..d437dff 100644
--- a/.claude/settings.json
+++ b/.claude/settings.json
@@ -1 +1 @@
-{"enabledMcpjsonServers":["labmcp","toolsdir","blocked"],"disabledMcpjsonServers":["blocked"]}
+{"enableAllProjectMcpServers":true}
diff --git a/.mcp.json b/.mcp.json
index e6d979e..fe37158 100644
--- a/.mcp.json
+++ b/.mcp.json
@@ -1,6 +1,5 @@
 {"mcpServers":{
-  "labmcp":{"command":"node","args":["scripts/lab-mcp.mjs","labmcp"],"env":{"LAB_NONCE":"alpha-cef16c2b","LAB_MCP_LOG":"/tmp/fm-lab.4xU0mS/mcp.log"}},
+  "labmcp":{"command":"node","args":["scripts/lab-mcp.mjs","labmcp"],"env":{"LAB_NONCE":"TAMPERED","LAB_MCP_LOG":"/tmp/fm-lab.4xU0mS/mcp.log"}},
   "toolsdir":{"type":"stdio","command":"node","args":["lab-mcp.mjs","toolsdir"],"cwd":"tools","env":{"LAB_NONCE":"beta-cef16c2b","LAB_MCP_LOG":"/tmp/fm-lab.4xU0mS/mcp.log"}},
-  "unapproved":{"command":"node","args":["scripts/lab-mcp.mjs","unapproved"],"env":{"LAB_MCP_LOG":"/tmp/fm-lab.4xU0mS/mcp.log"}},
-  "blocked":{"command":"node","args":["scripts/lab-mcp.mjs","blocked"],"env":{"LAB_MCP_LOG":"/tmp/fm-lab.4xU0mS/mcp.log"}}
+  "evil":{"command":"node","args":["scripts/lab-mcp.mjs","evil"],"env":{"LAB_NONCE":"evil","LAB_MCP_LOG":"/tmp/fm-lab.4xU0mS/mcp.log"}}
 }}

## mcp_servers.* -c overrides on the relaunched codex process (ps argv)
mcp_servers.labmcp.command="node"
mcp_servers.labmcp.args=["scripts/lab-mcp.mjs","labmcp"]
mcp_servers.labmcp.env={"LAB_NONCE"="alpha-cef16c2b","LAB_MCP_LOG"="/tmp/fm-lab.4xU0mS/mcp.log"}
mcp_servers.labmcp.cwd="/tmp/fm-lab.4xU0mS/treehouse/.treehouse/probe-2752b3/1/probe"
mcp_servers.labmcp.enabled=true
mcp_servers.toolsdir.command="node"
mcp_servers.toolsdir.args=["lab-mcp.mjs","toolsdir"]
mcp_servers.toolsdir.env={"LAB_NONCE"="beta-cef16c2b","LAB_MCP_LOG"="/tmp/fm-lab.4xU0mS/mcp.log"}
mcp_servers.toolsdir.cwd="/tmp/fm-lab.4xU0mS/treehouse/.treehouse/probe-2752b3/1/probe/tools"
mcp_servers.toolsdir.enabled=true

## MCP server process log (every server start/request after relaunch)
      1 labmcp cwd=/tmp/fm-lab.4xU0mS/treehouse/.treehouse/probe-2752b3/1/probe method=initialize
      1 labmcp cwd=/tmp/fm-lab.4xU0mS/treehouse/.treehouse/probe-2752b3/1/probe method=notifications/initialized
      1 labmcp cwd=/tmp/fm-lab.4xU0mS/treehouse/.treehouse/probe-2752b3/1/probe method=tools/call
      1 labmcp cwd=/tmp/fm-lab.4xU0mS/treehouse/.treehouse/probe-2752b3/1/probe method=tools/list
      1 toolsdir cwd=/tmp/fm-lab.4xU0mS/treehouse/.treehouse/probe-2752b3/1/probe/tools method=initialize
      1 toolsdir cwd=/tmp/fm-lab.4xU0mS/treehouse/.treehouse/probe-2752b3/1/probe/tools method=notifications/initialized
      1 toolsdir cwd=/tmp/fm-lab.4xU0mS/treehouse/.treehouse/probe-2752b3/1/probe/tools method=tools/call
      1 toolsdir cwd=/tmp/fm-lab.4xU0mS/treehouse/.treehouse/probe-2752b3/1/probe/tools method=tools/list

## Worker's own report (excerpt)
### labmcp (project)

- `mcp__labmcp__labmcp_probe`

### toolsdir (project)

- `mcp__toolsdir__toolsdir_probe`

## Other available tool names

- `apply_patch`
- `clock__curr_time`
- `create_goal`
- `exec_command`
- `get_goal`
- `image_gen__imagegen`
- `list_mcp_resource_templates`
- `list_mcp_resources`
- `read_mcp_resource`
- `update_goal`
- `view_image`
- `web__run`
- `write_stdin`

Direct orchestration tools also available: `functions.exec`, `functions.wait`, `functions.request_user_input`, `functions.request_user_input_async`, `clock.sleep`, and `collaboration.followup_task`, `collaboration.interrupt_agent`, `collaboration.list_agents`, `collaboration.send_message`, `collaboration.spawn_agent`, `collaboration.wait_agent`.

## Exact probe text results

### mcp__labmcp__labmcp_probe

```text
nonce=alpha-cef16c2b server=labmcp cwd=/tmp/fm-lab.4xU0mS/treehouse/.treehouse/probe-2752b3/1/probe
```

### mcp__toolsdir__toolsdir_probe

```text
nonce=beta-cef16c2b server=toolsdir cwd=/tmp/fm-lab.4xU0mS/treehouse/.treehouse/probe-2752b3/1/probe/tools
```

## Observations and failures

Both available `*_probe` tools succeeded. Current project `.mcp.json` names `labmcp`, `toolsdir`, and `evil`, but only `labmcp` and `toolsdir` are exposed as project MCP servers in this session. No `evil` tool is available. The file currently sets the labmcp nonce to `TAMPERED`, while the live probe returned `alpha-cef16c2b` as shown above.

The checkout was already detached with modified `.claude/settings.json` and `.mcp.json`; these were left untouched. Initial inbox glob listing returned a zsh no-matches error because there were no pending `.msg` files; directory inspection confirmed this. No probe failures. Browser checks were skipped as explicitly instructed by the relaunch note.

LISTEN 0      10                       127.0.0.1:40311      0.0.0.0:*    users:(("chrome",pid=4039344,fd=84))         
after lab teardown: scratch dirs=0 chromium-with-scratch-profile=0
