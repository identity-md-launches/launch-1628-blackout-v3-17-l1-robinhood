# BLACKOUT v3.17 L1 adaptation

Baseline: `identity-md-launches/launch-1544-blackout-swarmdesk-bootstrap-robinhood`
commit `e17f0ef7bd7d188949eb4dc91e3eb0540c94cbf3`.
Target: Robinhood Chain, chain ID **4663**. Project: https://playblackout.xyz.

## Scope and changes

No production source, deployment script, keeper code, generated pin, dependency or build
configuration changed. The existing constructors already satisfy this `evm_contracts`
launch. The unchanged `foundry.toml` uses Solidity 0.8.26, optimizer 200, Cancun,
`via_ir = false`, and `bytecode_hash = "none"`.

| File | Change and reason |
| --- | --- |
| `README.md` | Add the missing `out-launch/` build before pin checks (import finding `595725a2`); explain the role-1 intake prerequisite (finding `1caeadee`) and link the current v3.17 runbook. |
| `docs/accepted-v317.md` | Correct the two early-answer descriptions to match the reproduced code behavior, including the paid-backup fee and retry limits. Preserve the accepted behavior and source hashes. |
| `launch-v39.md` | Apply the same intake correction to every repeated objective and the operator sequence; include both artifact-build commands. Constructor inputs, hashes, deployment order and binder proofs are unchanged. |
| `test/LaunchIntakeV317.t.sol` | Four regression tests using a real, factory-deployed and bound registry with unregistered roles. Cover stream-0 rejection and later relay, paid callback failure/expiry/fee retention, successful 200,000-gas intake after role 1 registration, and regulator storage before role 1. |
| `test/LaunchL1V317.t.sol` | Rehearse both exact L1 contracts in one factory call on chain ID 4663 without protocol code. Assert creation hashes, eight Desk words, same-launch escrow reference, CREATE2 predictions, runtime limits/opcodes, binder identity and rejection of unauthorized or unproven binding. |
| `ADAPTATION.md` | Record the bounded adaptation, audit reproductions, validation and deployment handoff. |

## Imported audit disposition

**`1caeadeeae05db6542a9873a910a64b77abbf42f9f1fb390d39db0f6d4f278f9` — reproduced.**
`SwarmDesk._accept` reads `registry.module(1)` for stream 0. An unregistered role
reverts `NotConfigured`; no answer or consumed UUID is retained. The regression
uses the actual `GameRegistry.module` implementation, without mocking that revert.
A validly signed answer is accepted unchanged after the real FarmRewards is deployed
and registered, while its slot/epoch/freshness conditions still pass.

The paid-backup reproduction buys the request, then exercises the intake's actual
200,000-gas callback wrapper. Failure leaves the pending entry and paid fee intact;
`clearExpired` does not refund the fee or permit a second purchase in the same slot.
The same signed bytes can subsequently be relayed if still available and valid.
The positive callback test succeeds with the same gas stipend once role 1 exists.
Stream 1 can store before role 1, but execution still needs its modules.

Resolution: use the audit's documentation-correction option, consistent with the
explicit **NO SOURCE CHANGES** requirement and the supplied creation hashes.
Register and verify role 1 before stream-0 submission or backup purchase. Keepers
defer execution until wiring completes and must respect answer expiry. This corrects
the inaccurate claim that early stream-0 answers stay stored; it does not change intake.

**`595725a2d7eb18af074e458b8fb807928a1fbfbe3496a85d696e7e3a7e910a` — reproduced.**
Both original `--check` commands failed with `FileNotFoundError` for
`out-launch/RewardPool.sol/RewardPool.json` and
`out-launch/GameRegistry.sol/GameRegistry.json`, respectively. Plain `forge build`
targets `out/`. The corrected sequence explicitly builds the second artifact directory
using the same configuration before either pin checker runs:

```sh
forge build
forge build --out out-launch --cache-path cache-launch
python3 tools/pin_module_code.py --check
python3 tools/pin_swarm_code.py --check
forge test
```

No imported finding was dismissed as non-reproducible. No accepted gameplay finding
was used to change source or regenerate pins.

## L1 handoff

The platform manifest/deployment step must deploy exactly this pair in **one**
`evm_contracts` launch. Creation hashes below exclude constructor arguments.

