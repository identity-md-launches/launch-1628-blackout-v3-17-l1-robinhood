// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {BaseTest} from "./Base.t.sol";
import {EndowmentEscrow} from "../src/EndowmentEscrow.sol";
import {GameRegistry} from "../src/GameRegistry.sol";
import {MockToken} from "./mocks/MockToken.sol";
import {Robinhood} from "../src/lib/Robinhood.sol";
import "../src/lib/Errors.sol";

/// @notice Offline integration: real pinned Registry/RewardPool, local platform records and ERC20.
contract L1CustodyV317Test is BaseTest {
    EndowmentEscrow internal escrow;
    bytes internal registryCode;
    bytes internal poolCode;

    function launchFeatures() internal pure override returns (bool) {
        return false;
    }

    function setUp() public virtual override {
        super.setUp();
        vm.clearMockedCalls();
        vm.chainId(4663);
        escrow = new EndowmentEscrow(address(desk));
        registryCode = type(GameRegistry).creationCode;
        poolCode = vm.getCode("RewardPool.sol:RewardPool");
    }

    function _forward() internal returns (uint256) {
        return escrow.forward(address(d.registry), 1, 1, registryCode, 1, 2, poolCode);
    }

    function testConstructorRejectsFactoryAsDesk() public {
        vm.expectRevert(InvalidValue.selector);
        new EndowmentEscrow(Robinhood.PROJECT_FACTORY);
    }

    /// forge-config: default.fuzz.runs = 512
    function testFuzzTransferFailureRollsBackAndSameProofCanRetry(uint256 input) public {
        uint256 amount = bound(input, 1, token.balanceOf(address(this)));
        token.transfer(address(escrow), amount);
        uint256 beforePool = token.balanceOf(address(d.pool));
        token.setFail(true);
        vm.expectRevert(bytes("test transfer failure"));
        _forward();
        assertFalse(escrow.forwarded(), "failed transfer must not spend the one-shot exit");
        assertEq(token.balanceOf(address(escrow)), amount);
        assertEq(token.balanceOf(address(d.pool)), beforePool);
        token.setFail(false);
        assertEq(_forward(), amount);
        assertTrue(escrow.forwarded());
        assertEq(token.balanceOf(address(escrow)), 0);
        assertEq(token.balanceOf(address(d.pool)), beforePool + amount);
    }

    function testForwardTransferCallbackCannotReenterOrDuplicatePayment() public {
        token.transfer(address(escrow), 1 ether);
        bytes memory callData =
            abi.encodeCall(escrow.forward, (address(d.registry), 1, 1, registryCode, 1, 2, poolCode));
        token.setCallback(address(escrow), callData);
        uint256 beforePool = token.balanceOf(address(d.pool));
        assertEq(_forward(), 1 ether);
        assertFalse(token.callbackSucceeded());
        assertTrue(escrow.forwarded());
        assertEq(token.balanceOf(address(escrow)), 0);
        assertEq(token.balanceOf(address(d.pool)), beforePool + 1 ether);
    }

    function testZeroBalanceFailureDoesNotPreventLaterOneWeiForward() public {
        vm.expectRevert(InsufficientBalance.selector);
        _forward();
        assertFalse(escrow.forwarded());
        token.transfer(address(escrow), 1);
        assertEq(_forward(), 1);
        vm.expectRevert(AlreadyDone.selector);
        _forward();
    }

    function testOnlyCanonicalTokenMovesAndNoAllowanceIsGranted() public {
        MockToken foreign = new MockToken();
        foreign.transfer(address(escrow), 123 ether);
        token.transfer(address(escrow), 1 ether);
        uint256 beforePool = token.balanceOf(address(d.pool));
        vm.prank(bob);
        assertEq(_forward(), 1 ether);
        assertEq(foreign.balanceOf(address(escrow)), 123 ether);
        assertEq(foreign.balanceOf(address(d.pool)), 0);
        assertEq(token.balanceOf(address(d.pool)), beforePool + 1 ether);
        assertEq(token.allowance(address(escrow), bob), 0);
        assertEq(token.allowance(address(escrow), address(d.pool)), 0);
        assertEq(token.allowance(address(escrow), Robinhood.PROJECT_FACTORY), 0);
    }

    /// forge-config: default.fuzz.runs = 512
    function testFuzzEveryOutOfRangeCoordinatePreservesCustody(uint8 which, uint256 input) public {
        token.transfer(address(escrow), 7 ether);
        uint256 registryIndex = 1;
        uint256 rewardIndex = 2;
        uint64 registryLaunch = 1;
        uint64 poolLaunch = 1;
        which %= 4;
        if (which == 0) registryLaunch = 0;
        else if (which == 1) poolLaunch = 0;
        else if (which == 2) registryIndex = bound(input, 8, type(uint256).max);
        else rewardIndex = bound(input, 8, type(uint256).max);
        vm.expectRevert(InvalidValue.selector);
        escrow.forward(
            address(d.registry), registryLaunch, registryIndex, registryCode, poolLaunch, rewardIndex, poolCode
        );
        assertFalse(escrow.forwarded());
        assertEq(token.balanceOf(address(escrow)), 7 ether);
        assertEq(_forward(), 7 ether, "invalid attempt must leave the correct proof usable");
    }
}
