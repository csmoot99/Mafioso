# Readiness check: passed

URL: http://127.0.0.1:18777/
Page title: FM Codex Browser Probe R2

## Isolation and repository
Both pwd -P and git rev-parse --show-toplevel returned:
/tmp/fm-lab.4xU0mS/treehouse/.treehouse/probe-2752b3/1/probe

Created branch fm/labf6ad7cc2-cdx. Final git status --short was empty.
No project file changes, commits, pushes, or PRs. The task-specific prohibition on commits takes precedence over the generic commit delivery scaffold.
Inbox checked; no messages were present. No AGENTS.md or CLAUDE.md was found by the repository file search.
Read ponytail coding discipline; no code edits were needed.

## Browser verification
Used chrome-devtools-axi with escalated permissions and inherited browser environment.

| Check | Requested | Measured window.innerWidth / innerHeight | Result |
|---|---|---|---|
| Desktop | 1100 x 800 | 1100 / 800 | Passed |
| Phone | 390 x 844 | 390 / 844 | Passed |

Saved and viewed both images:
- [Desktop](desktop.png): three cards in one row, heading and controls visible.
- [Phone](phone.png): three cards stacked vertically, heading wraps, controls visible, no visible horizontal clipping.

Keyboard check at phone width:
1. Press Tab: document.activeElement.id returned exactly `btn`; snapshot identified focused First button.
2. Press Tab: document.activeElement.id returned exactly `lnk`; snapshot identified focused A link.

## Project MCP probes: exact text results
mcp__labmcp__labmcp_probe:
```text
nonce=alpha-f6ad7cc2 server=labmcp cwd=/tmp/fm-lab.4xU0mS/treehouse/.treehouse/probe-2752b3/1/probe
```

mcp__toolsdir__toolsdir_probe:
```text
nonce=beta-f6ad7cc2 server=toolsdir cwd=/tmp/fm-lab.4xU0mS/treehouse/.treehouse/probe-2752b3/1/probe/tools
```

These were every project probe tool exposed in the session; both were called successfully with {}.

## Available MCP servers and tools
Inventory derived from session-exposed tool names, not an assertion about unexposed configured servers.
Servers: codex_apps, codex_worktrees, labmcp, toolsdir.
Total exposed MCP tools: 95.

### codex_apps

- `mcp__codex_apps__chatgpt_space_attach_automation_to_page`
- `mcp__codex_apps__chatgpt_space_create_controller_automation`
- `mcp__codex_apps__chatgpt_space_create_page`
- `mcp__codex_apps__chatgpt_space_create_page_visualization`
- `mcp__codex_apps__chatgpt_space_create_presentation`
- `mcp__codex_apps__chatgpt_space_create_space`
- `mcp__codex_apps__chatgpt_space_edit_page`
- `mcp__codex_apps__chatgpt_space_execute_artifact_code`
- `mcp__codex_apps__chatgpt_space_find_pages`
- `mcp__codex_apps__chatgpt_space_get_artifact_execution_status`
- `mcp__codex_apps__chatgpt_space_get_page_auto_update`
- `mcp__codex_apps__chatgpt_space_get_page_sharing`
- `mcp__codex_apps__chatgpt_space_get_sharing_availability`
- `mcp__codex_apps__chatgpt_space_get_space`
- `mcp__codex_apps__chatgpt_space_get_space_sharing`
- `mcp__codex_apps__chatgpt_space_inspect_artifact`
- `mcp__codex_apps__chatgpt_space_inspect_page_reference`
- `mcp__codex_apps__chatgpt_space_list_page_automations`
- `mcp__codex_apps__chatgpt_space_list_page_comments`
- `mcp__codex_apps__chatgpt_space_list_pages`
- `mcp__codex_apps__chatgpt_space_list_spaces`
- `mcp__codex_apps__chatgpt_space_manage_page_comment`
- `mcp__codex_apps__chatgpt_space_move_page`
- `mcp__codex_apps__chatgpt_space_patch_page`
- `mcp__codex_apps__chatgpt_space_progress_update`
- `mcp__codex_apps__chatgpt_space_read_page`
- `mcp__codex_apps__chatgpt_space_read_page_changes`
- `mcp__codex_apps__chatgpt_space_read_page_reference`
- `mcp__codex_apps__chatgpt_space_read_page_transcript`
- `mcp__codex_apps__chatgpt_space_reply_page_comment`
- `mcp__codex_apps__chatgpt_space_run_page_auto_update`
- `mcp__codex_apps__chatgpt_space_search_sharing_recipients`
- `mcp__codex_apps__chatgpt_space_set_page_auto_update`
- `mcp__codex_apps__chatgpt_space_trash_page`
- `mcp__codex_apps__chatgpt_space_update_page_sharing`
- `mcp__codex_apps__chatgpt_space_update_space_sharing`
- `mcp__codex_apps__chatgpt_space_upload_artifact_images`
- `mcp__codex_apps__chatgpt_space_write_page_reference`
- `mcp__codex_apps__codex_document_control_execute_document_command`
- `mcp__codex_apps__codex_document_control_get_document_tool_schemas`
- `mcp__codex_apps__codex_document_control_list_document_sessions`
- `mcp__codex_apps__hotline_get_local_hotline`
- `mcp__codex_apps__pets_adopt`
- `mcp__codex_apps__pets_create_pet`
- `mcp__codex_apps__pets_delete_pet`
- `mcp__codex_apps__pets_get_pet_download_link`
- `mcp__codex_apps__pets_list_pets`
- `mcp__codex_apps__pets_prepare_pet_upload`
- `mcp__codex_apps__pets_select_pet`
- `mcp__codex_apps__pets_share_pet`
- `mcp__codex_apps__pets_unshare_pet`
- `mcp__codex_apps__pets_update_pet`
- `mcp__codex_apps__pets_validate_pet_spritesheet`
- `mcp__codex_apps__plugin_management_get_app_permissions`
- `mcp__codex_apps__plugin_management_get_plugin_dependencies`
- `mcp__codex_apps__plugin_management_search_plugins`
- `mcp__codex_apps__plugin_management_suggest_plugins`
- `mcp__codex_apps__plugin_management_uninstall_app`
- `mcp__codex_apps__plugin_management_update_app_permissions`
- `mcp__codex_apps__safety_settings_get_family_info`
- `mcp__codex_apps__safety_settings_get_parental_controls`
- `mcp__codex_apps__safety_settings_get_trusted_contact`
- `mcp__codex_apps__safety_settings_prepare_parental_control_update`
- `mcp__codex_apps__safety_settings_update_parental_control`
- `mcp__codex_apps__search_service_web_run`
- `mcp__codex_apps__sites_add_custom_domain`
- `mcp__codex_apps__sites_change_site_slug`
- `mcp__codex_apps__sites_create_schedule`
- `mcp__codex_apps__sites_create_site`
- `mcp__codex_apps__sites_create_source_repository_write_credential`
- `mcp__codex_apps__sites_deploy_private_site_version`
- `mcp__codex_apps__sites_deploy_site_version`
- `mcp__codex_apps__sites_generate_siwc_bypass_token`
- `mcp__codex_apps__sites_get_deployment_status`
- `mcp__codex_apps__sites_get_environment_variables`
- `mcp__codex_apps__sites_get_site`
- `mcp__codex_apps__sites_get_site_version`
- `mcp__codex_apps__sites_get_site_worker_logs`
- `mcp__codex_apps__sites_list_custom_domains`
- `mcp__codex_apps__sites_list_site_versions`
- `mcp__codex_apps__sites_list_sites`
- `mcp__codex_apps__sites_read_database_overview`
- `mcp__codex_apps__sites_read_database_table_rows`
- `mcp__codex_apps__sites_refresh_custom_domain_status`
- `mcp__codex_apps__sites_remove_custom_domain`
- `mcp__codex_apps__sites_save_site_version`
- `mcp__codex_apps__sites_save_version_and_deploy_private`
- `mcp__codex_apps__sites_update_environment_variables`
- `mcp__codex_apps__sites_update_site_access`
- `mcp__codex_apps__sites_update_site_metadata`

### codex_worktrees

- `mcp__codex_worktrees__create_worktree`
- `mcp__codex_worktrees__get_worktree_creation_status`
- `mcp__codex_worktrees__list_worktrees`

### labmcp

- `mcp__labmcp__labmcp_probe`

### toolsdir

- `mcp__toolsdir__toolsdir_probe`

Generic MCP resource helpers also available: list_mcp_resources, list_mcp_resource_templates, read_mcp_resource.

## Errors and recovery
1. Initial broad tool-metadata output was truncated (original token count 71555). Recovered by enumerating names only and retaining the complete names inventory for this report.
2. Initial sandboxed branch creation failed with the exact error:
```text
fatal: Unable to create '/tmp/fm-lab.4xU0mS/home/projects/probe/.git/worktrees/probe/index.lock': Read-only file system
```
Retried once with escalated sandbox permissions and succeeded:
```text
Switched to a new branch 'fm/labf6ad7cc2-cdx'
```
No browser or probe errors occurred. No obstacle blocked a step twice.

## Scope
All requested readiness checks completed. No project implementation, commit, push, pipeline, or broader accessibility audit performed.