| Index | Contract | Creation hash | Constructor arguments |
| --- | --- | --- | --- |
| 0 | `SwarmDesk` | `0x1d8e1afa90ba7a4c436fa2406f52743c97f7e6d9add372516144cadcb0795879` | The eight ordered words below. |
| 1 | `EndowmentEscrow` | `0xe7a48446223ad53d50a9a9372c5552b70fb94e4f03c0f9f45298f7e5d2036368` | `["$contract:SwarmDesk"]` from index 0 of this launch. |

```text
["0x6f7261636c652e72657175657374406f7261636c652d31000000000000000000",
 "5391989333430298100116863486635657822062725418115979424500284366258177",
 "0x2fc5a57f2c5f7bc083ea8ac5016234f1a0b1c68a514e5d921956cc57948534ef",
 "0xc13efed8438aab53ea052a4507def2dc4ce9856765520dfa28c66daa59cfc11d",
 "0x00e69e4445c7ca7256338293f9f9cea439fd2beb1959d1d43ebec7b14493e2f6",
 "0xc0ae7511b06744cf7ccadc6b60ff9ff96cb7234cf32988850df33324861cc8df",
 "0x11ed7438974e96ecc962201e9c46422c7bf239d725876863fa25a56c734b20d3",
 "0x6d51cBE774aeAe4dd40bCA2560E9bc2695A0d007"]
```

The last word is the project wallet/binder, never the factory, a protocol endpoint
or transaction origin. All protocol endpoints remain compiled in. No token, hook,
pool, initializer or extra application is added to L1.

After deployment the platform returns **both recorded addresses**, indices **0/1**,
and their **single shared L1 launch number**. Those outputs do not exist in this
source-adaptation task and are not invented here. No manifest, production transaction,
signature or deployment receipt is produced by this work; all test coordinates and
test keys are confined to offline fixtures.

Keep the recorded L2 launch number `N_TOKEN` alongside the L1 and L3 outputs in
the keeper's `wiring.tokenLaunch`. After L3, only
`0x6d51cBE774aeAe4dd40bCA2560E9bc2695A0d007` signs:

```text
bind(REGISTRY, registryCreationCode, paramsCreationCode, N_A, 1, N_A, 0, N_TOKEN)
```

The existing `LaunchFactory.positionOf(N_TOKEN)` proof must name the registry's
token and market hook, in addition to the pinned registry/Params/configuration
proofs. An echo-only market cannot satisfy that record. Confirm `Desk.registry()`,
`Desk.tokenLaunch()`, and each registered module against the recorded outputs before
forwarding the escrow's complete remainder once to the proven RewardPool.

## Validation

- `forge build`: passed with the unchanged repository configuration.
- `forge test`: **320 passed, 0 failed, 6 skipped** across 56 suites (326 total
  tests), including all five new regressions. The invariant campaign passed at the
  repository's 128 runs / depth 64 (8,192 handler calls). The six skipped tests are
  the opt-in fork tests.
- `forge build --out out-launch --cache-path cache-launch`: passed. The L1 creation
  bytes in `out/` and `out-launch/` are identical and match both requested hashes.
- `python3 tools/pin_module_code.py --check`: passed for all fourteen modules in
  both artifact directories, including their EIP-170 runtime bounds.
- `python3 tools/pin_swarm_code.py --check`: passed for the registry and Params pins.
- `python3 tools/check_v37_authority.py`: passed.
- `node tools/check_deploy_gate.mjs docs/launch-v314-plan.json`: passed for all
  nineteen constructors in the existing multi-stage plan. Only the two L1 entries
  belong to this assignment's launch.
- ABI inspection confirms nonpayable static constructors (eight words / one word)
  with no library link references. Runtime sizes: SwarmDesk **22,226 bytes**;
  EndowmentEscrow **5,008 bytes**. The single-call deployment regression also passes
  the supplied floor's opcode scan and runtime-size conditions.
- `forge fmt --check test/LaunchL1V317.t.sol test/LaunchIntakeV317.t.sol` and
  `git diff --check`: passed.
- Baseline comparison confirms no changes to `src/`, `launch/`, `script/`,
  dependencies or protected build configuration.

Local tests are evidence for review, not deployment receipts or independent
attestations. No network, live fork, Slither or Mythril run is claimed here; opt-in
fork tests need their separate environment and were not enabled.
