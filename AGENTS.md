# Agent Execution Contract

## 1) Mandatory MCP + Skills Policy

- Always use `exa`, `context7`, and `serena` MCP servers for research, docs, and repo-aware retrieval whenever relevant to the task.
- Always discover and apply relevant skills before execution, including skill discovery and learned skill workflows (find skills, learn skills, and all other applicable skills in this environment).
- Prefer skill-backed execution over ad-hoc implementation when a matching skill exists.
- Initial check for skill availability (run once per environment/bootstrap):

```bash
npm install -g agent-browser
agent-browser install
npx skills add vercel-labs/agent-browser
npx skills add vercel-labs/agent-skills
npx skills add https://github.com/vercel-labs/skills --skill find-skills
npx skills add philschmid/self-learning-skill
npx skills add https://github.com/forrestchang/andrej-karpathy-skills --skill karpathy-guidelines
npx skills add https://github.com/anthropics/skills --skill skill-creator
npx skills add https://github.com/gbsoss/skill-from-masters --skill skill-from-github
npx skills add https://github.com/vercel-labs/agent-skills --skill vercel-react-best-practices
npx skills add https://github.com/nextlevelbuilder/ui-ux-pro-max-skill --skill ui-ux-pro-max
npx skills add https://github.com/coreyhaines31/marketingskills --skill seo-audit
npx skills add https://github.com/vercel-labs/agent-skills --skill web-design-guidelines
npx skills add https://github.com/anthropics/skills --skill frontend-design
npx skills add https://github.com/supabase/agent-skills --skill supabase-postgres-best-practices
npx skills add https://github.com/obra/superpowers --skill brainstorming
npx skills add https://github.com/better-auth/skills --skill better-auth-best-practices
```

- For this repository, ensure Serena MCP is available from the current working directory:

```bash
uvx --from git+https://github.com/oraios/serena \
  serena start-mcp-server \
  --transport stdio \
  --enable-web-dashboard false \
  --open-web-dashboard false \
  --enable-gui-log-window false \
  --project .
```

- If your MCP client already launches Serena from config, keep that configuration aligned and do not register QMD as a replacement for Serena in this repository.

## 2) Current Team Orchestration System

Team Orchestration System

> **Unified Multi-Agent Framework** combining claude-sneakpeek + OMO + OMC

---

## Quick Start

```
Spawn the whole team: database expert, back-end senior engineer, front-end senior engineer and tech lead.

## Subagents
- ALWAYS wait for all subagents to complete before yielding.
- Spawn subagents automatically when:
- Parallelizable work (e.g., install + verify, npm test + typecheck, multiple tasks from plan)
- Long-running or blocking tasks where a worker can run independently.
Isolation for risky changes or checks
```

**Team members are defined inside the `.claude/team` directory, in markdown files.**

---

## Magic Keywords

Say these keywords anywhere in your prompt to activate special modes:

| Keyword | Aliases | Effect |
|---------|---------|--------|
| **ultrawork** | `ulw`, `uw` | Parallel execution, background tasks, strict TODO tracking |
| **ralph** | `don't stop`, `must complete`, `until done` | Self-loop until task verified complete |
| **autopilot** | `autonomous`, `full auto`, `fullsend` | Full autonomous mode - minimal intervention |
| **ultrapilot** | `parallel build`, `swarm build` | Parallel swarm build mode |
| **swarm** | `swarm N agents`, `coordinated agents` | Launch N coordinated agents |
| **pipeline** | `chain agents` | Sequential agent chain |
| **ecomode** | `eco`, `efficient`, `budget` | Token-efficient mode |
| **plan** | `plan this`, `plan the` | Planning mode before execution |
| **ralplan** | - | Ralph + planning combined |
| **tdd** | `test first`, `red green` | Test-driven development |
| **research** | `analyze data`, `statistics` | Research/analysis mode |
| **ultrathink** | `think hard`, `think deeply` | Extended reasoning mode |
| **deepsearch** | `search codebase`, `find in code` | Deep codebase search |
| **analyze** | `deep analyze`, `investigate`, `debug` | Deep analysis/debugging |
| **cancel** | `stop`, `abort` | Stop current operation |

