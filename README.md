<h1 align="center">🚪 Gatecraft</h1>

<p align="center">
  <em>Multi-agent orchestration where "done" is never evidence.</em>
</p>

<p align="center">
  <img alt="type: Claude Code skill" src="https://img.shields.io/badge/type-Claude%20Code%20skill-8A63D2">
  <img alt="state: beads (bd)" src="https://img.shields.io/badge/shared%20state-beads%20(bd)-2D9CDB">
  <img alt="isolation: git worktrees" src="https://img.shields.io/badge/isolation-git%20worktrees-27AE60">
  <img alt="verification: independent re-verify" src="https://img.shields.io/badge/verification-independent%20re--verify-EB5757">
</p>

> **A worker's "done" is not evidence.**
> That single rule runs through the whole skill. Everything else exists to enforce it.

*🇬🇧 English below · 🇮🇹 [Versione italiana più in basso](#-italiano)*

---

## 🇬🇧 English

### What it is

Gatecraft is a [Claude Code](https://claude.com/claude-code) **skill**: a procedural protocol that turns one agent into an **orchestrator** coordinating several independent CLI coding agents (codex, multiple Claude profiles, gemini/AntiGravity, …) against a shared [`bd` (beads)](https://github.com/steveyegge/beads) issue tracker.

Each unit of work runs in its own **isolated git worktree**, passes an **objective, test-based gate defined before dispatch**, and is **independently re-verified by the orchestrator** — diff, gate, and real runtime QA — *before* anything merges or closes. Worker self-reports are treated as signals, never as proof.

It is **portable**: on first use on a new machine or project it runs a bootstrap discovery pass instead of assuming any account names, paths, or roles.

### Why it exists

Hand a backlog to a swarm of agents and the failure mode is always the same: something reports "✅ tests pass, done," gets merged, and turns out to have been verified against the wrong runtime, a stale premise, or nothing at all. This skill is the accumulated set of guardrails — **each one earned from a real, lived incident** (see [`references/anti-patterns.md`](gatecraft/references/anti-patterns.md)) — that stop that from happening while nobody is watching. It has run overnight, unattended, against real multi-epic backlogs — see [`references/changelog.md`](gatecraft/references/changelog.md) for the field-use record.

### Core ideas

| Principle | What it means in practice |
|---|---|
| 🔬 **Verify, don't trust** | The orchestrator re-runs the gate itself, inspects the diff, and does runtime QA. A worker's `bd close` reopens for verification, never short-circuits it. |
| 🎯 **Gate before dispatch** | A concrete, mechanical definition of done (existing test → targeted script → real-runtime check) is written *before* the worker starts — never a prose task description. |
| 🧬 **Isolate, then reconcile** | Every bead gets its own worktree; before merge, main is re-integrated and the gate re-runs on the combined result *and* on main itself. |
| 🔍 **Review ≠ gate** | Behavior gate and security/design review are separate; sensitive paths (auth, payments, secrets, personal data) always get an adversarial reviewer from a *different* profile. |
| 🤝 **Handoff as temporary regency** | On rate-limit exhaustion the orchestrator role is handed off with a durable snapshot and reclaimed later — with a best-effort lock, heartbeat/staleness rules, and ACK windows to avoid two orchestrators acting at once. |
| 🌙 **Safe unattended operation** | Silence is never authorization. Standing policies decided at bootstrap (succession, worker-exhaustion, unattended ceiling, push/deploy) resolve only what the user explicitly delegated. |

### Why Claude Code drives the orchestrator seat

This is a deliberate design decision, not an oversight: **the orchestrator role is Claude Code–specific, while worker roles are vendor-neutral.** You can dispatch beads to codex, Gemini/AntiGravity, or any capable CLI agent as *workers* — but the agent holding the orchestrator seat should be Claude Code.

The reason is concrete and lives in [`references/codex-quota.md`](gatecraft/references/codex-quota.md): the orchestrator's autonomous rate-limit handoff (Step 3) depends on reading its own usage non-interactively. Claude Code's `/usage` is a best-effort but working channel; codex's cleanest equivalent turned out to be its *official experimental* `codex app-server --stdio` JSON-RPC interface (`account/rateLimits/read`) — cleaner than expected, but still a different, less battle-tested path than `/usage`. The same seat also leans on Claude Code mechanisms for self-identification (`CLAUDE_CONFIG_DIR`) and skill auto-loading.

### Repository layout

```
gatecraft/                       # the installable unit — copy this whole folder
├─ SKILL.md                      # the core protocol (Steps 0–4)
└─ references/
   ├─ dispatch-template.md       # the fill-every-field worker prompt
   ├─ anti-patterns.md           # lived failures → the rules that prevent them
   ├─ changelog.md               # dated record of every substantive revision
   ├─ handoff-protocol.md        # Step 3 mechanics: lock, watchdogs, verification ledger
   ├─ codex-quota.md             # non-interactive usage-channel investigation (both vendors)
   ├─ dashboard.md               # recommended dashboard tool + multi-source incident detail
   └─ wordpress.md               # WordPress env checklist + Windows sandbox incident
INSTALL.md                       # single- and multi-profile install instructions
```

### Install (short version)

Copy the **whole `gatecraft/` folder** (not just `SKILL.md`) into either:

- `~/.claude/skills/` — available in every project on the machine, or
- `<repo>/.claude/skills/` — committed for everyone who clones the repo.

Restart open sessions. No alias, no second file to install — the folder name *is* the command.

👉 Full instructions, including the multi-profile junction setup, are in **[INSTALL.md](INSTALL.md)**.

### Use it

Invoke `/gatecraft`, or just ask in plain language — *"orchestrate this with multi-cli", "dispatch to codex/claude/antigravity"*. The first run walks through **Step 0 (bootstrap)**: it checks/installs `bd`, discovers the profiles actually present, smoke-tests write capability, and asks you to set the standing autonomy, succession, and push policies before any bead is dispatched.

### Requirements

- a git repository
- at least one installed CLI coding agent
- a real shell (Claude Code CLI or its VS Code extension, or an equivalent shell-capable environment)

`bd` and the multi-CLI profile tooling are **not** required in advance — Step 0 detects them and asks before installing anything.

### License

[PolyForm Shield 1.0.0](https://polyformproject.org/licenses/shield/1.0.0) — free to use, modify, and distribute for virtually any purpose, *except* building or running a product that competes with this project or with the licensor's own offerings. See [LICENSE](LICENSE) for the full terms.

If this is useful to you, a mention or link back is appreciated but never required.

---

## 🇮🇹 Italiano

### Cos'è

Gatecraft è una **skill** per [Claude Code](https://claude.com/claude-code): un protocollo procedurale che trasforma un agente in un **orchestratore** che coordina più agenti CLI di coding indipendenti (codex, più profili Claude, gemini/AntiGravity, …) su un tracker di issue condiviso, [`bd` (beads)](https://github.com/steveyegge/beads).

Ogni unità di lavoro gira in un **git worktree isolato**, supera un **gate oggettivo basato su test definito *prima* del dispatch**, e viene **verificata in modo indipendente dall'orchestratore** — diff, gate e QA runtime reale — *prima* di ogni merge o chiusura. Il "fatto" dichiarato dal worker è un segnale, mai una prova.

È **portabile**: alla prima esecuzione su una nuova macchina o progetto esegue una fase di discovery (bootstrap) invece di assumere nomi di account, path o ruoli.

### Perché esiste

Se affidi un backlog a uno sciame di agenti, il modo di fallire è sempre lo stesso: qualcosa dichiara "✅ test passati, fatto", viene mergiato, e si scopre che era stato verificato contro il runtime sbagliato, una premessa stantìa, o nulla. Questa skill è l'insieme accumulato di paracadute — **ognuno nato da un incidente reale e vissuto** (vedi [`references/anti-patterns.md`](gatecraft/references/anti-patterns.md)) — che impediscono che accada mentre nessuno guarda. È stata usata di notte, senza supervisione, su backlog multi-epic reali — vedi [`references/changelog.md`](gatecraft/references/changelog.md) per la cronologia d'uso sul campo.

### Idee portanti

| Principio | Cosa significa in pratica |
|---|---|
| 🔬 **Verifica, non fidarti** | L'orchestratore ri-esegue il gate di persona, ispeziona il diff e fa QA runtime. Un `bd close` del worker riapre per verifica, non la scavalca. |
| 🎯 **Gate prima del dispatch** | Una definizione di "fatto" concreta e meccanica (test esistente → script mirato → check runtime reale) è scritta *prima* che il worker parta — mai una descrizione a parole. |
| 🧬 **Isola, poi riconcilia** | Ogni bead ha il suo worktree; prima del merge, main viene reintegrato e il gate rigira sul risultato combinato *e* su main stesso. |
| 🔍 **Review ≠ gate** | Gate comportamentale e review di sicurezza/design sono distinti; i path sensibili (auth, pagamenti, segreti, dati personali) ricevono sempre un reviewer avversariale da un profilo *diverso*. |
| 🤝 **Handoff come reggenza temporanea** | All'esaurimento del rate-limit il ruolo di orchestratore passa con uno snapshot durevole e viene riottenuto dopo — con lock best-effort, regole di heartbeat/staleness e finestre di ACK per evitare due orchestratori attivi insieme. |
| 🌙 **Operatività unattended sicura** | Il silenzio non è mai autorizzazione. Le policy decise al bootstrap (successione, esaurimento worker, tetto unattended, push/deploy) risolvono solo ciò che l'utente ha esplicitamente delegato. |

### Perché è Claude Code a occupare la sedia dell'orchestratore

È una scelta di design deliberata, non una svista: **il ruolo di orchestratore è specifico di Claude Code, mentre i ruoli di worker sono neutri rispetto al vendor.** Puoi dispatchare bead a codex, Gemini/AntiGravity o qualunque CLI agent capace come *worker* — ma l'agente che occupa la sedia dell'orchestratore dovrebbe essere Claude Code.

Il motivo è concreto ed è documentato in [`references/codex-quota.md`](gatecraft/references/codex-quota.md): l'handoff autonomo da rate-limit dell'orchestratore (Step 3) dipende dal leggere il proprio consumo in modo non-interattivo. Il `/usage` di Claude Code è un canale best-effort ma funzionante; l'equivalente più pulito su codex si è rivelato essere la sua interfaccia *ufficiale sperimentale* `codex app-server --stdio` via JSON-RPC (`account/rateLimits/read`) — più pulita del previsto, ma comunque un percorso diverso e meno collaudato di `/usage`. La stessa sedia si appoggia inoltre a meccanismi di Claude Code per l'auto-identificazione (`CLAUDE_CONFIG_DIR`) e l'auto-caricamento delle skill.

### Struttura del repository

```
gatecraft/                       # l'unità installabile — copia l'intera cartella
├─ SKILL.md                      # il protocollo core (Step 0–4)
└─ references/
   ├─ dispatch-template.md       # il prompt worker con ogni campo da compilare
   ├─ anti-patterns.md           # fallimenti vissuti → le regole che li prevengono
   ├─ changelog.md               # registro datato di ogni revisione sostanziale
   ├─ handoff-protocol.md        # meccanica dello Step 3: lock, watchdog, ledger di verifica
   ├─ codex-quota.md             # indagine sui canali di uso non-interattivo (entrambi i vendor)
   ├─ dashboard.md               # tool dashboard consigliato + dettaglio incidente multi-sorgente
   └─ wordpress.md               # checklist ambiente WordPress + incidente sandbox Windows
INSTALL.md                       # istruzioni di installazione mono e multi-profilo
```

### Installazione (versione breve)

Copia **l'intera cartella `gatecraft/`** (non solo `SKILL.md`) in:

- `~/.claude/skills/` — disponibile in ogni progetto della macchina, oppure
- `<repo>/.claude/skills/` — committata per chiunque cloni il repo.

Riavvia le sessioni aperte. Nessun alias, nessun secondo file da installare — il nome della cartella *è* il comando.

👉 Istruzioni complete, incluso il setup con junction per il multi-profilo, in **[INSTALL.md](INSTALL.md)**.

### Come si usa

Invoca `/gatecraft`, oppure chiedi in linguaggio naturale — *"orchestrate this with multi-cli", "dispatch to codex/claude/antigravity"*. La prima esecuzione attraversa lo **Step 0 (bootstrap)**: controlla/installa `bd`, scopre i profili realmente presenti, fa uno smoke-test di scrittura e ti chiede di fissare le policy permanenti di autonomia, successione e push prima che venga dispatchato qualsiasi bead.

### Requisiti

- un repository git
- almeno un CLI coding agent installato
- una shell reale (Claude Code CLI o la sua estensione VS Code, o un ambiente equivalente con shell)

`bd` e il tooling multi-CLI **non** servono in anticipo — lo Step 0 li rileva e chiede prima di installare qualsiasi cosa.

### Licenza

[PolyForm Shield 1.0.0](https://polyformproject.org/licenses/shield/1.0.0) — libero da usare, modificare e distribuire per praticamente qualsiasi scopo, *tranne* costruire o gestire un prodotto in concorrenza con questo progetto o con le offerte commerciali del licenziante. Vedi [LICENSE](LICENSE) per il testo completo.

Se questo progetto ti è utile, una menzione o un link sono apprezzati ma mai obbligatori.

---

<p align="center"><sub>Built the way it recommends working: every rule here was earned from a real incident, not added out of abstract caution.</sub></p>
