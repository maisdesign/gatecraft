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
| --- | --- |
| 🔬 **Verify, don't trust** | The orchestrator re-runs the gate itself, inspects the diff, and does runtime QA. A worker's `bd close` reopens for verification, never short-circuits it. |
| 🎯 **Gate before dispatch** | A concrete, mechanical definition of done (existing test → targeted script → real-runtime check) is written *before* the worker starts — never a prose task description. |
| 🧬 **Isolate, then reconcile** | Every bead gets its own worktree; before merge, main is re-integrated and the gate re-runs on the combined result *and* on main itself. |
| 🔍 **Review ≠ gate** | Behavior gate and security/design review are separate; sensitive paths (auth, payments, secrets, personal data) always get an adversarial reviewer from a *different* profile. |
| 🤝 **Handoff as temporary regency** | On rate-limit exhaustion the orchestrator role is handed off with a durable snapshot and reclaimed later — with a cooperative same-host Git-common-dir guard, durable best-effort lock, heartbeat/staleness rules, and ACK windows. |
| 🌙 **Safe unattended operation** | Silence is never authorization. Standing policies decided at bootstrap (succession, worker-exhaustion, unattended ceiling, push/deploy) resolve only what the user explicitly delegated. |

### Orchestrator seat compatibility

Claude Code is the most field-tested orchestrator seat, not a categorical requirement. Codex also has a verified official-experimental structured quota adapter through codex app-server --stdio and account/rateLimits/read; its path is cleaner than a TUI scrape but has less field history. Worker roles remain vendor-neutral.

Require every orchestrator candidate, regardless of vendor, to pass bootstrap smoke tests for self-identification, usage introspection, non-interactive launch, ACK/lock acquisition, and process-tree reap. Treat skill auto-loading and profile discovery as capabilities to supply through the candidate's own environment; reject automatic succession for a seat that fails any required smoke test. See [references/codex-quota.md](gatecraft/references/codex-quota.md) for the Claude and Codex adapters.

### Repository layout

~~~text
gatecraft/                       # the installable unit — copy this whole folder
├─ SKILL.md                      # core protocol, inline safety invariants, contract routing
├─ references/
│  ├─ execution-contract.md      # normative GC-0.0…GC-1.12 records
│  ├─ local-guard.md             # cooperative local lock + foreign-change baseline/sweep
│  ├─ cycle-end.md               # receipt-first cycle-end event and recovery contract
│  ├─ receipt-protocol.md        # verification/v2 receipts, hashing, review, retry rules
│  ├─ recovery-protocol.md       # attended external-merge audit; permanently non-qualifying
│  ├─ omniroute.md               # optional session gateway onboarding, policy, and safety rules
│  ├─ evidence-hygiene.md        # raw-local → sanitized durable/public boundary
│  ├─ dispatch-template.md       # the fill-every-field worker prompt
│  ├─ anti-patterns.md           # lived failures → the rules that prevent them
│  ├─ changelog.md               # dated record of every substantive revision
│  ├─ handoff-protocol.md        # Step 3 mechanics: lock, watchdogs, verification ledger
│  ├─ codex-quota.md             # copyable PowerShell usage adapters
│  ├─ dashboard.md               # recommended dashboard tool + incident detail
│  └─ wordpress.md               # WordPress env checklist + Windows sandbox incident
├─ scripts/
│  ├─ Gatecraft.Protocol.psm1    # deterministic parser, validator, hasher, sanitizer, retry state
│  ├─ OmniRoute.psm1             # preference, discovery, readiness, start, and install-consent helpers
│  ├─ omniroute-session.ps1       # JSON runtime entry point invoked by per-session GC-0.2
│  ├─ omniroute-process-host.ps1  # bounded/redacted source startup and build process host
│  ├─ guard.ps1 / guard.sh       # PowerShell 7 + POSIX/Git-Bash local guard entry points
│  ├─ cycle-end.ps1              # PowerShell 7 receipt-first cycle-end entry point
│  └─ cycle-end.sh               # POSIX/Git-Bash argument-preserving entry point
└─ tests/
   ├─ Test-Guard.ps1             # concurrency, foreign-change, process, path, shell-parity gate
   ├─ Test-CycleEnd.ps1          # idempotency, conflict, kill/replay, and shell-parity gate
   ├─ Test-ReceiptProtocol.ps1   # real-module verification/review/retry behavioral gate
   ├─ Test-RecoveryProtocol.ps1  # attended audit and non-qualification behavioral gate
   ├─ Test-OmniRoute.ps1         # optional-gateway policy, discovery, and consent gate
   ├─ Test-All.ps1               # fail-fast integrated runner for every Gatecraft gate
   └─ Test-ProtocolContract.ps1  # dependency-free protocol acceptance gate
