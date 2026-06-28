# Architecture

## The base scheme (portable to any EVM)

### How state is tracked
Rather than a pile of booleans, each challenge carries one `Stage` field. The
"open your entry" period isn't its own stored stage — it's simply the gap
between the seal deadline and the unseal deadline while the stage is still
`Sealing`. A read-only `stageOf` view reports that gap as `Unsealing` so callers
see the right thing without an extra storage write.

### What the chain holds at each moment
- **While sealing:** just the digest
  `keccak256(abi.encode(answer, salt, msg.sender, bountyId))`. The answer string
  is blank.
- **While unsealing:** the cleartext answer plus an `unsealed` flag. Publishing
  it now is harmless — the seal window is shut, so a copycat can no longer enter.
- **After judging:** the jury's raw output, kept around for anyone auditing.

### Where the cleartext answer actually is
- Before opening: nowhere but the entrant's own machine.
- After opening: in the `revealAnswer` calldata, then in contract storage.

### Properties I rely on
- *Concealment* — the random salt stops anyone pre-imaging short answers.
- *Commitment* — you can't swap your answer later; the open has to reproduce the
  stored digest.
- *No stand-ins, no recycling* — the sender address and the challenge id are
  baked into the digest.
- *One slot per wallet* — a 1-based index map both enforces this and gives a
  direct lookup at open time, so there's no array scan.
- *Skipping is allowed* — never open and you're just left out; an unopened entry
  can never be chosen as the winner.

### Who decides what
The AI produces a comparison across the field; the human host makes the binding
choice in `finalizeWinner`, which is also the only moment money leaves the
escrow — and only to a wallet that actually opened a valid entry.

## The Ritual TEE variant (keeping entries encrypted through judging)

Instead of publishing cleartext at the open step, entrants encrypt to the
executor's key and the answers are only ever decrypted inside the enclave.

```
entrant                         on-chain                    enclave (TEE executor)
  encrypt(answer, exec pubkey)
        │ ECIES
        └───────────────▶ ciphertext / digest stored
                                 │
 host → judgeAll(id, llmInput) ──┴──▶ precompile 0x0802 ─▶ decrypt the batch,
                                                           score it, return only
                                                           the verdict
                          verdict ◀──────────────────────┘
 host → finalizeWinner(index)  (reads the verdict, pays out)
```

**Cleartext locations (encrypted variant):**
- entrant's client — before encryption;
- on-chain — ciphertext and/or digest only, never cleartext;
- inside the TEE — briefly, during the one batch inference, then gone;
- leaving the enclave — only the verdict.

**On-chain vs off-chain split:**
- on-chain: challenge metadata, criteria, ciphertext/digest, deadlines, the
  verdict, the chosen winner, the escrowed prize;
- off-chain: the decrypted answers (transient, in-enclave) and any conversation
  history on the DA provider.

**Feeding the model one batch:** `judgeAll` assembles a single `messagesJson`
holding every entry and fires one inference (never one call per entry — that
respects Ritual's single-async-call-per-tx rule and is cheaper). Internally
`_askJury` peels the async envelope `(simInput, actualOutput)`, decodes the
response envelope, and aborts with `JuryFailed(reason)` whenever `hasError` is
set, so a bad jury reply can't quietly corrupt state.

**Ritual parts used:** the LLM precompile `0x0802`, `encryptedSecrets` /
`userPublicKey` for private inputs and outputs, `RitualWallet` to cover the async
fee, and `TEEServiceRegistry` to pick a live LLM executor.

**The trade:** the base scheme is dead simple and fully checkable on any EVM, at
the cost of revealing cleartext after the deadline. The Ritual variant never
reveals it, but leans on TEE attestation and a live executor. The sealed-entry
lifecycle is identical either way — only the jury step changes.
