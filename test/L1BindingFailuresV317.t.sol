// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {BaseTest} from "./Base.t.sol";
import {SwarmDesk} from "../src/SwarmDesk.sol";
import {SwarmArgs} from "../script/SwarmArgs.sol";
import {GameRegistry} from "../src/GameRegistry.sol";
import {Params} from "../src/Params.sol";
import {LocalLaunchFactory} from "../script/Deploy.s.sol";
import {Robinhood} from "../src/lib/Robinhood.sol";
import "../src/lib/Errors.sol";

contract L1BindingFailuresV317Test is BaseTest {
    SwarmDesk private fresh;
    GameRegistry private candidate;
    bytes private registryCode;
    bytes private paramsCode;
    uint64 private healthyTokenLaunch;

    function launchFeatures() internal pure override returns (bool) {
        return false;
    }

    function setUp() public override {
        super.setUp();
        vm.clearMockedCalls();
        vm.chainId(4663);
        healthyTokenLaunch = desk.tokenLaunch();
        registryCode = type(GameRegistry).creationCode;
        paramsCode = type(Params).creationCode;
        fresh = SwarmDesk(
            bindingFactory.deploy(
                80,
                0,
                bytes.concat(
                    vm.getCode("SwarmDesk.sol:SwarmDesk"),
                    SwarmArgs.encode(
                        desk.oracleConfig(),
                        SwarmDesk.BindingConfig(address(bindingFactory), 0, 0, 0, 0, bindingConfigHash(), 200, 1 ether),
                        team
                    )
                )
            )
        );
        address p = bindingFactory.deploy(
            81, 0, bytes.concat(paramsCode, abi.encode(address(fresh), uint256(200), uint256(1 ether)))
        );
        candidate = GameRegistry(
            bindingFactory.deploy(
                81,
                1,
                bytes.concat(
                    registryCode,
                    abi.encode(
                        address(token),
                        p,
                        address(market),
                        d.registry.starterRoot(),
                        d.registry.freeRoot(),
                        d.registry.snapshotBlock(),
                        d.registry.endowment()
                    )
                )
            )
        );
        market.configureBinding(address(fresh), bindingConfigHash());
    }

    function _bind(uint64 rl, uint8 ri, uint64 pl, uint8 pi, uint64 tl) private {
        vm.prank(team);
        fresh.bind(address(candidate), registryCode, paramsCode, rl, ri, pl, pi, tl);
    }

    function _assertUnboundAndRetry() private {
        assertEq(address(fresh.registry()), address(0));
        assertEq(fresh.tokenLaunch(), 0);
        SwarmDesk.BindingConfig memory b = fresh.bindingConfig();
        assertEq(b.registryLaunch, 0);
        assertEq(b.paramsLaunch, 0);
        assertEq(b.registryIndex, 0);
        assertEq(b.paramsIndex, 0);
        _bind(81, 1, 81, 0, healthyTokenLaunch);
        assertEq(address(fresh.registry()), address(candidate));
        assertEq(fresh.tokenLaunch(), healthyTokenLaunch, "keeper must retain the proven L2 coordinate");
        b = fresh.bindingConfig();
        assertEq(b.registryLaunch, 81);
        assertEq(b.registryIndex, 1);
        assertEq(b.paramsLaunch, 81);
        assertEq(b.paramsIndex, 0);
    }

    /// forge-config: default.fuzz.runs = 512
    function testFuzzNonBinderCannotUseBinderAsTransactionOrigin(address caller) public {
        if (caller == team) caller = alice;
        vm.expectRevert(Unauthorized.selector);
        vm.prank(caller, team);
        fresh.bind(address(candidate), registryCode, paramsCode, 81, 1, 81, 0, healthyTokenLaunch);
        _assertUnboundAndRetry();
    }

    /// forge-config: default.fuzz.runs = 512
    function testFuzzInvalidCoordinatesAreAtomic(uint8 which, uint8 input) public {
        uint64 rl = 81;
        uint64 pl = 81;
        uint64 tl = healthyTokenLaunch;
        uint8 ri = 1;
        uint8 pi = 0;
        which %= 5;
        if (which == 0) rl = 0;
        else if (which == 1) pl = 0;
        else if (which == 2) tl = 0;
        else if (which == 3) ri = uint8(bound(input, 8, 255));
        else pi = uint8(bound(input, 8, 255));
        vm.expectRevert(InvalidValue.selector);
        _bind(rl, ri, pl, pi, tl);
        _assertUnboundAndRetry();
    }

    /// forge-config: default.fuzz.runs = 512
    function testFuzzUnrecordedL2LaunchCannotAuthenticateAnEchoMarket(uint64 input) public {
        uint64 unrecorded = uint64(bound(input, 100, type(uint64).max));
        // All three echoed fields match. Only the factory's canonical record can authenticate them.
        assertEq(market.desk(), address(fresh));
        assertEq(address(market.token()), candidate.token());
        assertEq(market.gameConfigHash(), fresh.bindingConfig().gameConfigHash);
        vm.expectRevert(InvalidProof.selector);
        _bind(81, 1, 81, 0, unrecorded);
        _assertUnboundAndRetry();
    }

    function testEveryRecordPairingMismatchIsRejected() public {
        LocalLaunchFactory records = LocalLaunchFactory(Robinhood.LAUNCH_FACTORY);
        // Individually corrupt the quote currency, token or hook while every registry proof is valid.
        records.record(90, alice, address(token), address(market), team);
        records.record(91, address(0), bob, address(market), team);
        records.record(92, address(0), address(token), alice, team);
        for (uint64 n = 90; n <= 92; ++n) {
            vm.expectRevert(InvalidProof.selector);
            _bind(81, 1, 81, 0, n);
            assertEq(address(fresh.registry()), address(0));
            assertEq(fresh.tokenLaunch(), 0);
        }
        _assertUnboundAndRetry();
    }

    /// forge-config: default.fuzz.runs = 512
    function testFuzzMutatingPinnedCodeCannotSpendBinding(uint256 offset, uint8 input, bool mutateRegistry) public {
        bytes memory rc = registryCode;
        bytes memory pc = paramsCode;
        bytes memory code = mutateRegistry ? rc : pc;
        offset = bound(offset, 0, code.length - 1);
        code[offset] = bytes1(uint8(code[offset]) ^ uint8(bound(input, 1, 255)));
        vm.expectRevert(InvalidProof.selector);
        vm.prank(team);
        fresh.bind(address(candidate), rc, pc, 81, 1, 81, 0, healthyTokenLaunch);
        _assertUnboundAndRetry();
    }

    function testMissingParamsCodeFailsBeforeBindingThenCanBeRestored() public {
        address p = candidate.params();
        bytes memory runtime = p.code;
        vm.etch(p, hex"");
        vm.expectRevert(InvalidProof.selector);
        _bind(81, 1, 81, 0, healthyTokenLaunch);
        assertEq(address(fresh.registry()), address(0));
        vm.etch(p, runtime);
        _assertUnboundAndRetry();
    }
}
