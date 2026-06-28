# SealedBountyJudge

A bounty arena where answers are locked away as hashes during entry, and can
only be opened (and judged) after the entry window shuts. Built on top of the
`ritual-chain-workshop` starter.

## Why this exists

In the starter's `AIJudge.sol`, an entrant called `submitAnswer` and their text
landed on-chain in the clear. Anyone watching could lift a good answer, polish
it, and out-submit the author. That is the bug. The fix here is a two-phase
"seal then open" design: you commit to a hash first, and your words only appear
once nobody else can still enter.

## The four required calls

```
submitCommitment(uint256 bountyId, bytes32 commitment)
revealAnswer(uint256 bountyId, string answer, bytes32 salt)
judgeAll(uint256 bountyId, bytes llmInput)
finalizeWinner(uint256 bountyId, uint256 winnerIndex)
```

The seal that ties everything together:

```
seal = keccak256(abi.encode(answer, salt, msg.sender, bountyId))
```

I expose the same hash as a public `pure` helper, `sealOf(...)`, so a client can
compute the exact value before sending `submitCommitment`.

## How a challenge flows

The contract tracks a single `Stage` value per challenge instead of juggling
separate flags:

`Sealing` → (`Adjudicated`) → `Settled`

- `openChallenge(brief, criteria, sealWindow, unsealWindow)` — the host escrows a
  prize and sets how long each phase lasts. Both windows are added to the current
  block time.
- `submitCommitment` — stores only the seal. The answer field stays empty. One
  seal per address; refused once the seal window ends.
- `revealAnswer` — opens the entry after the seal window and before the unseal
  window. The contract rebuilds the hash and demands an exact match; mismatches
  revert.
- `judgeAll` — host-only, after unsealing closes, with at least one valid entry.
  Sends every opened answer to the AI jury in one shot and records the verdict.
- `finalizeWinner` — host-only. Picks an opened entry and forwards the prize.

## What each piece of the seal buys you

- **answer** is the thing being promised.
- **salt** is random padding, so a short answer like "yes" can't be guessed by
  replaying hashes.
- **msg.sender** locks the seal to one wallet — you cannot open someone else's.
- **bountyId** scopes the seal to this challenge, so it can't be reused elsewhere.

Every one of these has a failing-case test that proves it.

## Running it

Solidity tests (Foundry, vendored under `hardhat/lib`):

```bash
cd hardhat
forge test -vvv
```

22 tests, and deliberately no mock precompile — the judging tests only assert the
guard conditions that fire before any precompile call. The genuine AI jury call
is exercised against the live chain by the script below, since an async
precompile can't settle inside a local EVM.

## Trying it for real on Ritual

```bash
cd scripts
npm install
cp .env.example .env     # then paste a faucet-funded TESTNET key
npm run whoami
npm run deploy           # → contract address + deploy tx hash
npm run demo             # full seal → open → judge → settle, real LLM
```

Three things that tripped me up and are worth knowing:
- block timestamps on Ritual are milliseconds, so the demo passes its windows in
  ms;
- the async jury fee comes out of the caller's `RitualWallet` balance, not the
  contract's, so the EOA has to deposit first;
- the public RPC occasionally lies about the nonce, so the scripts re-fetch and
  retry on their own.

## Layout

```
hardhat/contracts/SealedBountyJudge.sol   the arena
hardhat/test/SealedBountyJudge.t.sol      22 unit + fuzz tests
scripts/                                  lib, whoami, deploy, arena (demo)
ARCHITECTURE.md                           on/off-chain + TEE write-up
TEST_PLAN.md                              reveal-case coverage
REFLECTION.md                             the reflection question
```