### Phrase Triggers (activate autopilot)
- "build me a..." / "create me a..." / "make me a..."
- "I want a..." / "I want an..."
- "handle it all" / "end to end" / "e2e this"

---

## Spawn Commands

### Single Agent
```
Spawn the backend engineer
Spawn architect to review this design
```

### Multiple Agents
```
Spawn the whole team: database expert, back-end senior engineer, front-end senior engineer
Spawn: architect, executor, qa-tester
```

### Swarm Mode
```
swarm 4 agents to implement the authentication feature
ultrapilot: build the entire API
```

### With Model Tier
```
Spawn architect-high for complex system design
Spawn explore-low for quick file search
```

---

## Team Directory

All team member expertise files are in `.claude/team/`:

### Core Team
| File | Role | Model |
|------|------|-------|
| `tech-lead.md` | Team coordination, decisions | OPUS |
| `architect.md` | System design, architecture | OPUS |
| `backend.md` | Backend/API development | SONNET |
| `frontend.md` | Frontend/UI development | SONNET |
| `db-expert.md` | Database design, queries | SONNET |

### Specialists
| File | Role | Model |
|------|------|-------|
| `executor.md` | Task implementation | SONNET |
| `researcher.md` | Documentation research | HAIKU |
| `explore.md` | Fast codebase search | HAIKU |
| `designer.md` | UI/UX design | SONNET |
| `writer.md` | Technical documentation | HAIKU |
| `vision.md` | Image/screenshot analysis | SONNET |
| `critic.md` | Critical review | OPUS |
| `analyst.md` | Requirements analysis | OPUS |
| `planner.md` | Strategic planning | OPUS |
| `qa-tester.md` | Testing, quality assurance | SONNET |
| `scientist.md` | Data analysis, experiments | OPUS |

### Model Tiers
- **`-low`** suffix → HAIKU (fast, cheap, simple tasks)
- **`-medium`** suffix → SONNET (balanced)
- **`-high`** suffix → OPUS (complex reasoning)

Example: `architect-low.md`, `executor-high.md`

---

## Working Modes

### Ultrawork Mode (`ulw`)

Activated by: `ultrawork`, `ulw`, `uw`

**Rules:**
1. **PARALLEL** - Fire independent calls simultaneously, NEVER wait sequentially
2. **BACKGROUND FIRST** - Use `Task(run_in_background=true)` for exploration (10+ concurrent)
3. **TODO** - Track EVERY step, mark complete IMMEDIATELY after each
4. **VERIFY** - Check ALL requirements met before declaring done
5. **NO PREMATURE STOP** - ALL TODOs must be complete

**State persisted at:** `.omc/state/ultrawork-state.json`

### Ralph Loop Mode

Activated by: `ralph`, `don't stop`, `must complete`, `until done`

**Behavior:**
- Self-referential work loop
- Continues until completion verified
- Outputs `<promise>TASK COMPLETE</promise>` when truly done
- Tracks iteration count
- Can combine with ultrawork: `ralph ultrawork`

### Autopilot Mode

Activated by: `autopilot`, `autonomous`, `fullsend`

**Behavior:**
- Minimal user intervention
- Makes decisions autonomously
- Completes entire task end-to-end
- Only asks for critical clarifications

### Swarm Mode

Activated by: `swarm N agents`, `coordinated agents`

**Behavior:**
- Spawns N parallel agents
- Each agent works on subtask
- Coordination via communication channel
- No task overlaps - stays in sync

---

## Team Communication

### How It Works
1. **Team Lead** always spawned first - coordinates others
2. Each teammate has **own inbox** (send/receive messages)
3. **Communication channel** keeps everyone in sync
4. **No task overlaps** - work is distributed cleanly

### Message Types
- `task` - Assign work to teammate
- `result` - Report completed work
- `status` - Progress update
- `plan` - Proposed plan for approval
- `approval` - Vote on plans

