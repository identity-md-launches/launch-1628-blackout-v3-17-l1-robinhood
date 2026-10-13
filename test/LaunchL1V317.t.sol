// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {SwarmDesk} from "../src/SwarmDesk.sol";
import {EndowmentEscrow} from "../src/EndowmentEscrow.sol";
import {Robinhood} from "../src/lib/Robinhood.sol";
import "../src/lib/Errors.sol";

/// @dev Offline factory probe: both CREATE2 operations occur in one call, in launch index order.
contract L1V317DeploymentProbe {
    function deployPair(uint64 launchNumber, bytes memory deskInitCode, bytes memory escrowCode)
        external
        returns (address[2] memory deployed)
    {
        deployed[0] = _deploy(deskInitCode, keccak256(abi.encode(launchNumber, uint256(0))));
        // Resolve $contract:SwarmDesk to index 0 of this same invocation.
        deployed[1] =
            _deploy(bytes.concat(escrowCode, abi.encode(deployed[0])), keccak256(abi.encode(launchNumber, uint256(1))));
    }

    function _deploy(bytes memory code, bytes32 salt) private returns (address deployed) {
        require(code.length <= 49_152, "init code exceeds EIP-3860");
        assembly ("memory-safe") {
            deployed := create2(0, add(code, 32), mload(code), salt)
        }
        require(deployed != address(0) && deployed.code.length != 0, "constructor failed");
    }
}

contract LaunchL1V317Test is Test {
    address private constant BINDER = 0x6d51cBE774aeAe4dd40bCA2560E9bc2695A0d007;
    bytes32 private constant GAME_CONFIG_HASH = 0x11ed7438974e96ecc962201e9c46422c7bf239d725876863fa25a56c734b20d3;
    // Only a local test coordinate. Actual launch numbers come from the platform's recorded outputs.
    uint64 private constant TEST_LAUNCH = 77;

    function _deskWords() private pure returns (bytes memory) {
        return abi.encode(
            bytes32(0x6f7261636c652e72657175657374406f7261636c652d31000000000000000000),
            uint256(5391989333430298100116863486635657822062725418115979424500284366258177),
            bytes32(0x2fc5a57f2c5f7bc083ea8ac5016234f1a0b1c68a514e5d921956cc57948534ef),
            bytes32(0xc13efed8438aab53ea052a4507def2dc4ce9856765520dfa28c66daa59cfc11d),
            bytes32(0x00e69e4445c7ca7256338293f9f9cea439fd2beb1959d1d43ebec7b14493e2f6),
            bytes32(0xc0ae7511b06744cf7ccadc6b60ff9ff96cb7234cf32988850df33324861cc8df),
            GAME_CONFIG_HASH,
            BINDER
        );
    }

    function _predict(uint256 index, bytes memory initCode) private pure returns (address) {
        return address(
            uint160(
                uint256(
                    keccak256(
                        abi.encodePacked(
                            bytes1(0xff),
                            Robinhood.PROJECT_FACTORY,
                            keccak256(abi.encode(TEST_LAUNCH, index)),
                            keccak256(initCode)
                        )
                    )
                )
            )
        );
    }

    function testExactL1PairDeploysTogetherOnEmptyRobinhoodChain() public {
        vm.chainId(4663);
        assertEq(Robinhood.PROJECT_FACTORY.code.length, 0);
        assertEq(Robinhood.PROJECT_REGISTRY.code.length, 0);
        assertEq(Robinhood.LAUNCH_FACTORY.code.length, 0);
        assertEq(Robinhood.POOL_MANAGER.code.length, 0);
        assertEq(Robinhood.INTAKE.code.length, 0);
        assertEq(Robinhood.DELIVERY.code.length, 0);
        assertEq(Robinhood.ATTESTER.code.length, 0);
        assertEq(Robinhood.IMD.code.length, 0);
        assertEq(BINDER.code.length, 0);

        bytes memory deskCode = vm.getCode("SwarmDesk.sol:SwarmDesk");
        bytes memory escrowCode = vm.getCode("EndowmentEscrow.sol:EndowmentEscrow");
        assertEq(keccak256(deskCode), 0x1d8e1afa90ba7a4c436fa2406f52743c97f7e6d9add372516144cadcb0795879);
        assertEq(keccak256(escrowCode), 0xe7a48446223ad53d50a9a9372c5552b70fb94e4f03c0f9f45298f7e5d2036368);
        bytes memory words = _deskWords();
        assertEq(words.length, 8 * 32);
        bytes memory deskInitCode = bytes.concat(deskCode, words);
        address predictedDesk = _predict(0, deskInitCode);
        address predictedEscrow = _predict(1, bytes.concat(escrowCode, abi.encode(predictedDesk)));
        vm.etch(Robinhood.PROJECT_FACTORY, type(L1V317DeploymentProbe).runtimeCode);
        address[2] memory deployed =
            L1V317DeploymentProbe(Robinhood.PROJECT_FACTORY).deployPair(TEST_LAUNCH, deskInitCode, escrowCode);
        assertEq(deployed[0], predictedDesk);
        assertEq(deployed[1], predictedEscrow);
        SwarmDesk desk = SwarmDesk(deployed[0]);
        EndowmentEscrow escrow = EndowmentEscrow(deployed[1]);
        assertEq(desk.binder(), BINDER);
        assertEq(address(desk.registry()), address(0));
        assertEq(desk.tokenLaunch(), 0);
        assertEq(desk.bindingConfig().gameConfigHash, GAME_CONFIG_HASH);
        assertEq(desk.bindingConfig().heartbeatBps, 200);
        assertEq(desk.bindingConfig().heartbeatCap, 1 ether);
        assertEq(desk.bindingConfig().factory, Robinhood.PROJECT_FACTORY);
        assertEq(desk.oracleConfig().intake, Robinhood.INTAKE);
        assertEq(desk.oracleConfig().delivery, Robinhood.DELIVERY);
        assertEq(desk.oracleConfig().signer, Robinhood.ATTESTER);
        assertEq(desk.oracleConfig().asset, Robinhood.IMD);
        assertEq(escrow.desk(), address(desk));
        assertFalse(escrow.forwarded());
        assertEq(escrow.factory(), Robinhood.PROJECT_FACTORY);
        assertEq(escrow.records(), Robinhood.PROJECT_REGISTRY);
        _assertRuntime(deployed[0]);
        _assertRuntime(deployed[1]);

        // Deploying factory and transaction origin acquire no binder privilege.
        vm.expectRevert(Unauthorized.selector);
        vm.prank(Robinhood.PROJECT_FACTORY, BINDER);
        desk.bind(address(escrow), hex"", hex"", 1, 1, 1, 0, 2);
        // The binder still cannot bypass the creation-code proofs.
        vm.expectRevert(InvalidProof.selector);
        vm.prank(BINDER);
        desk.bind(address(escrow), hex"", hex"", 1, 1, 1, 0, 2);
        assertEq(address(desk.registry()), address(0));
    }

    function _assertRuntime(address application) private view {
        bytes memory code = application.code;
        assertGt(code.length, 0);
        assertLe(code.length, 24_576);
        for (uint256 i; i < code.length; ++i) {
            uint8 op = uint8(code[i]);
            if (op >= 0x60 && op <= 0x7f) {
                i += op - 0x5f;
                continue;
            }
            assertTrue(op != 0xf4 && op != 0xf2 && op != 0xff, "forbidden opcode");
        }
    }
}
