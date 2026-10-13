// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {BaseTest} from "./Base.t.sol";
import {GameRegistry} from "../src/GameRegistry.sol";
import {Params} from "../src/Params.sol";
import {SwarmDesk} from "../src/SwarmDesk.sol";
import {SwarmArgs} from "../script/SwarmArgs.sol";
import {OracleAttestation} from "../src/oracle/OracleAttestation.sol";
import {MockSwarmIntake} from "./mocks/MockSwarmIntake.sol";
import "../src/lib/Errors.sol";

/// @dev Imported audit 1caeadee: preserve v3.17 bytecode and test the corrected operational guidance.
/// All coordinates/configuration here belong to the offline BaseTest fixture, never a launch handoff.
contract LaunchIntakeV317Test is BaseTest {
    GameRegistry private incomplete;
    MockSwarmIntake private intake;

    function launchFeatures() internal pure override returns (bool) {
        return false;
    }

    function setUp() public override {
        super.setUp();
        SwarmDesk.OracleConfig memory oracle = desk.oracleConfig();
        uint64 recordedTokenLaunch = desk.tokenLaunch();
        desk = SwarmDesk(
            bindingFactory.deploy(
                60,
                0,
                bytes.concat(
                    vm.getCode("SwarmDesk.sol:SwarmDesk"),
                    SwarmArgs.encode(
                        oracle,
                        SwarmDesk.BindingConfig(address(bindingFactory), 0, 0, 0, 0, bindingConfigHash(), 200, 1 ether),
                        team
                    )
                )
            )
        );
        address params = bindingFactory.deploy(
            61, 0, bytes.concat(type(Params).creationCode, abi.encode(address(desk), uint256(200), uint256(1 ether)))
        );
        incomplete = GameRegistry(
            bindingFactory.deploy(
                61,
                1,
                bytes.concat(
                    type(GameRegistry).creationCode,
                    abi.encode(
                        address(token),
                        params,
                        address(market),
                        d.registry.starterRoot(),
                        d.registry.freeRoot(),
                        d.registry.snapshotBlock(),
                        d.registry.endowment()
                    )
                )
            )
        );
        market.configureBinding(address(desk), bindingConfigHash());
        vm.prank(team);
        desk.bind(
            address(incomplete),
            type(GameRegistry).creationCode,
            type(Params).creationCode,
            61,
            1,
            61,
            0,
            recordedTokenLaunch
        );
        assertEq(incomplete.registered(), 0);
        vm.expectRevert(NotConfigured.selector);
        incomplete.module(1);

        MockSwarmIntake model = new MockSwarmIntake();
        vm.etch(oracle.intake, address(model).code);
        intake = MockSwarmIntake(oracle.intake);
        intake.setPrice(0.5 ether);
        token.transfer(address(desk), 10 ether);
        vm.warp((block.timestamp / 6 hours) * 6 hours + 2 hours);
    }

    function _registerRewards() private {
        bytes memory code = vm.getCode("FarmRewards.sol:FarmRewards");
        address rewards = bindingFactory.deploy(61, 3, bytes.concat(code, abi.encode(address(incomplete))));
        assertEq(incomplete.register(1, 61, 3, code), rewards);
        assertEq(incomplete.module(1), rewards);
    }

    function _answer(uint8 stream) private view returns (OracleAttestation.Attestation memory a, bytes memory sig) {
        bytes32[] memory values = new bytes32[](stream == 0 ? 7 : 17);
        values[0] = bytes32(desk.slot(stream));
        // The new FarmRewards has epoch 0 until game activation; use that epoch in the event answer.
        values[values.length - 1] = keccak256("offline launch intake regression");
        SwarmDesk.OracleConfig memory oracle = desk.oracleConfig();
        a.requestId = keccak256(abi.encode("launch intake test", stream));
        a.chainId = oracle.questionChain;
        a.questionHash = oracle.questions[stream];
        a.answerType = OracleAttestation.ANSWER_BYTES32_LIST;
        a.answer = abi.encode(values);
        a.fromBlock = oracle.fromBlock;
        a.toBlock = oracle.toBlock;
        a.panelSize = 5;
        a.quorum = 4;
        a.agreed = 5;
        a.issuedAt = uint64(block.timestamp);
        a.expiresAt = uint64(block.timestamp + 6 hours);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(0x123456, desk.attestationDigest(a));
        sig = abi.encodePacked(r, s, v);
    }

    function _assertUnstored(bytes32 requestId) private view {
        assertFalse(desk.consumed(requestId));
        assertEq(desk.acceptedSlotPlusOne(0), 0);
        (bytes32 hash,,,,, bool stored,) = desk.lastAnswer(0);
        assertEq(hash, bytes32(0));
        assertFalse(stored);
    }

    function _assertStored(uint8 stream, OracleAttestation.Attestation memory a) private view {
        assertTrue(desk.consumed(a.requestId));
        assertEq(desk.acceptedSlotPlusOne(stream), desk.slot(stream) + 1);
        (bytes32 hash, bytes32 id,,,, bool stored,) = desk.lastAnswer(stream);
        assertEq(hash, keccak256(a.answer));
        assertEq(id, a.requestId);
        assertTrue(stored);
    }

    function testStreamZeroRevertsThenSameAttestationStoresAfterRoleOneRegistration() public {
        (OracleAttestation.Attestation memory a, bytes memory sig) = _answer(0);
        vm.expectRevert(NotConfigured.selector);
        desk.submit(a, sig);
        _assertUnstored(a.requestId);
        assertFalse(desk.delivered(keccak256(abi.encode(address(0), a.requestId))));

        _registerRewards();
        desk.submit(a, sig);
        _assertStored(0, a);
        // Role 1 is sufficient for intake, but execution still needs the remaining event modules.
        vm.expectRevert(NotConfigured.selector);
        desk.execute(0, a.answer);
        _assertStored(0, a);
    }

    function testEarlyPaidCallbackFailsAndExpiryDoesNotRefundOrReopenSlot() public {
        uint256 balanceBefore = token.balanceOf(address(desk));
        uint256 intakeBefore = token.balanceOf(address(intake));
        bytes32 id = desk.askBackup(0, bytes("event body"));
        (uint64 askedSlot, uint64 deadline, uint8 streamPlusOne) = desk.pending(id);
        assertEq(streamPlusOne, 1);
        assertEq(askedSlot, desk.slot(0));
        (OracleAttestation.Attestation memory a, bytes memory sig) = _answer(0);
        assertFalse(intake.result(id, a, sig), "200k callback must fail before role 1 exists");
        _assertUnstored(a.requestId);
        assertFalse(desk.delivered(keccak256(abi.encode(address(intake), id))));
        (uint64 remainingSlot, uint64 remainingDeadline, uint8 remainingStream) = desk.pending(id);
        assertEq(remainingSlot, askedSlot);
        assertEq(remainingDeadline, deadline);
        assertEq(remainingStream, streamPlusOne);
        vm.expectRevert(TooEarly.selector);
        desk.askBackup(0, bytes("event body"));
        vm.expectRevert(TooEarly.selector);
        desk.clearExpired(id);
        vm.warp(deadline);
        desk.clearExpired(id);
        (,, remainingStream) = desk.pending(id);
        assertEq(remainingStream, 0);
        assertEq(desk.askedSlotPlusOne(0), uint256(askedSlot) + 1);
        vm.expectRevert(TooEarly.selector);
        desk.askBackup(0, bytes("event body"));
        assertEq(token.balanceOf(address(desk)), balanceBefore - 0.5 ether);
        assertEq(token.balanceOf(address(intake)), intakeBefore + 0.5 ether);
        // If the signed bytes remain available and fresh, even a failed backup can be relayed later.
        _registerRewards();
        desk.submit(a, sig);
        _assertStored(0, a);
    }

    function testPaidCallbackStoresUnder200kAfterRoleOneRegistration() public {
        _registerRewards();
        bytes32 id = desk.askBackup(0, bytes("event body"));
        (OracleAttestation.Attestation memory a, bytes memory sig) = _answer(0);
        assertTrue(intake.result(id, a, sig), "registered role 1 permits the 200k callback");
        _assertStored(0, a);
        (,, uint8 streamPlusOne) = desk.pending(id);
        assertEq(streamPlusOne, 0);
    }

    function testRegulatorStoresBeforeRoleOneButExecutionWaitsForModules() public {
        (OracleAttestation.Attestation memory a, bytes memory sig) = _answer(1);
        desk.submit(a, sig);
        _assertStored(1, a);
        vm.expectRevert(NotConfigured.selector);
        desk.execute(1, a.answer);
        _assertStored(1, a);
    }
}
