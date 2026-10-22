# Worker readiness probe

Isolation verified: `pwd -P` and `git rev-parse --show-toplevel` both returned `/tmp/fm-lab.4xU0mS/treehouse/.treehouse/probe-2752b3/1/probe`.

## MCP servers and tools

The session exposes `codex_apps`, `codex_worktrees`, `labmcp`, `toolsdir`. Project `.mcp.json` supplies `labmcp` and `toolsdir`. It also configures `unapproved` and `blocked`, but neither exposes tools in this session. `codex_apps` and `codex_worktrees` are session-provided, not declared by this project.

- **codex_apps**: `chatgpt_space_attach_automation_to_page`, `chatgpt_space_create_controller_automation`, `chatgpt_space_create_page`, `chatgpt_space_create_page_visualization`, `chatgpt_space_create_presentation`, `chatgpt_space_create_space`, `chatgpt_space_edit_page`, `chatgpt_space_execute_artifact_code`, `chatgpt_space_find_pages`, `chatgpt_space_get_artifact_execution_status`, `chatgpt_space_get_page_auto_update`, `chatgpt_space_get_page_sharing`, `chatgpt_space_get_sharing_availability`, `chatgpt_space_get_space`, `chatgpt_space_get_space_sharing`, `chatgpt_space_inspect_artifact`, `chatgpt_space_inspect_page_reference`, `chatgpt_space_list_page_automations`, `chatgpt_space_list_page_comments`, `chatgpt_space_list_pages`, `chatgpt_space_list_spaces`, `chatgpt_space_manage_page_comment`, `chatgpt_space_move_page`, `chatgpt_space_patch_page`, `chatgpt_space_progress_update`, `chatgpt_space_read_page`, `chatgpt_space_read_page_changes`, `chatgpt_space_read_page_reference`, `chatgpt_space_read_page_transcript`, `chatgpt_space_reply_page_comment`, `chatgpt_space_run_page_auto_update`, `chatgpt_space_search_sharing_recipients`, `chatgpt_space_set_page_auto_update`, `chatgpt_space_trash_page`, `chatgpt_space_update_page_sharing`, `chatgpt_space_update_space_sharing`, `chatgpt_space_upload_artifact_images`, `chatgpt_space_write_page_reference`, `codex_document_control_execute_document_command`, `codex_document_control_get_document_tool_schemas`, `codex_document_control_list_document_sessions`, `hotline_get_local_hotline`, `pets_adopt`, `pets_create_pet`, `pets_delete_pet`, `pets_get_pet_download_link`, `pets_list_pets`, `pets_prepare_pet_upload`, `pets_select_pet`, `pets_share_pet`, `pets_unshare_pet`, `pets_update_pet`, `pets_validate_pet_spritesheet`, `plugin_management_get_app_permissions`, `plugin_management_get_plugin_dependencies`, `plugin_management_search_plugins`, `plugin_management_suggest_plugins`, `plugin_management_uninstall_app`, `plugin_management_update_app_permissions`, `safety_settings_get_family_info`, `safety_settings_get_parental_controls`, `safety_settings_get_trusted_contact`, `safety_settings_prepare_parental_control_update`, `safety_settings_update_parental_control`, `search_service_web_run`, `sites_add_custom_domain`, `sites_change_site_slug`, `sites_create_schedule`, `sites_create_site`, `sites_create_source_repository_write_credential`, `sites_deploy_private_site_version`, `sites_deploy_site_version`, `sites_generate_siwc_bypass_token`, `sites_get_deployment_status`, `sites_get_environment_variables`, `sites_get_site`, `sites_get_site_version`, `sites_get_site_worker_logs`, `sites_list_custom_domains`, `sites_list_site_versions`, `sites_list_sites`, `sites_read_database_overview`, `sites_read_database_table_rows`, `sites_refresh_custom_domain_status`, `sites_remove_custom_domain`, `sites_save_site_version`, `sites_save_version_and_deploy_private`, `sites_update_environment_variables`, `sites_update_site_access`, `sites_update_site_metadata`
- **codex_worktrees**: `create_worktree`, `get_worktree_creation_status`, `list_worktrees`
- **labmcp**: `labmcp_probe`
- **toolsdir**: `toolsdir_probe`

Other available execution/tool helpers (not project MCP servers): `apply_patch`, `clock__curr_time`, `create_goal`, `exec_command`, `get_goal`, `image_gen__imagegen`, `list_mcp_resource_templates`, `list_mcp_resources`, `read_mcp_resource`, `update_goal`, `view_image`, `web__run`, `write_stdin`. Direct orchestration interfaces also include functions exec/wait/input, clock sleep, and collaboration tools.

## Exact probe text results

```text
nonce=alpha-cef16c2b server=labmcp cwd=/tmp/fm-lab.4xU0mS/treehouse/.treehouse/probe-2752b3/1/probe
```

```text
nonce=beta-cef16c2b server=toolsdir cwd=/tmp/fm-lab.4xU0mS/treehouse/.treehouse/probe-2752b3/1/probe/tools
```

## Browser

- `CHROME_DEVTOOLS_AXI_BROWSER_URL=http://127.0.0.1:43113`
- `CHROME_DEVTOOLS_AXI_SESSION=fm-codex-browser.poUvT9PG`
- Inherited environment preserved.
- First open attempt: `error: Bridge failed to start within 30s`, `code: BRIDGE_NOT_READY`.
- Second open attempt returned the same exact error: `error: Bridge failed to start within 30s`, `code: BRIDGE_NOT_READY`.
- Initial run stopped after the same obstacle twice. On the authorized retry, every chrome-devtools-axi command used escalated sandbox permissions and succeeded with the inherited environment unchanged.
- Opened `http://127.0.0.1:18777/`; page title: `FM Codex Browser Probe`.
- Desktop resize: 1100 × 800; eval of `({width: window.innerWidth, height: window.innerHeight})` returned `{"width":1100,"height":800}`.
- Phone resize: 390 × 844; the same eval returned `{"width":390,"height":844}`.
- Saved and viewed [worker-desktop.png](worker-desktop.png) and [worker-phone.png](worker-phone.png). Desktop shows three cards in a row; phone shows the cards stacked. Both display the matching viewport width.
- After the first `press Tab`, eval of `document.activeElement.id` returned `"btn"`.
- After the second `press Tab`, eval of `document.activeElement.id` returned `"lnk"`.

## Failures and scope

Branch creation failed: `fatal: Unable to create '/tmp/fm-lab.4xU0mS/home/projects/probe/.git/worktrees/probe/index.lock': Read-only file system`.
No project files changed, commits created, or pushes performed. The task-specific no-commit instruction takes precedence over the generic delivery scaffold.
Final `git status --porcelain` was empty. Steering inbox contained no pending messages. MCP readiness and all requested browser checks passed. The prior browser failure cleared when commands ran with escalated socket access; no browser command failed on the retry. The branch-creation failure above remains recorded as a setup limitation; no Git mutations were retried.