INSTALL.md                       # single- and multi-profile install instructions
~~~

### Install (short version)

Copy the **whole `gatecraft/` folder** (not just `SKILL.md`) into either:

- `~/.claude/skills/` — available in every project on the machine, or
- `<repo>/.claude/skills/` — committed for everyone who clones the repo.

Restart open sessions. No alias, no second file to install — the folder name *is* the command.

👉 Full instructions, including the multi-profile junction setup, are in **[INSTALL.md](INSTALL.md)**.

### Use it

Invoke `/gatecraft`, or just ask in plain language — *"orchestrate this with multi-cli", "dispatch to codex/claude/antigravity"*. The first run walks through **Step 0 (bootstrap)**: it checks/installs `bd`, discovers the profiles actually present, smoke-tests write capability, and asks you to set the standing autonomy, succession, and push policies before any bead is dispatched.

### Optional OmniRoute gateway

At the start of every orchestration session Gatecraft can discover [OmniRoute](https://github.com/diegosouzapw/OmniRoute) and offer it as an optional routing/compression layer. Gatecraft still works normally without it. If OmniRoute is missing, attended onboarding can offer a pinned official npm installation, ask again next time, or remember never to ask. If it is present, the user can enable it for this session, always for the current project, always with Gatecraft, skip it this session, or disable it for the current project.

Gatecraft persists user intent, not an `installed` boolean: actual endpoint/adapter state is rechecked every session. Project choices stay in local Git config, global choices stay in local user configuration, and session choices stay in memory. A typed startup registry covers native CLI, Docker, validated official source checkouts, desktop apps, and user services without persisting arbitrary shell commands. A modified official source checkout is still detected, but can only be started once after direct confirmation and is never stored as standing startup authority. Source mode is preflighted: an unbuilt checkout recommends `dev`, while `start` requires a production build and never silently changes mode. Managed source startup forces and verifies loopback binding and reports bounded sanitized diagnostics; building is a separate hash-bound confirmation. Activation uses bounded readiness checks, does not rewrite ordinary Claude/Codex configuration, and falls back to direct profiles when the optional gateway is unavailable. Review models remain explicit where model identity matters, and protocol fields, exact commands, receipts, and verification evidence are never eligible for compression. See [the OmniRoute integration contract](gatecraft/references/omniroute.md).

### Requirements

- a git repository
- at least one installed CLI coding agent
- a real shell (Claude Code CLI or its VS Code extension, or an equivalent shell-capable environment)
- PowerShell 7 (`pwsh`) and Git; on Windows shell-parity testing uses Git for Windows Bash

`bd` and the multi-CLI profile tooling are **not** required in advance — Step 0 detects them and asks before installing anything. OmniRoute is never required.

### Maintenance

Before committing any change to the skill or its references, maintainers must run all dependency-free protocol gates from the repository root:

```powershell
pwsh -NoProfile -File gatecraft/tests/Test-All.ps1
pwsh -NoProfile -File gatecraft/tests/Test-Guard.ps1
pwsh -NoProfile -File gatecraft/tests/Test-CycleEnd.ps1
pwsh -NoProfile -File gatecraft/tests/Test-ReceiptProtocol.ps1
pwsh -NoProfile -File gatecraft/tests/Test-RecoveryProtocol.ps1
pwsh -NoProfile -File gatecraft/tests/Test-OmniRoute.ps1
pwsh -NoProfile -File gatecraft/tests/Test-ProtocolContract.ps1
git diff --check
git add -- <intended-paths>
git diff --cached --check
```

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
| --- | --- |
| 🔬 **Verifica, non fidarti** | L'orchestratore ri-esegue il gate di persona, ispeziona il diff e fa QA runtime. Un `bd close` del worker riapre per verifica, non la scavalca. |
| 🎯 **Gate prima del dispatch** | Una definizione di "fatto" concreta e meccanica (test esistente → script mirato → check runtime reale) è scritta *prima* che il worker parta — mai una descrizione a parole. |
| 🧬 **Isola, poi riconcilia** | Ogni bead ha il suo worktree; prima del merge, main viene reintegrato e il gate rigira sul risultato combinato *e* su main stesso. |
| 🔍 **Review ≠ gate** | Gate comportamentale e review di sicurezza/design sono distinti; i path sensibili (auth, pagamenti, segreti, dati personali) ricevono sempre un reviewer avversariale da un profilo *diverso*. |
| 🤝 **Handoff come reggenza temporanea** | All'esaurimento del rate-limit il ruolo passa con uno snapshot durevole — usando un guard cooperativo locale sul Git common-dir, il lock durevole best-effort, heartbeat/staleness e finestre di ACK. |
| 🌙 **Operatività unattended sicura** | Il silenzio non è mai autorizzazione. Le policy decise al bootstrap (successione, esaurimento worker, tetto unattended, push/deploy) risolvono solo ciò che l'utente ha esplicitamente delegato. |

### Compatibilità della sedia dell'orchestratore

Claude Code è la sedia di orchestrazione più collaudata sul campo, non un requisito categorico. Anche Codex dispone di un adapter strutturato verificato e ufficiale-sperimentale tramite codex app-server --stdio e account/rateLimits/read; il canale è più pulito di uno scrape della TUI, ma ha meno esperienza sul campo. I ruoli worker restano neutrali rispetto al vendor.

Richiedi a ogni candidato orchestratore, indipendentemente dal vendor, di superare gli smoke test di bootstrap per auto-identificazione, lettura dell'uso, avvio non interattivo, ACK/acquisizione del lock e reap dell'albero dei processi. Tratta auto-caricamento della skill e discovery del profilo come capacità da fornire tramite l'ambiente del candidato; escludi dalla successione automatica una sedia che fallisce un test obbligatorio. Vedi [references/codex-quota.md](gatecraft/references/codex-quota.md) per gli adapter Claude e Codex.

### Struttura del repository

~~~text
gatecraft/                       # l'unità installabile — copia l'intera cartella
├─ SKILL.md                      # protocollo core, invarianti inline, routing al contratto
├─ references/
│  ├─ execution-contract.md      # record normativi GC-0.0…GC-1.12
│  ├─ local-guard.md             # lock locale cooperativo + baseline/sweep delle modifiche estranee
│  ├─ cycle-end.md               # evento cycle-end receipt-first e contratto di ripristino
│  ├─ receipt-protocol.md        # ricevute verification/v2, hash, review e retry
│  ├─ recovery-protocol.md       # audit attended di merge esterni; mai qualificante
│  ├─ omniroute.md               # onboarding, policy e sicurezza del gateway opzionale di sessione
│  ├─ evidence-hygiene.md        # confine raw locale → durevole/pubblico sanitizzato
│  ├─ dispatch-template.md       # prompt worker con ogni campo da compilare
│  ├─ anti-patterns.md           # fallimenti vissuti → regole preventive
│  ├─ changelog.md               # registro datato delle revisioni sostanziali
│  ├─ handoff-protocol.md        # Step 3: lock, watchdog e ledger di verifica
│  ├─ codex-quota.md             # adapter PowerShell copiabili per l'uso
│  ├─ dashboard.md               # dashboard consigliata + dettaglio incidenti
│  └─ wordpress.md               # checklist WordPress + incidente sandbox Windows
├─ scripts/
│  ├─ Gatecraft.Protocol.psm1    # parser, validatore, hash, sanitizzazione e retry deterministici
│  ├─ OmniRoute.psm1             # helper per preferenze, discovery, readiness, avvio e consenso installazione
│  ├─ omniroute-session.ps1       # entry point JSON invocato dal GC-0.2 a ogni sessione
│  ├─ omniroute-process-host.ps1  # process host bounded/sanitizzato per avvio e build sorgente
│  ├─ guard.ps1 / guard.sh       # entry point PowerShell 7 + POSIX/Git-Bash del guard locale
│  ├─ cycle-end.ps1              # entry point receipt-first per PowerShell 7
│  └─ cycle-end.sh               # entry point POSIX/Git-Bash che preserva gli argomenti
└─ tests/
   ├─ Test-Guard.ps1             # gate concorrenza, modifiche estranee, processi, path e parità shell
   ├─ Test-CycleEnd.ps1          # gate idempotenza, conflitti, kill/replay e parità shell
   ├─ Test-ReceiptProtocol.ps1   # gate comportamentale sul modulo reale
   ├─ Test-RecoveryProtocol.ps1  # gate audit attended e non qualificazione
   ├─ Test-OmniRoute.ps1         # gate policy, discovery e consenso del gateway opzionale
   ├─ Test-All.ps1               # runner integrato fail-fast per tutti i gate Gatecraft
   └─ Test-ProtocolContract.ps1  # gate del protocollo senza dipendenze
INSTALL.md                       # istruzioni di installazione mono e multi-profilo
~~~

### Installazione (versione breve)

Copia **l'intera cartella `gatecraft/`** (non solo `SKILL.md`) in:

- `~/.claude/skills/` — disponibile in ogni progetto della macchina, oppure
- `<repo>/.claude/skills/` — committata per chiunque cloni il repo.

Riavvia le sessioni aperte. Nessun alias, nessun secondo file da installare — il nome della cartella *è* il comando.

👉 Istruzioni complete, incluso il setup con junction per il multi-profilo, in **[INSTALL.md](INSTALL.md)**.

### Come si usa

Invoca `/gatecraft`, oppure chiedi in linguaggio naturale — *"orchestrate this with multi-cli", "dispatch to codex/claude/antigravity"*. La prima esecuzione attraversa lo **Step 0 (bootstrap)**: controlla/installa `bd`, scopre i profili realmente presenti, fa uno smoke-test di scrittura e ti chiede di fissare le policy permanenti di autonomia, successione e push prima che venga dispatchato qualsiasi bead.

### Gateway OmniRoute opzionale

All'inizio di ogni sessione di orchestrazione Gatecraft può rilevare [OmniRoute](https://github.com/diegosouzapw/OmniRoute) e proporlo come livello opzionale di routing e compressione. Gatecraft continua a funzionare normalmente senza OmniRoute. Se manca, l'onboarding attended può proporre un'installazione npm ufficiale e vincolata a una versione esatta, chiedere nuovamente alla prossima sessione oppure ricordare di non chiederlo più. Se è presente, l'utente può abilitarlo solo per la sessione, sempre nel progetto corrente, sempre con Gatecraft, saltarlo per la sessione oppure disabilitarlo nel progetto corrente.

Gatecraft persiste l'intenzione dell'utente, non un booleano `installed`: lo stato reale di endpoint e adapter viene ricontrollato a ogni sessione. Le scelte di progetto restano nella configurazione Git locale, quelle globali nella configurazione locale dell'utente e quelle di sessione solo in memoria. Un registro di startup tipizzato copre CLI nativa, Docker, checkout sorgente ufficiali validati, app desktop e servizi utente senza conservare comandi shell arbitrari. Anche un checkout sorgente ufficiale modificato viene rilevato, ma può essere avviato una sola volta dopo conferma diretta e non viene mai salvato come autorità di avvio permanente. La modalità sorgente viene verificata prima dell'avvio: un checkout senza build raccomanda `dev`, mentre `start` richiede una build di produzione e non cambia mai modalità silenziosamente. L'avvio sorgente gestito forza e verifica il binding loopback e restituisce diagnostica limitata e sanitizzata; la build richiede una conferma separata vincolata agli hash. L'attivazione usa readiness check con timeout, non riscrive la configurazione ordinaria di Claude/Codex e torna ai profili diretti quando il gateway opzionale non è disponibile. I modelli di review restano espliciti quando l'identità del modello è rilevante; campi di protocollo, comandi esatti, receipt ed evidenze di verifica non sono mai comprimibili. Vedi [il contratto d'integrazione OmniRoute](gatecraft/references/omniroute.md).

