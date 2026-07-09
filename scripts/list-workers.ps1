[CmdletBinding()]
param([switch]$Json)
$raw = & (Join-Path $PSScriptRoot "list-pairs.ps1") -Json
$pairs = @($raw | ConvertFrom-Json)
$workers = @($pairs | ForEach-Object {
    [PSCustomObject]@{
        worker_id=$_.pair_id; pair_id=$_.pair_id; name=$_.worker_name; mode=$_.mode; sandbox=$_.sandbox
        isolation=$_.isolation; model=$_.codex_model; reasoning=$_.codex_reasoning; status=$_.status
        project_cwd=$_.project_cwd; source_project_cwd=$_.source_project_cwd; listener_pid=$_.listener_pid
        thread_id=$_.codex_session_id; writer_lease=$_.writer_lease; last_activity=$_.last_activity; task_hint=$_.task_hint
    }
})
if ($Json) { ConvertTo-Json -InputObject $workers -Depth 8 } else { $workers | Format-Table worker_id,name,mode,isolation,model,reasoning,status -AutoSize }
