// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {BaseTest} from "./Base.t.sol";
import {SwarmDesk} from "../src/SwarmDesk.sol";
import {MockToken} from "./mocks/MockToken.sol";
import {MockSwarmIntake} from "./mocks/MockSwarmIntake.sol";
import "../src/lib/Errors.sol";

contract L1DeskHandlerV317 is Test {
    SwarmDesk public immutable desk;
    MockToken public immutable token;
    MockSwarmIntake public immutable intake;
    uint256 public immutable maxPrice;
    address[2] public actors;
    uint256 public donated;
    uint256 public spent;
    uint256[2] public lastPaidSlotPlusOne;
    mapping(uint8 => mapping(uint256 => bool)) public paid;
    bytes32[] public requests;

    constructor(SwarmDesk d, MockToken t, MockSwarmIntake i, address a, address b) {
        desk = d;
        token = t;
        intake = i;
        maxPrice = d.oracleConfig().maxPrice;
        actors = [a, b];
    }

    function _body(uint8 stream) private pure returns (bytes memory) {
        return stream == 0 ? bytes("event body") : bytes("regulator body");
    }

    function _early(uint8 stream, uint256 slot_) private view returns (bool) {
        return paid[stream][slot_] || block.timestamp < slot_ * (stream == 0 ? 6 hours : 7 days) + 1 hours;
    }

    function donate(uint256 who, uint256 input) external {
        uint256 amount = bound(input, 1, 100 ether);
        vm.prank(actors[who % 2]);
        token.transfer(address(desk), amount);
        donated += amount;
    }

    function elapse(uint256 input) external {
        vm.warp(block.timestamp + bound(input, 1, 7 days));
    }

    function ask(uint8 inputStream, uint256 priceCase, uint256 who) external {
        uint8 stream = inputStream % 2;
        uint256 slot_ = desk.slot(stream);
        uint256 price = priceCase % 4 == 0 ? 0 : priceCase % 4 == 1 ? maxPrice + 1 : priceCase % 4 == 2 ? 1 : maxPrice;
        intake.setPrice(price);
        bool early = _early(stream, slot_);
        bool invalidPrice = price == 0 || price > maxPrice;
        if (early) vm.expectRevert(TooEarly.selector);
        else if (invalidPrice) vm.expectRevert(InvalidValue.selector);
        vm.prank(actors[who % 2]);
        bytes32 id = desk.askBackup(stream, _body(stream));
        if (!early && !invalidPrice) {
            assertTrue(id != bytes32(0));
            assertFalse(paid[stream][slot_], "at most one paid request per stream/slot");
            paid[stream][slot_] = true;
            lastPaidSlotPlusOne[stream] = slot_ + 1;
            spent += price;
            requests.push(id);
            (uint64 s, uint64 deadline, uint8 plusOne) = desk.pending(id);
            assertEq(s, slot_);
            assertEq(plusOne, stream + 1);
            assertGt(deadline, block.timestamp);
            assertLe(deadline, block.timestamp + 1 hours);
        } else {
            assertEq(desk.askedSlotPlusOne(stream), lastPaidSlotPlusOne[stream], "failed ask cannot spend the slot");
        }
    }

    function badBody(uint8 inputStream) external {
        vm.expectRevert(InvalidProof.selector);
        desk.askBackup(inputStream % 2, bytes("uncommitted body"));
    }

    function transferFailure(uint8 inputStream) external {
        uint8 stream = inputStream % 2;
        uint256 slot_ = desk.slot(stream);
        intake.setPrice(maxPrice);
        token.setFail(true);
        if (_early(stream, slot_)) vm.expectRevert(TooEarly.selector);
        else vm.expectRevert(bytes("test transfer failure"));
        desk.askBackup(stream, _body(stream));
        token.setFail(false);
        assertEq(desk.askedSlotPlusOne(stream), lastPaidSlotPlusOne[stream]);
    }

    function failRequest(uint256 input, bool statusTwo) external {
        if (requests.length == 0) return;
        bytes32 id = requests[input % requests.length];
        (,, uint8 streamPlusOne) = desk.pending(id);
        bool ok = intake.failure(id, statusTwo ? 2 : 1, keccak256("offline failure"));
        assertEq(ok, streamPlusOne != 0);
        (,, uint8 after_) = desk.pending(id);
        assertEq(after_, 0);
        // A failure clears its pending request, never the paid slot or the token debit.
        if (streamPlusOne != 0) {
            assertEq(desk.askedSlotPlusOne(streamPlusOne - 1), lastPaidSlotPlusOne[streamPlusOne - 1]);
        }
    }

    function expire(uint256 input) external {
        if (requests.length == 0) return;
        bytes32 id = requests[input % requests.length];
        (, uint64 deadline, uint8 streamPlusOne) = desk.pending(id);
        bool canClear = streamPlusOne != 0 && block.timestamp >= deadline;
        if (!canClear) vm.expectRevert(TooEarly.selector);
        desk.clearExpired(id);
        if (canClear) {
            (,, uint8 after_) = desk.pending(id);
            assertEq(after_, 0);
        }
    }
}

