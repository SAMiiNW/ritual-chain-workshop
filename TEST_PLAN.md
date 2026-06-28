# Test coverage

`forge test -vvv` — 22 tests (21 concrete + 1 fuzz at 256 runs). There is no mock
precompile anywhere: the judging tests stop at the guard checks that run ahead of
any precompile call, and the real jury path is covered on-chain by
`scripts/arena.mjs`.

## Opening an entry correctly (and the ways it can fail)

- `test_Unseal_Valid` — the matching (answer, salt) rebuilds the seal and is accepted.
- `test_Unseal_RevertWrongSalt` — correct answer, wrong salt → `SealMismatch`.
- `test_Unseal_RevertWrongAnswer` — tampered answer, correct salt → `SealMismatch`.
- `test_Unseal_RevertImpersonation` — a wallet that never entered → `NoEntry`.
- `test_Unseal_RevertCrossChallengeReplay` — a seal made for challenge A fails in B → `SealMismatch`.
- `testFuzz_OnlyExactUnsealSucceeds` — random salts that differ always fail.

## Timing of the open

- `test_Unseal_RevertBeforeWindow` — can't open during the seal window (`UnsealNotOpen`).
- `test_Unseal_RevertAfterWindow` — can't open past the unseal deadline (`UnsealClosed`).
- `test_Unseal_RevertDouble` — an entry opens once only (`AlreadyUnsealed`).

## Sealing an entry

- `test_Seal_HidesAnswer` — during sealing the stored answer is empty.
- `test_Seal_RevertDouble` — one entry per wallet (`AlreadyEntered`).
- `test_Seal_RevertEmpty` — a zero seal is refused (`EmptySeal`).
- `test_Seal_RevertAfterDeadline` — no sealing past the deadline (`SealingClosed`).
- `test_Seal_RevertUnknownChallenge` — unknown id (`UnknownChallenge`).

## The jury gate (host-only, batched)

- `test_Judge_RevertNotHost` — only the host can run it (`NotHost`).
- `test_Judge_RevertWhileUnsealOpen` — too early, unsealing still open (`WrongStage`).
- `test_Judge_RevertNoValidEntries` — nothing was opened (`NoValidEntries`).

## Settlement

- `test_Finalize_RevertBeforeJudge` — can't settle before judging (`WrongStage`).
- `test_Finalize_RevertNotHost` — only the host can settle (`NotHost`).

## Opening a challenge

- `test_Open_SetsSealingStage` — fresh challenge starts in `Sealing`.
- `test_Open_RevertNoPrize` — a prize is mandatory (`PrizeMissing`).
- `test_Open_RevertZeroWindow` — windows must be non-zero (`BadWindow`).

## Live proof (real AI jury)

`scripts/arena.mjs` against Ritual Chain walks the whole thing end to end:
deploy, open, seal (answer hidden — stored length 0), open, batch-judge with a
real `0x0802` call (verdict bytes land on-chain), and settle the prize to the
opener.
