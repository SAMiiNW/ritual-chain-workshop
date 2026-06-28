// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {Test} from "forge-std/Test.sol";
import {SealedBountyJudge} from "../contracts/SealedBountyJudge.sol";

/// @dev These tests exercise the commit/unseal/finalize logic and all the
///      `judgeAll` GUARD conditions that revert BEFORE the contract ever calls
///      the LLM precompile — so no mock precompile is used anywhere. The actual
///      AI jury call (which is an async precompile and cannot settle inside a
///      local EVM) is proven for real on-chain by scripts/e2e.mjs.
contract SealedBountyJudgeTest is Test {
    SealedBountyJudge internal arena;

    address internal host = makeAddr("host");
    address internal alice = makeAddr("alice");
    address internal bob = makeAddr("bob");

    uint64 internal constant SEAL_WINDOW = 1 hours;
    uint64 internal constant UNSEAL_WINDOW = 1 hours;
    uint256 internal constant PRIZE = 2 ether;

    function setUp() public {
        arena = new SealedBountyJudge();
        vm.deal(host, 100 ether);
    }

    // ── helpers ────────────────────────────────────────────────────────────

    function _open() internal returns (uint256 id) {
        vm.prank(host);
        id = arena.openChallenge{value: PRIZE}(
            "Name the protocol",
            "clarity and correctness",
            SEAL_WINDOW,
            UNSEAL_WINDOW
        );
    }

    function _seal(uint256 id, address who, string memory ans, bytes32 salt) internal {
        bytes32 s = arena.sealOf(ans, salt, who, id);
        vm.prank(who);
        arena.submitCommitment(id, s);
    }

    function _sealDeadline(uint256 id) internal view returns (uint64 d) {
        (, , , , d, , , , , ) = arena.challengeInfo(id);
    }

    function _unsealDeadline(uint256 id) internal view returns (uint64 d) {
        (, , , , , d, , , , ) = arena.challengeInfo(id);
    }

    // ── open ─────────────────────────────────────────────────────────────

    function test_Open_SetsSealingStage() public {
        uint256 id = _open();
        (
            address h,
            ,
            ,
            uint256 prize,
            ,
            ,
            SealedBountyJudge.Stage stage,
            uint256 count,
            ,

        ) = arena.challengeInfo(id);
        assertEq(h, host);
        assertEq(prize, PRIZE);
        assertEq(uint256(stage), uint256(SealedBountyJudge.Stage.Sealing));
        assertEq(count, 0);
    }

    function test_Open_RevertNoPrize() public {
        vm.prank(host);
        vm.expectRevert(SealedBountyJudge.PrizeMissing.selector);
        arena.openChallenge("b", "c", SEAL_WINDOW, UNSEAL_WINDOW);
    }

    function test_Open_RevertZeroWindow() public {
        vm.prank(host);
        vm.expectRevert(SealedBountyJudge.BadWindow.selector);
        arena.openChallenge{value: PRIZE}("b", "c", 0, UNSEAL_WINDOW);
    }

    // ── seal (commit) ──────────────────────────────────────────────────────

    function test_Seal_HidesAnswer() public {
        uint256 id = _open();
        _seal(id, alice, "the answer", keccak256("a"));
        (address e, bytes32 s, bool unsealed, string memory ans) = arena.entryAt(id, 0);
        assertEq(e, alice);
        assertTrue(s != bytes32(0));
        assertFalse(unsealed);
        assertEq(bytes(ans).length, 0); // hidden during the seal window
    }

    function test_Seal_RevertDouble() public {
        uint256 id = _open();
        _seal(id, alice, "x", keccak256("a"));
        bytes32 s = arena.sealOf("y", keccak256("b"), alice, id);
        vm.prank(alice);
        vm.expectRevert(SealedBountyJudge.AlreadyEntered.selector);
        arena.submitCommitment(id, s);
    }

    function test_Seal_RevertEmpty() public {
        uint256 id = _open();
        vm.prank(alice);
        vm.expectRevert(SealedBountyJudge.EmptySeal.selector);
        arena.submitCommitment(id, bytes32(0));
    }

    function test_Seal_RevertAfterDeadline() public {
        uint256 id = _open();
        vm.warp(_sealDeadline(id));
        bytes32 s = arena.sealOf("x", keccak256("a"), alice, id);
        vm.prank(alice);
        vm.expectRevert(SealedBountyJudge.SealingClosed.selector);
        arena.submitCommitment(id, s);
    }

    function test_Seal_RevertUnknownChallenge() public {
        vm.prank(alice);
        vm.expectRevert(SealedBountyJudge.UnknownChallenge.selector);
        arena.submitCommitment(999, keccak256("x"));
    }

    // ── unseal (reveal): happy ──────────────────────────────────────────────

    function test_Unseal_Valid() public {
        uint256 id = _open();
        bytes32 salt = keccak256("a");
        _seal(id, alice, "winning", salt);
        vm.warp(_sealDeadline(id));
        vm.prank(alice);
        arena.revealAnswer(id, "winning", salt);
        (, , bool unsealed, string memory ans) = arena.entryAt(id, 0);
        assertTrue(unsealed);
        assertEq(ans, "winning");
        assertEq(arena.validEntryCount(id), 1);
    }

    // ── unseal: failures ────────────────────────────────────────────────────

    function test_Unseal_RevertWrongSalt() public {
        uint256 id = _open();
        _seal(id, alice, "ans", keccak256("right"));
        vm.warp(_sealDeadline(id));
        vm.prank(alice);
        vm.expectRevert(SealedBountyJudge.SealMismatch.selector);
        arena.revealAnswer(id, "ans", keccak256("wrong"));
    }

    function test_Unseal_RevertWrongAnswer() public {
        uint256 id = _open();
        bytes32 salt = keccak256("s");
        _seal(id, alice, "real", salt);
        vm.warp(_sealDeadline(id));
        vm.prank(alice);
        vm.expectRevert(SealedBountyJudge.SealMismatch.selector);
        arena.revealAnswer(id, "fake", salt);
    }

    function test_Unseal_RevertImpersonation() public {
        uint256 id = _open();
        bytes32 salt = keccak256("s");
        _seal(id, alice, "ans", salt);
        vm.warp(_sealDeadline(id));
        vm.prank(bob); // bob never entered
        vm.expectRevert(SealedBountyJudge.NoEntry.selector);
        arena.revealAnswer(id, "ans", salt);
    }

    function test_Unseal_RevertCrossChallengeReplay() public {
        uint256 id1 = _open();
        uint256 id2 = _open();
        bytes32 salt = keccak256("s");
        bytes32 s1 = arena.sealOf("ans", salt, alice, id1);
        vm.prank(alice);
        arena.submitCommitment(id2, s1);
        vm.warp(_sealDeadline(id2));
        vm.prank(alice);
        vm.expectRevert(SealedBountyJudge.SealMismatch.selector);
        arena.revealAnswer(id2, "ans", salt);
    }

    function test_Unseal_RevertBeforeWindow() public {
        uint256 id = _open();
        bytes32 salt = keccak256("s");
        _seal(id, alice, "ans", salt);
        vm.prank(alice);
        vm.expectRevert(SealedBountyJudge.UnsealNotOpen.selector);
        arena.revealAnswer(id, "ans", salt);
    }

    function test_Unseal_RevertAfterWindow() public {
        uint256 id = _open();
        bytes32 salt = keccak256("s");
        _seal(id, alice, "ans", salt);
        vm.warp(_unsealDeadline(id));
        vm.prank(alice);
        vm.expectRevert(SealedBountyJudge.UnsealClosed.selector);
        arena.revealAnswer(id, "ans", salt);
    }

    function test_Unseal_RevertDouble() public {
        uint256 id = _open();
        bytes32 salt = keccak256("s");
        _seal(id, alice, "ans", salt);
        vm.warp(_sealDeadline(id));
        vm.prank(alice);
        arena.revealAnswer(id, "ans", salt);
        vm.prank(alice);
        vm.expectRevert(SealedBountyJudge.AlreadyUnsealed.selector);
        arena.revealAnswer(id, "ans", salt);
    }

    // ── judge: guards (all revert before the precompile is ever called) ─────

    function test_Judge_RevertNotHost() public {
        uint256 id = _open();
        _seal(id, alice, "a", keccak256("sa"));
        vm.warp(_sealDeadline(id));
        vm.prank(alice);
        arena.revealAnswer(id, "a", keccak256("sa"));
        vm.warp(_unsealDeadline(id));
        vm.prank(alice);
        vm.expectRevert(SealedBountyJudge.NotHost.selector);
        arena.judgeAll(id, bytes("x"));
    }

    function test_Judge_RevertWhileUnsealOpen() public {
        uint256 id = _open();
        _seal(id, alice, "a", keccak256("sa"));
        vm.warp(_sealDeadline(id));
        vm.prank(alice);
        arena.revealAnswer(id, "a", keccak256("sa"));
        vm.prank(host);
        vm.expectRevert(SealedBountyJudge.WrongStage.selector);
        arena.judgeAll(id, bytes("x"));
    }

    function test_Judge_RevertNoValidEntries() public {
        uint256 id = _open();
        _seal(id, alice, "a", keccak256("sa")); // sealed, never unsealed
        vm.warp(_unsealDeadline(id));
        vm.prank(host);
        vm.expectRevert(SealedBountyJudge.NoValidEntries.selector);
        arena.judgeAll(id, bytes("x"));
    }

    // ── finalize: guards (no judging needed for these reverts) ──────────────

    function test_Finalize_RevertBeforeJudge() public {
        uint256 id = _open();
        _seal(id, alice, "a", keccak256("sa"));
        vm.warp(_sealDeadline(id));
        vm.prank(alice);
        arena.revealAnswer(id, "a", keccak256("sa"));
        vm.warp(_unsealDeadline(id));
        vm.prank(host);
        vm.expectRevert(SealedBountyJudge.WrongStage.selector);
        arena.finalizeWinner(id, 0);
    }

    function test_Finalize_RevertNotHost() public {
        uint256 id = _open();
        vm.prank(alice);
        vm.expectRevert(SealedBountyJudge.NotHost.selector);
        arena.finalizeWinner(id, 0);
    }

    // ── fuzz: seal binding ───────────────────────────────────────────────────

    function testFuzz_OnlyExactUnsealSucceeds(
        string calldata answer,
        bytes32 salt,
        bytes32 wrongSalt
    ) public {
        vm.assume(salt != wrongSalt);
        vm.assume(bytes(answer).length <= 8192);
        uint256 id = _open();
        bytes32 s = arena.sealOf(answer, salt, alice, id);
        vm.prank(alice);
        arena.submitCommitment(id, s);
        vm.warp(_sealDeadline(id));
        vm.prank(alice);
        vm.expectRevert(SealedBountyJudge.SealMismatch.selector);
        arena.revealAnswer(id, answer, wrongSalt);
    }
}