/// @notice Conservation of Desk donations and paid backup debits across failure/expiry/retry sequences.
/// Authentic oracle signatures/execution are tested elsewhere; this campaign targets the token custody path.
/// forge-config: default.invariant.runs = 128
/// forge-config: default.invariant.depth = 64
/// forge-config: default.invariant.fail-on-revert = true
contract L1DeskInvariantV317Test is BaseTest {
    MockSwarmIntake private intake;
    L1DeskHandlerV317 private handler;
    uint256 private intakeBefore;
    uint256 private actorTotal;
    uint256 private constant INITIAL = 100 ether;

    function launchFeatures() internal pure override returns (bool) {
        return false;
    }

    function setUp() public override {
        super.setUp();
        vm.clearMockedCalls();
        vm.chainId(4663);
        address endpoint = desk.oracleConfig().intake;
        vm.etch(endpoint, type(MockSwarmIntake).runtimeCode);
        intake = MockSwarmIntake(endpoint);
        token.transfer(address(desk), INITIAL);
        intakeBefore = token.balanceOf(endpoint);
        actorTotal = token.balanceOf(alice) + token.balanceOf(bob);
        handler = new L1DeskHandlerV317(desk, token, intake, alice, bob);
        bytes4[] memory selectors = new bytes4[](7);
        selectors[0] = handler.donate.selector;
        selectors[1] = handler.elapse.selector;
        selectors[2] = handler.ask.selector;
        selectors[3] = handler.badBody.selector;
        selectors[4] = handler.transferFailure.selector;
        selectors[5] = handler.failRequest.selector;
        selectors[6] = handler.expire.selector;
        targetSelector(FuzzSelector(address(handler), selectors));
        targetContract(address(handler));
        targetSender(alice);
        targetSender(bob);
    }

    function invariant_DonationsEqualHeldTokensPlusPaidBackups() public view {
        assertEq(token.balanceOf(address(desk)) + handler.spent(), INITIAL + handler.donated());
        assertEq(token.balanceOf(address(intake)), intakeBefore + handler.spent());
        assertEq(token.balanceOf(alice) + token.balanceOf(bob) + handler.donated(), actorTotal);
    }

    function testHandlerPaidFailureAndExpiryDoNotRefundOrReopenSlot() public {
        vm.warp((block.timestamp / 6 hours) * 6 hours + 2 hours);
        handler.transferFailure(0);
        assertEq(handler.spent(), 0);
        assertEq(intake.nonce(), 0, "intake state must also roll back");
        handler.ask(0, 3, 0);
        assertEq(handler.spent(), handler.maxPrice());
        assertEq(intake.nonce(), 1);
        handler.failRequest(0, false);
        handler.ask(0, 3, 1); // Handler requires TooEarly for a retry of this paid slot.
        assertEq(intake.nonce(), 1);
        vm.warp(block.timestamp + 6 hours);
        handler.ask(0, 3, 1);
        assertEq(intake.nonce(), 2);
        handler.elapse(1 hours);
        handler.expire(1);
        handler.ask(0, 3, 0);
        assertEq(intake.nonce(), 2);
        assertEq(handler.spent(), 2 * handler.maxPrice());
        invariant_DonationsEqualHeldTokensPlusPaidBackups();
        invariant_FailureCannotReopenPaidSlotOrLeaveAllowance();
    }

    function invariant_FailureCannotReopenPaidSlotOrLeaveAllowance() public view {
        assertEq(desk.askedSlotPlusOne(0), handler.lastPaidSlotPlusOne(0));
        assertEq(desk.askedSlotPlusOne(1), handler.lastPaidSlotPlusOne(1));
        assertEq(token.allowance(address(desk), address(intake)), 0);
        assertFalse(token.failTransfers());
    }
}