### Mailbox Location
```
.claude/teams/{team-name}/mailbox/{teammate}.json
```

---

## Agent Expertise Format

Each `.claude/team/{role}.md` file contains:

```markdown
# {Role Name}

## Identity
You are the {Role} on this team.

## Expertise
- Skill 1
- Skill 2
- ...

## Model Tier
HAIKU | SONNET | OPUS

## Allowed Tools
Edit, Write, Read, Bash, Glob, Grep, ...

## Working Style
- How this agent approaches tasks
- Communication preferences
- Quality standards
```

---

## Quick Reference

| Want to... | Say... |
|------------|--------|
| Spawn full team | "Spawn the whole team: X, Y, Z" |
| Work until done | "ralph: implement feature X" |
| Parallel execution | "ultrawork: build the API" |
| Autonomous mode | "autopilot: create login system" |
| Multi-agent swarm | "swarm 4 agents: refactor codebase" |
| Quick search | "Spawn explore-low to find auth files" |
| Complex design | "Spawn architect-high for system design" |
| Token-efficient | "ecomode: fix this bug" |
| Test-driven | "tdd: implement user service" |

---

## File Structure

```
.claude/
├── team/                    # Agent expertise files
│   ├── architect.md
│   ├── backend.md
│   ├── frontend.md
│   ├── db-expert.md
│   ├── tech-lead.md
│   ├── executor.md
│   ├── ... (32 total)
│   └── plan.md              # Implementation plan
│
├── teams/                   # Active team sessions
│   └── {team-name}/
│       ├── config.json
│       ├── state.json
│       └── mailbox/
│
└── settings.local.json
```

---

## Examples

### Example 1: Build a Feature
```
ralph ultrawork: Build user authentication with JWT, including login, register, 
password reset, and email verification. Spawn backend and db-expert.
```

### Example 2: Review and Refactor
```
Spawn the whole team: architect, critic, qa-tester
Review the payment module for security issues and refactor for better performance.
```

### Example 3: Quick Exploration
```
Spawn explore-low to find all API endpoints in the codebase
```

### Example 4: Full Autonomous Build
```
autopilot: Build me a REST API for a todo app with PostgreSQL, 
including CRUD operations, user auth, and tests.
```

---

*Team members defined in `.claude/team/` • Magic keywords activate special modes • Ralph loops until done*

---

## 3) AI Coding Agent Guidelines (claude.md)

These rules define how an AI coding agent should plan, execute, verify, communicate, and recover when working in a real codebase. Optimize for correctness, minimalism, and developer experience.

---

## Operating Principles (Non-Negotiable)

- **Correctness over cleverness**: Prefer boring, readable solutions that are easy to maintain.
- **Smallest change that works**: Minimize blast radius; don't refactor adjacent code unless it meaningfully reduces risk or complexity.
- **Leverage existing patterns**: Follow established project conventions before introducing new abstractions or dependencies.
- **Prove it works**: "Seems right" is not done. Validate with tests/build/lint and/or a reliable manual repro.
- **Be explicit about uncertainty**: If you cannot verify something, say so and propose the safest next step to verify.

---

## Workflow Orchestration

### 1. Plan Mode Default
- Enter plan mode for any non-trivial task (3+ steps, multi-file change, architectural decision, production-impacting behavior).
- Include verification steps in the plan (not as an afterthought).
- If new information invalidates the plan: **stop**, update the plan, then continue.
- Write a crisp spec first when requirements are ambiguous (inputs/outputs, edge cases, success criteria).

### 2. Subagent Strategy (Parallelize Intelligently)
- Use subagents to keep the main context clean and to parallelize:
  - repo exploration, pattern discovery, test failure triage, dependency research, risk review.
- Give each subagent **one focused objective** and a concrete deliverable:
  - "Find where X is implemented and list files + key functions" beats "look around."
- Merge subagent outputs into a short, actionable synthesis before coding.

