# PowerShell mirror of test-commit-scope.sh — verifies that the artifact
# commits in the ideate (Step 9) and stridify (Step 8d) skills commit ONLY the
# artifact when another file was staged before the session.
#
# On a PowerShell-only host the skills tell the model to run the same two git
# commands as the bash block. This test reads those commands from each skill's
# block — the `git add` line and every `git commit` line — and runs them from
# PowerShell in a scratch repository (with and without prior history) whose
# index already holds an unrelated staged file.
#
# Run:
#   pwsh -NoProfile -File lib/test-commit-scope.ps1
#
# Exits 0 if all tests pass, non-zero otherwise.

Set-StrictMode -Version Latest

$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$PluginRoot = Split-Path -Parent $ScriptDir

$script:PASS = 0
$script:FAIL = 0
function Pass($m) { $script:PASS++; Write-Host "  PASS  $m" }
function Fail($m, $d = '') { $script:FAIL++; Write-Host "  FAIL  $m"; if ($d) { Write-Host "        $d" } }

Write-Host 'test-commit-scope.ps1 — the artifact commit leaves pre-staged files alone'
Write-Host ''

$ReqDoc = 'docs/ideation/2026-05-12T103000-dark-mode-toggle-requirements.md'
$Batch  = 'docs/ideation/2026-05-12T120000-dark-mode-toggle-stride-batch.json'
$Staged = 'docs/ideation/unrelated-notes.md'
$Tmp = Join-Path ([System.IO.Path]::GetTempPath()) ('sti-commit-scope-' + [guid]::NewGuid())
New-Item -ItemType Directory -Path $Tmp | Out-Null

# Get-CommitLines <skill> — the `git commit` lines of the skill's commit block.
function Get-CommitLines([string]$Skill) {
    $text = [System.IO.File]::ReadAllText((Join-Path $PluginRoot "skills/$Skill/SKILL.md"))
    $blocks = [regex]::Matches($text, '(?ms)^```bash[ \t]*\r?\n(.*?)^```') |
        Where-Object { $_.Groups[1].Value.Contains('git add -- "$TARGET_PATH"') }
    if (@($blocks).Count -ne 1) { throw "expected one commit block in $Skill, found $(@($blocks).Count)" }
    return @(($blocks[0].Groups[1].Value -split "\r?\n") | Where-Object { $_ -match '^\s*git commit ' })
}

# New-Repo <dir> <withHistory> — scratch repo with an unrelated staged file.
function New-Repo([string]$Dir, [bool]$WithHistory) {
    New-Item -ItemType Directory -Force -Path (Join-Path $Dir 'docs/ideation') | Out-Null
    & git -C $Dir init -q
    & git -C $Dir config user.email test@example.com
    & git -C $Dir config user.name test
    if ($WithHistory) {
        Set-Content -LiteralPath (Join-Path $Dir 'README.md') -Value 'seed'
        & git -C $Dir add README.md
        & git -C $Dir commit -q -m seed
    }
    Set-Content -LiteralPath (Join-Path $Dir $Staged) -Value 'private scratch notes, not for this commit'
    & git -C $Dir add $Staged
    Set-Content -LiteralPath (Join-Path $Dir $ReqDoc) -Value '# Dark mode toggle'
    Copy-Item -LiteralPath (Join-Path $PluginRoot 'fixtures/2026-05-12T120000-dark-mode-toggle-stride-batch.json') -Destination (Join-Path $Dir $Batch)
}

# Invoke-SkillCommit <dir> <artifact> <message> <usePathspec> — the two
# commands the skill's block runs, issued from PowerShell.
function Invoke-SkillCommit([string]$Dir, [string]$Artifact, [string]$Message, [bool]$UsePathspec) {
    & git -C $Dir add -- $Artifact
    if ($UsePathspec) {
        & git -C $Dir commit -q -m $Message -- $Artifact
    } else {
        & git -C $Dir commit -q -m $Message
    }
    return $LASTEXITCODE
}

try {
    $cases = @(
        @{ Label = 'ideate Step 9'; Skill = 'stride-ideation-ideate'; Artifact = $ReqDoc; Message = 'stride-ideation: requirements for dark-mode-toggle' },
        @{ Label = 'stridify Step 8d'; Skill = 'stride-ideation-stridify'; Artifact = $Batch; Message = 'stride-ideation: decomposition for dark-mode-toggle' }
    )
    foreach ($case in $cases) {
        $commitLines = Get-CommitLines $case.Skill
        $withPathspec = @($commitLines | Where-Object { $_.Contains('-- "$TARGET_PATH"') })
        if ($commitLines.Count -ge 2 -and $withPathspec.Count -eq $commitLines.Count) {
            Pass "$($case.Label): every git commit line passes the artifact as a pathspec"
        } else {
            Fail "$($case.Label): a git commit line has no -- `"`$TARGET_PATH`" pathspec" ($commitLines -join ' | ')
        }

        foreach ($history in @($true, $false)) {
            $tag = "$($case.Label) (history: $(if ($history) { 'yes' } else { 'no' }))"
            $dir = Join-Path $Tmp ([guid]::NewGuid())
            New-Repo $dir $history
            $rc = Invoke-SkillCommit $dir $case.Artifact $case.Message ($withPathspec.Count -gt 0)
            if ($rc -ne 0) { Fail "${tag}: the commit exited $rc"; continue }
            $committed = @((& git -C $dir show --name-only --pretty=format: HEAD) | Where-Object { $_ })
            if ($committed.Count -eq 1 -and $committed[0] -eq $case.Artifact) {
                Pass "${tag}: the new commit contains only the artifact"
            } else {
                Fail "${tag}: the new commit contains more than the artifact" ($committed -join ' ')
            }
            $stillStaged = @(& git -C $dir diff --cached --name-only) -contains $Staged
            if ($stillStaged) { Pass "${tag}: the pre-staged file is still staged" } else { Fail "${tag}: the pre-staged file is no longer staged" }
            if ($committed -contains $Staged) { Fail "${tag}: the pre-staged file was swept into the commit" } else { Pass "${tag}: the pre-staged file is absent from the commit" }
        }
    }

    # Control: without the pathspec, git commit records the pre-staged file too.
    $dir = Join-Path $Tmp 'control'
    New-Repo $dir $true
    $null = Invoke-SkillCommit $dir $ReqDoc 'stride-ideation: requirements for dark-mode-toggle' $false
    if (@(& git -C $dir show --name-only --pretty=format: HEAD) -contains $Staged) {
        Pass 'control: without the pathspec the pre-staged file is swept in'
    } else {
        Fail 'control: the no-pathspec commit did not sweep, so the cases above prove nothing'
    }
} finally {
    Remove-Item -LiteralPath $Tmp -Recurse -Force -ErrorAction SilentlyContinue
}

Write-Host ''
Write-Host ("{0} passed, {1} failed" -f $script:PASS, $script:FAIL)
if ($script:FAIL -gt 0) { exit 1 } else { exit 0 }
