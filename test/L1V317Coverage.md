# BLACKOUT v3.17 L1 regression coverage

This suite supplements the existing contributor tests without changing source or configuration.
`LaunchL1V317.t.sol` already checks the exact eight constructor words, creation hashes,
Robinhood chain ID, and Desk/escrow deployment in one factory call at indices 0 and 1.

The additional suites cover:

- `L1BindingFailuresV317.t.sol`: caller versus transaction-origin authority, all invalid bind
  coordinate fields, unrecorded L2 launches, each pool-record pairing mismatch, single-byte
  mutations of pinned creation code, missing Params runtime, and a successful retry after rejection.
  A failed bind must preserve every binding coordinate and leave the canonical binding available.
- `L1CustodyV317.t.sol`: factory-address constructor rejection, empty and one-wei exits,
  invalid forward coordinates, failed transfers with successful retry, callback reentrancy,
  foreign-token isolation, and absence of token allowances.
- `L1EscrowInvariantV317.t.sol`: 256 runs of 64 randomly ordered handler calls across two actors.
  Independent deposit and exit ledgers must equal escrow custody and RewardPool receipts.
  Forwarding remains one-shot, including after late deposits, failures and transfer callbacks.
- `L1DeskInvariantV317.t.sol`: 128 runs of 64 randomly ordered handler calls across two actors.
  Donations equal remaining custody plus oracle payments. Invalid prices/bodies, transfer
  failures, authentic failure callbacks and expiry cannot refund or reopen a paid slot;
  the intake allowance returns to zero. Time advances through both stream periods.

Both invariant suites include deterministic handler sequences that exercise successful value
movement and failure recovery. Unexpected handler reverts fail the campaigns; expected failures
are checked by their revert reasons. Fuzz counts are inline, so the unchanged repository
configuration is sufficient.

These are offline integration tests using the repository's local platform-record and ERC20/intake
models with real pinned application contracts. Their launch numbers are fixture coordinates,
not deployed launch outputs. Live Robinhood factory records, oracle service delivery and actual
launch addresses still require the existing opt-in fork/deployment rehearsal. No transaction is
broadcast and no RPC or key is required by these suites.