### 3. Incremental Delivery (Reduce Risk)
- Prefer **thin vertical slices** over big-bang changes.
- Land work in small, verifiable increments:
  - implement → test → verify → then expand.
- When feasible, keep changes behind:
  - feature flags, config switches, or safe defaults.

### 4. Self-Improvement Loop
- After any user correction or a discovered mistake:
  - add a new entry to `tasks/lessons.md` capturing:
    - the failure mode, the detection signal, and a prevention rule.
- Review `tasks/lessons.md` at session start and before major refactors.

### 5. Verification Before "Done"
- Never mark complete without evidence:
  - tests, lint/typecheck, build, logs, or a deterministic manual repro.
- Compare behavior baseline vs changed behavior when relevant.
- Ask: "Would a staff engineer approve this diff and the verification story?"

### 6. Demand Elegance (Balanced)
- For non-trivial changes, pause and ask:
  - "Is there a simpler structure with fewer moving parts?"
- If the fix is hacky, rewrite it the elegant way **if** it does not expand scope materially.
- Do not over-engineer simple fixes; keep momentum and clarity.

### 7. Autonomous Bug Fixing (With Guardrails)
- When given a bug report:
  - reproduce → isolate root cause → fix → add regression coverage → verify.
- Do not offload debugging work to the user unless truly blocked.
- If blocked, ask for **one** missing detail with a recommended default and explain what changes based on the answer.

---

## Task Management (File-Based, Auditable)

1. **Plan First**
   - Write a checklist to `tasks/todo.md` for any non-trivial work.
   - Include "Verify" tasks explicitly (lint/tests/build/manual checks).
2. **Define Success**
   - Add acceptance criteria (what must be true when done).
3. **Track Progress**
   - Mark items complete as you go; keep one "in progress" item at a time.
4. **Checkpoint Notes**
   - Capture discoveries, decisions, and constraints as you learn them.
5. **Document Results**
   - Add a short "Results" section: what changed, where, how verified.
6. **Capture Lessons**
   - Update `tasks/lessons.md` after corrections or postmortems.

---

## Communication Guidelines (User-Facing)

### 1. Be Concise, High-Signal
- Lead with outcome and impact, not process.
- Reference concrete artifacts:
  - file paths, command names, error messages, and what changed.
- Avoid dumping large logs; summarize and point to where evidence lives.

### 2. Ask Questions Only When Blocked
When you must ask:
- Ask **exactly one** targeted question.
- Provide a recommended default.
- State what would change depending on the answer.

### 3. State Assumptions and Constraints
- If you inferred requirements, list them briefly.
- If you could not run verification, say why and how to verify.

### 4. Show the Verification Story
- Always include:
  - what you ran (tests/lint/build), and the outcome.
- If you didn't run something, give a minimal command list the user can run.

### 5. Avoid "Busywork Updates"
- Don't narrate every step.
- Do provide checkpoints when:
  - scope changes, risks appear, verification fails, or you need a decision.

---

## Context Management Strategies (Don't Drown the Session)

### 1. Read Before Write
- Before editing:
  - locate the authoritative source of truth (existing module/pattern/tests).
- Prefer small, local reads (targeted files) over scanning the whole repo.

### 2. Keep a Working Memory
- Maintain a short running "Working Notes" section in `tasks/todo.md`:
  - key constraints, invariants, decisions, and discovered pitfalls.
- When context gets large:
  - compress into a brief summary and discard raw noise.

### 3. Minimize Cognitive Load in Code
- Prefer explicit names and direct control flow.
- Avoid clever meta-programming unless the project already uses it.
- Leave code easier to read than you found it.

### 4. Control Scope Creep
- If a change reveals deeper issues:
  - fix only what is necessary for correctness/safety.
  - log follow-ups as TODOs/issues rather than expanding the current task.

---

## Error Handling and Recovery Patterns

### 1. "Stop-the-Line" Rule
If anything unexpected happens (test failures, build errors, behavior regressions):
- stop adding features
- preserve evidence (error output, repro steps)
- return to diagnosis and re-plan

