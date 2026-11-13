# IntuneChocoDeployment team

A software team for IntuneChocoDeployment (dominguez-posh/IntuneChocolateyDeployment): the lead session "IntuneChocoDeployment CTO" and 11 subagents in `.claude/agents/`. Rules: `RULES.md`. Lead brief: `CTO.md`. Values used for the templates: `vars.json`. Updates come from the dev-team-framework repo (`node setup.mjs <project>`, it never overwrites without `--overwrite`).

## Start
1. Open a terminal in C:\git\IntuneChocolateyDeployment.
2. `claude -n "IntuneChocoDeployment CTO" --model opus` (or in the background: `claude --bg -n "IntuneChocoDeployment CTO" --model opus --permission-mode auto "<start order>"`).
3. Start order: "You are IntuneChocoDeployment CTO. Read `.claude/team/README.md`, `CTO.md`, the memory and the open issues. Report the state to me briefly. Start agents only for open work that is already ordered. No release and no upload without me."

## On another device
Needs Claude Code, `gh auth login`, Node, git. Clone the repo to C:\git\IntuneChocolateyDeployment, copy `.claude/team/memory/*.md` into the memory folder of the project (`~/.claude/projects/<project path with separators as dashes>/memory/`), start as above. No secrets live in git; the vault gives them out with the user's approval.

## Improving the team
General improvements to roles or rules go back to the dev-team-framework repo; project details stay here.
