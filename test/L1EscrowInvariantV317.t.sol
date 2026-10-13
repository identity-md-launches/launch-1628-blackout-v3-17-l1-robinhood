// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {BaseTest} from "./Base.t.sol";
import {EndowmentEscrow} from "../src/EndowmentEscrow.sol";
import {GameRegistry} from "../src/GameRegistry.sol";
import {MockToken} from "./mocks/MockToken.sol";
import "../src/lib/Errors.sol";

/// @dev Ghost accounting records actual successful deposits/exits, independent of escrow storage.
contract L1EscrowHandlerV317 is Test {
    EndowmentEscrow public immutable escrow;
    MockToken public immutable token;
    address public immutable registry;
    address public immutable pool;
    address[2] public actors;
    bytes private registryCode;
    bytes private poolCode;
    uint256 public deposited;
    uint256 public forwardedAmount;
    uint256 public successes;

    constructor(
        EndowmentEscrow e,
        MockToken t,
        address r,
        address p,
        address a,
        address b,
        bytes memory rc,
        bytes memory pc
    ) {
        escrow = e;
        token = t;
        registry = r;
        pool = p;
        actors = [a, b];
        registryCode = rc;
        poolCode = pc;
    }

    function deposit(uint256 who, uint256 input) external {
        address actor = actors[who % 2];
        uint256 balance = token.balanceOf(actor);
        if (balance == 0) return;
        uint256 amount = bound(input, 1, balance < 1000 ether ? balance : 1000 ether);
        vm.prank(actor);
        token.transfer(address(escrow), amount);
        deposited += amount;
    }

    function forward(uint256 who) external {
        uint256 amount = token.balanceOf(address(escrow));
        if (escrow.forwarded()) vm.expectRevert(AlreadyDone.selector);
        else if (amount == 0) vm.expectRevert(InsufficientBalance.selector);
        vm.prank(actors[who % 2]);
        // Expected reverts return zero through the cheatcode; only a real exit updates the ghosts.
        uint256 sent = escrow.forward(registry, 1, 1, registryCode, 1, 2, poolCode);
        if (sent != 0) {
            assertEq(sent, amount, "whole balance must exit");
            forwardedAmount += sent;
            successes++;
        }
    }

    function rejectedProof(uint256 who, uint256 input) external {
        uint256 index = bound(input, 8, type(uint256).max);
        bool done = escrow.forwarded();
        uint256 beforeBalance = token.balanceOf(address(escrow));
        vm.expectRevert(done ? AlreadyDone.selector : InvalidValue.selector);
        vm.prank(actors[who % 2]);
        escrow.forward(registry, 1, 1, registryCode, 1, index, poolCode);
        assertEq(token.balanceOf(address(escrow)), beforeBalance);
        assertEq(escrow.forwarded(), done);
    }

    function failedTransfer(uint256 who) external {
        uint256 beforeBalance = token.balanceOf(address(escrow));
        bool done = escrow.forwarded();
        token.setFail(true);
        if (done) vm.expectRevert(AlreadyDone.selector);
        else if (beforeBalance == 0) vm.expectRevert(InsufficientBalance.selector);
        else vm.expectRevert(bytes("test transfer failure"));
        vm.prank(actors[who % 2]);
        escrow.forward(registry, 1, 1, registryCode, 1, 2, poolCode);
        token.setFail(false);
        assertEq(token.balanceOf(address(escrow)), beforeBalance);
        assertEq(escrow.forwarded(), done, "transfer failure must roll back the exit flag");
    }

    function callbackForward(uint256 who) external {
        bytes memory data = abi.encodeCall(escrow.forward, (registry, 1, 1, registryCode, 1, 2, poolCode));
        token.setCallback(address(escrow), data);
        this.forward(who);
        assertFalse(token.callbackSucceeded(), "nested forward must never succeed");
        token.setCallback(address(0), hex"");
    }
}

/// @notice L1 escrow custody under random deposits, proof failures, transfer failures, callbacks and retries.
/// No fork or fabricated platform output: coordinates 1/1 and 1/2 are from the offline deployment fixture.
/// forge-config: default.invariant.runs = 256
/// forge-config: default.invariant.depth = 64
/// forge-config: default.invariant.fail-on-revert = true
contract L1EscrowInvariantV317Test is BaseTest {
    EndowmentEscrow private escrow;
    L1EscrowHandlerV317 private handler;
    MockToken private foreign;
    uint256 private poolBefore;
    uint256 private actorTotal;

    function launchFeatures() internal pure override returns (bool) {
        return false;
    }

    function setUp() public override {
        super.setUp();
        vm.clearMockedCalls();
        vm.chainId(4663);
        escrow = new EndowmentEscrow(address(desk));
        foreign = new MockToken();
        foreign.transfer(address(escrow), 17 ether);
        poolBefore = token.balanceOf(address(d.pool));
        actorTotal = token.balanceOf(alice) + token.balanceOf(bob);
        handler = new L1EscrowHandlerV317(
            escrow,
            token,
            address(d.registry),
            address(d.pool),
            alice,
            bob,
            type(GameRegistry).creationCode,
            vm.getCode("RewardPool.sol:RewardPool")
        );
        bytes4[] memory selectors = new bytes4[](5);
        selectors[0] = handler.deposit.selector;
        selectors[1] = handler.forward.selector;
        selectors[2] = handler.rejectedProof.selector;
        selectors[3] = handler.failedTransfer.selector;
        selectors[4] = handler.callbackForward.selector;
        targetSelector(FuzzSelector(address(handler), selectors));
        targetContract(address(handler));
        targetSender(alice);
        targetSender(bob);
    }

    function invariant_CustodyMatchesIndependentDepositAndExitLedger() public view {
        assertEq(token.balanceOf(address(escrow)), handler.deposited() - handler.forwardedAmount());
        assertEq(token.balanceOf(address(d.pool)), poolBefore + handler.forwardedAmount());
        assertEq(token.balanceOf(alice) + token.balanceOf(bob) + handler.deposited(), actorTotal);
    }

    function testHandlerExercisesFailedExitSuccessAndLateDeposit() public {
        handler.deposit(0, 10 ether);
        handler.failedTransfer(1);
        assertEq(handler.successes(), 0);
        handler.rejectedProof(0, 8);
        handler.callbackForward(1);
        assertEq(handler.successes(), 1);
        assertEq(handler.forwardedAmount(), 10 ether);
        handler.deposit(1, 1);
        handler.forward(0); // Handler requires AlreadyDone despite a new balance.
        assertEq(token.balanceOf(address(escrow)), 1);
        assertEq(handler.successes(), 1);
        invariant_CustodyMatchesIndependentDepositAndExitLedger();
        invariant_ExitIsOneShotAndOnlyCanonicalTokenMoves();
    }

    function invariant_ExitIsOneShotAndOnlyCanonicalTokenMoves() public view {
        assertLe(handler.successes(), 1);
        assertEq(escrow.forwarded(), handler.successes() == 1);
        assertEq(foreign.balanceOf(address(escrow)), 17 ether);
        assertEq(foreign.balanceOf(address(d.pool)), 0);
        assertEq(token.allowance(address(escrow), alice), 0);
        assertEq(token.allowance(address(escrow), bob), 0);
        assertEq(token.allowance(address(escrow), address(handler)), 0);
        assertFalse(token.failTransfers());
    }
}