### 2. Triage Checklist (Use in Order)
1. **Reproduce** reliably (test, script, or minimal steps).
2. **Localize** the failure (which layer: UI, API, DB, network, build tooling).
3. **Reduce** to a minimal failing case (smaller input, fewer steps).
4. **Fix** root cause (not symptoms).
5. **Guard** with regression coverage (test or invariant checks).
6. **Verify** end-to-end for the original report.

### 3. Safe Fallbacks (When Under Time Pressure)
- Prefer "safe default + warning" over partial behavior.
- Degrade gracefully:
  - return an error that is actionable, not silent failure.
- Avoid broad refactors as "fixes."

### 4. Rollback Strategy (When Risk Is High)
- Keep changes reversible:
  - feature flag, config gating, or isolated commits.
- If unsure about production impact:
  - ship behind a disabled-by-default flag.

### 5. Instrumentation as a Tool (Not a Crutch)
- Add logging/metrics only when they:
  - materially reduce debugging time, or prevent recurrence.
- Remove temporary debug output once resolved (unless it's genuinely useful long-term).

---

## Engineering Best Practices (AI Agent Edition)

### 1. API / Interface Discipline
- Design boundaries around stable interfaces:
  - functions, modules, components, route handlers.
- Prefer adding optional parameters over duplicating code paths.
- Keep error semantics consistent (throw vs return error vs empty result).

### 2. Testing Strategy
- Add the smallest test that would have caught the bug.
- Prefer:
  - unit tests for pure logic,
  - integration tests for DB/network boundaries,
  - E2E only for critical user flows.
- Avoid brittle tests tied to incidental implementation details.

### 3. Type Safety and Invariants
- Avoid suppressions (`any`, ignores) unless the project explicitly permits and you have no alternative.
- Encode invariants where they belong:
  - validation at boundaries, not scattered checks.

### 4. Dependency Discipline
- Do not add new dependencies unless:
  - the existing stack cannot solve it cleanly, and the benefit is clear.
- Prefer standard library / existing utilities.

### 5. Security and Privacy
- Never introduce secret material into code, logs, or chat output.
- Treat user input as untrusted:
  - validate, sanitize, and constrain.
- Prefer least privilege (especially for DB access and server-side actions).

### 6. Performance (Pragmatic)
- Avoid premature optimization.
- Do fix:
  - obvious N+1 patterns, accidental unbounded loops, repeated heavy computation.
- Measure when in doubt; don't guess.

### 7. Accessibility and UX (When UI Changes)
- Keyboard navigation, focus management, readable contrast, and meaningful empty/error states.
- Prefer clear copy and predictable interactions over fancy effects.

---

## Git and Change Hygiene (If Applicable)

- Keep commits atomic and describable; avoid "misc fixes" bundles.
- Don't rewrite history unless explicitly requested.
- Don't mix formatting-only changes with behavioral changes unless the repo standard requires it.
- Treat generated files carefully:
  - only commit them if the project expects it.

---

## Definition of Done (DoD)

A task is done when:
- Behavior matches acceptance criteria.
- Tests/lint/typecheck/build (as relevant) pass or you have a documented reason they were not run.
- Risky changes have a rollback/flag strategy (when applicable).
- The code follows existing conventions and is readable.
- A short verification story exists: "what changed + how we know it works."

---

## Templates

### Plan Template (Paste into `tasks/todo.md`)
- [ ] Restate goal + acceptance criteria
- [ ] Locate existing implementation / patterns
- [ ] Design: minimal approach + key decisions
- [ ] Implement smallest safe slice
- [ ] Add/adjust tests
- [ ] Run verification (lint/tests/build/manual repro)
- [ ] Summarize changes + verification story
- [ ] Record lessons (if any)

### Bugfix Template (Use for Reports)
- Repro steps:
- Expected vs actual:
- Root cause:
- Fix:
- Regression coverage:
- Verification performed:
- Risk/rollback notes:
