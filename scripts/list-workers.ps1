[CmdletBinding()]
param([switch]$Json)
$raw = & (Join-Path $PSScriptRoot "list-pairs.ps1") -Json
$parsed = $raw | ConvertFrom-Json
$pairs = @()
# Windows PowerShell 5.1 preserves a top-level JSON array as one pipeline
# object. A foreach statement explicitly enumerates it and avoids producing one
# bogus worker whose every property is itself an array.
foreach ($pair in $parsed) { $pairs += $pair }
$workers = @($pairs | ForEach-Object {
    [PSCustomObject]@{
        worker_id=$_.pair_id; pair_id=$_.pair_id; name=$_.worker_name; mode=$_.mode; sandbox=$_.sandbox
        isolation=$_.isolation; model=$_.codex_model; reasoning=$_.codex_reasoning; status=$_.status
        project_cwd=$_.project_cwd; source_project_cwd=$_.source_project_cwd; listener_pid=$_.listener_pid
        thread_id=$_.codex_session_id; writer_lease=$_.writer_lease; last_activity=$_.last_activity; task_hint=$_.task_hint
        active_message_id=$_.active_message_id; active_elapsed_sec=$_.active_elapsed_sec; queue_depth=$_.queue_depth
        pending_message_ids=@($_.pending_message_ids); completed_turns=$_.completed_turns; max_turns=$_.max_turns
        progress_count=$_.progress_count; last_progress_at=$_.last_progress_at; last_progress=$_.last_progress; max_progress_updates=$_.max_progress_updates
    }
})
if ($Json) { ConvertTo-Json -InputObject $workers -Depth 8 } else { $workers | Format-Table worker_id,name,mode,isolation,model,reasoning,status,queue_depth -AutoSize }
