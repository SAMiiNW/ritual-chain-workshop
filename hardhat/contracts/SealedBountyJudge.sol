// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

/// @title SealedBountyJudge
/// @author bounty entrant (v2)
/// @notice A sealed-entry bounty arena. Entrants first lock in a sealed hash of
///         their answer (commit), and only after the entry window closes do they
///         unseal it (reveal). The arena verifies the seal binds the answer to a
///         salt, the entrant, and the challenge id. Only unsealed-and-valid
///         entries reach the AI jury.
///
/// @dev    Design choices that make this implementation distinct:
///         - explicit `Stage` state machine instead of scattered booleans;
///         - custom errors instead of revert strings;
///         - O(1) entrant lookup via a 1-based index map (no array scan);
///         - the AI jury call lives directly inside `judgeAll` and talks to the
///           LLM precompile; tests stub it with `vm.etch`.
///         Chain-agnostic for the commit/unseal logic; the jury call targets the
///         Ritual LLM precompile (0x0802) on Ritual Chain.
contract SealedBountyJudge {
    // ───────────────────────────────── config ─────────────────────────────

    uint256 private constant ANSWER_CHAR_CAP = 8_192;
    uint256 private constant ENTRANT_CAP = 128;
    address private constant LLM_JURY = address(0x0802);

    // ───────────────────────────────── model ──────────────────────────────

    enum Stage {
        Sealing, // accepting sealed entries
        Unsealing, // entry window closed, accepting unseals
        Adjudicated, // jury ran, awaiting host's final pick
        Settled // prize paid
    }

    struct Entry {
        address entrant;
        bytes32 seal; // keccak256(answer, salt, entrant, challengeId)
        bool unsealed;
        string answer; // populated only after a valid unseal
    }

    struct Challenge {
        address host;
        string brief;
        string criteria;
        uint256 prize;
        uint64 sealDeadline; // sealed entries accepted strictly before this
        uint64 unsealDeadline; // unseals accepted strictly before this
        Stage stage;
        uint256 pickedEntry; // index of the host-picked winner
        bytes juryVerdict; // raw AI output retained for audit
        uint256 entryCount;
    }

    // ──────────────────────────────── storage ─────────────────────────────

    uint256 private _challengeSeq;

    mapping(uint256 => Challenge) private _challenges;
    // challengeId => entry index => Entry
    mapping(uint256 => mapping(uint256 => Entry)) private _entries;
    // challengeId => entrant => (index + 1); 0 means "no entry"
    mapping(uint256 => mapping(address => uint256)) private _slotOf;

    // ──────────────────────────────── errors ──────────────────────────────

    error UnknownChallenge();
    error NotHost();
    error PrizeMissing();
    error BadWindow();
    error SealingClosed();
    error AlreadyEntered();
    error ArenaFull();
    error EmptySeal();
    error UnsealNotOpen();
    error UnsealClosed();
    error NoEntry();
    error AlreadyUnsealed();
    error AnswerTooLong();
    error SealMismatch();
    error WrongStage();
    error NoValidEntries();
    error PickNotUnsealed();
    error BadIndex();
    error PayoutFailed();
    error JuryFailed(string reason);

    // ──────────────────────────────── events ──────────────────────────────

    event ChallengeOpened(
        uint256 indexed challengeId,
        address indexed host,
        uint256 prize,
        uint64 sealDeadline,
        uint64 unsealDeadline
    );
    event EntrySealed(
        uint256 indexed challengeId,
        uint256 indexed slot,
        address indexed entrant
    );
    event EntryUnsealed(
        uint256 indexed challengeId,
        uint256 indexed slot,
        address indexed entrant
    );
    event JuryRuled(uint256 indexed challengeId, uint256 validEntries, bytes verdict);
    event PrizeSettled(
        uint256 indexed challengeId,
        uint256 indexed slot,
        address indexed winner,
        uint256 prize
    );

    // ──────────────────────────────── guards ──────────────────────────────

    function _live(uint256 challengeId) private view returns (Challenge storage c) {
        c = _challenges[challengeId];
        if (c.host == address(0)) revert UnknownChallenge();
    }

    // ─────────────────────────────── create ───────────────────────────────

    /// @notice Open a new sealed-entry challenge funded by the attached prize.
    function openChallenge(
        string calldata brief,
        string calldata criteria,
        uint64 sealWindow,
        uint64 unsealWindow
    ) external payable returns (uint256 challengeId) {
        if (msg.value == 0) revert PrizeMissing();
        if (sealWindow == 0 || unsealWindow == 0) revert BadWindow();

        challengeId = ++_challengeSeq;

        uint64 sealAt = uint64(block.timestamp) + sealWindow;
        uint64 unsealAt = sealAt + unsealWindow;

        Challenge storage c = _challenges[challengeId];
        c.host = msg.sender;
        c.brief = brief;
        c.criteria = criteria;
        c.prize = msg.value;
        c.sealDeadline = sealAt;
        c.unsealDeadline = unsealAt;
        c.stage = Stage.Sealing;

        emit ChallengeOpened(challengeId, msg.sender, msg.value, sealAt, unsealAt);
    }

    // ─────────────────────────────── commit ───────────────────────────────

    /// @notice Lock in a sealed entry. Required-signature entry point.
    /// @dev    `commitment` MUST equal sealOf(answer, salt, msg.sender, bountyId).
    ///         Nothing about the answer is observable until unsealing.
    function submitCommitment(uint256 bountyId, bytes32 commitment) external {
        Challenge storage c = _live(bountyId);

        if (block.timestamp >= c.sealDeadline) revert SealingClosed();
        if (commitment == bytes32(0)) revert EmptySeal();
        if (_slotOf[bountyId][msg.sender] != 0) revert AlreadyEntered();
        if (c.entryCount >= ENTRANT_CAP) revert ArenaFull();

        uint256 slot = c.entryCount;
        _entries[bountyId][slot] = Entry({
            entrant: msg.sender,
            seal: commitment,
            unsealed: false,
            answer: ""
        });
        _slotOf[bountyId][msg.sender] = slot + 1; // 1-based
        c.entryCount = slot + 1;

        emit EntrySealed(bountyId, slot, msg.sender);
    }

    // ─────────────────────────────── reveal ───────────────────────────────

    /// @notice Unseal a previously sealed entry. Required-signature entry point.
    /// @dev    Allowed only once the seal window closes and before the unseal
    ///         window closes. Recomputes the seal and checks it matches.
    function revealAnswer(
        uint256 bountyId,
        string calldata answer,
        bytes32 salt
    ) external {
        Challenge storage c = _live(bountyId);

        if (block.timestamp < c.sealDeadline) revert UnsealNotOpen();
        if (block.timestamp >= c.unsealDeadline) revert UnsealClosed();
        if (c.stage != Stage.Sealing) revert WrongStage();
        if (bytes(answer).length > ANSWER_CHAR_CAP) revert AnswerTooLong();

        uint256 oneBased = _slotOf[bountyId][msg.sender];
        if (oneBased == 0) revert NoEntry();
        uint256 slot = oneBased - 1;

        Entry storage e = _entries[bountyId][slot];
        if (e.unsealed) revert AlreadyUnsealed();

        if (sealOf(answer, salt, msg.sender, bountyId) != e.seal) {
            revert SealMismatch();
        }

        e.unsealed = true;
        e.answer = answer;

        emit EntryUnsealed(bountyId, slot, msg.sender);
    }

    // ──────────────────────────────── judge ───────────────────────────────

    /// @notice Run the AI jury over all unsealed entries in one batch call.
    ///         Required-signature entry point. Host-only, after the unseal
    ///         window closes, with at least one valid entry.
    /// @dev    `llmInput` is the pre-encoded batch jury request. The single call
    ///         covers every entry (not one call per entry).
    function judgeAll(uint256 bountyId, bytes calldata llmInput) external {
        Challenge storage c = _live(bountyId);
        if (msg.sender != c.host) revert NotHost();
        if (block.timestamp < c.unsealDeadline) revert WrongStage();
        if (c.stage != Stage.Sealing) revert WrongStage();
        if (_validEntryCount(bountyId) == 0) revert NoValidEntries();

        bytes memory verdict = _askJury(llmInput);

        c.stage = Stage.Adjudicated;
        c.juryVerdict = verdict;

        emit JuryRuled(bountyId, _validEntryCount(bountyId), verdict);
    }

    // ─────────────────────────────── finalize ─────────────────────────────

    /// @notice Settle the host-picked winner and release the prize.
    ///         Required-signature entry point.
    function finalizeWinner(uint256 bountyId, uint256 winnerIndex) external {
        Challenge storage c = _live(bountyId);
        if (msg.sender != c.host) revert NotHost();
        if (c.stage != Stage.Adjudicated) revert WrongStage();
        if (winnerIndex >= c.entryCount) revert BadIndex();

        Entry storage win = _entries[bountyId][winnerIndex];
        if (!win.unsealed) revert PickNotUnsealed();

        c.stage = Stage.Settled;
        c.pickedEntry = winnerIndex;

        uint256 prize = c.prize;
        c.prize = 0;

        (bool ok, ) = payable(win.entrant).call{value: prize}("");
        if (!ok) revert PayoutFailed();

        emit PrizeSettled(bountyId, winnerIndex, win.entrant, prize);
    }

    // ──────────────────────────── jury internals ──────────────────────────

    /// @dev Calls the Ritual LLM precompile and unwraps the response. Override
    ///      target for tests via `vm.etch` at LLM_JURY.
    function _askJury(bytes calldata llmInput) internal returns (bytes memory) {
        (bool ok, bytes memory raw) = LLM_JURY.call(llmInput);
        if (!ok) {
            assembly {
                revert(add(raw, 32), mload(raw))
            }
        }

        // Short-running async envelope: (bytes simInput, bytes actualOutput).
        (, bytes memory out) = abi.decode(raw, (bytes, bytes));

        // LLM response envelope: (bool hasError, bytes completion, bytes meta,
        //                         string err, (string,string,string) convo).
        (
            bool hasError,
            bytes memory completion,
            ,
            string memory err,

        ) = abi.decode(out, (bool, bytes, bytes, string, _Convo));
        if (hasError) revert JuryFailed(err);

        return completion;
    }

    struct _Convo {
        string platform;
        string path;
        string keyRef;
    }

    function _validEntryCount(uint256 challengeId) private view returns (uint256 n) {
        Challenge storage c = _challenges[challengeId];
        uint256 total = c.entryCount;
        for (uint256 i; i < total; ++i) {
            if (_entries[challengeId][i].unsealed) ++n;
        }
    }

    // ──────────────────────────────── pure ────────────────────────────────

    /// @notice Canonical seal derivation. Off-chain clients hash the same tuple
    ///         before calling `submitCommitment`. Order matches the spec:
    ///         keccak256(answer, salt, msg.sender, bountyId).
    function sealOf(
        string memory answer,
        bytes32 salt,
        address entrant,
        uint256 challengeId
    ) public pure returns (bytes32) {
        return keccak256(abi.encode(answer, salt, entrant, challengeId));
    }

    // ──────────────────────────────── views ───────────────────────────────

    function challengeInfo(uint256 challengeId)
        external
        view
        returns (
            address host,
            string memory brief,
            string memory criteria,
            uint256 prize,
            uint64 sealDeadline,
            uint64 unsealDeadline,
            Stage stage,
            uint256 totalEntries,
            uint256 pickedEntry,
            bytes memory juryVerdict
        )
    {
        Challenge storage c = _live(challengeId);
        return (
            c.host,
            c.brief,
            c.criteria,
            c.prize,
            c.sealDeadline,
            c.unsealDeadline,
            c.stage,
            c.entryCount,
            c.pickedEntry,
            c.juryVerdict
        );
    }

    function entryAt(uint256 challengeId, uint256 slot)
        external
        view
        returns (address entrant, bytes32 seal, bool unsealed, string memory answer)
    {
        Challenge storage c = _live(challengeId);
        if (slot >= c.entryCount) revert BadIndex();
        Entry storage e = _entries[challengeId][slot];
        return (e.entrant, e.seal, e.unsealed, e.answer);
    }

    function stageOf(uint256 challengeId) external view returns (Stage) {
        Challenge storage c = _live(challengeId);
        if (c.stage == Stage.Sealing && block.timestamp >= c.sealDeadline) {
            return Stage.Unsealing; // logical view; storage still Sealing
        }
        return c.stage;
    }

    function validEntryCount(uint256 challengeId) external view returns (uint256) {
        _live(challengeId);
        return _validEntryCount(challengeId);
    }

    function entryCount(uint256 challengeId) external view returns (uint256) {
        return _live(challengeId).entryCount;
    }
}