### Requisiti

- un repository git
- almeno un CLI coding agent installato
- una shell reale (Claude Code CLI o la sua estensione VS Code, o un ambiente equivalente con shell)
- PowerShell 7 (`pwsh`) e Git; su Windows il test di parità usa Bash di Git for Windows

`bd` e il tooling multi-CLI **non** servono in anticipo — lo Step 0 li rileva e chiede prima di installare qualsiasi cosa. OmniRoute non è mai obbligatorio.

### Manutenzione

Prima di committare qualsiasi modifica alla skill o ai suoi riferimenti, i maintainer devono eseguire tutti i gate del protocollo senza dipendenze dalla root del repository:

```powershell
pwsh -NoProfile -File gatecraft/tests/Test-All.ps1
pwsh -NoProfile -File gatecraft/tests/Test-Guard.ps1
pwsh -NoProfile -File gatecraft/tests/Test-CycleEnd.ps1
pwsh -NoProfile -File gatecraft/tests/Test-ReceiptProtocol.ps1
pwsh -NoProfile -File gatecraft/tests/Test-RecoveryProtocol.ps1
pwsh -NoProfile -File gatecraft/tests/Test-OmniRoute.ps1
pwsh -NoProfile -File gatecraft/tests/Test-ProtocolContract.ps1
git diff --check
git add -- <percorsi-intenzionali>
git diff --cached --check
```

### Licenza

[PolyForm Shield 1.0.0](https://polyformproject.org/licenses/shield/1.0.0) — libero da usare, modificare e distribuire per praticamente qualsiasi scopo, *tranne* costruire o gestire un prodotto in concorrenza con questo progetto o con le offerte commerciali del licenziante. Vedi [LICENSE](LICENSE) per il testo completo.

Se questo progetto ti è utile, una menzione o un link sono apprezzati ma mai obbligatori.

---

<p align="center"><sub>Built the way it recommends working: every rule here was earned from a real incident, not added out of abstract caution.</sub></p>
