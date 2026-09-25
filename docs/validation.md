# Local validation — 2026-09-25

The final delivered suite contains **57 passing tests**, with zero failures or
skips, across six suites. Four fuzz properties run 1,000 cases each. Three stateful
invariants run 128 sequences of depth 64 each (8,192 handler calls per property),
with `fail_on_revert = true` and zero handler reverts.

| Command | Result |
| --- | --- |
| `forge clean` then `forge build --offline` | Pass; 76 source files compiled from vendored dependencies |
| `forge test --offline` | 57 passed, 0 failed, 0 skipped |
| `forge fmt --check` | Pass |
| `python3 docs/check_artifacts.py` | Pass; 55 compiled contracts scanned |
| Supplied hook protected tests | 3 passed |
| Supplied token protected tests | 6 passed |

Foundry 1.7.1; native solc `0.8.26+commit.8a97fa7a`; Cancun; optimizer enabled,
200 runs; `via_ir = false`; `bytecode_hash = "none"`; `cbor_metadata = false`.
Foundry's cast and test-transfer lint advisories remain nonfatal. Production
narrowing conversions were checked against their sign/range guards in the local
math review and boundary tests.

The protected tests were copied into temporary scratch files with import paths
adapted to the local helper and mock locations; test bodies were unchanged apart
from formatting. The hook creation code included the manifest's literal Sepolia
PoolManager argument; the token code had no arguments. Declared flags were 204 and
decimals 18. The tests deployed the actual creation bytecode, including CREATE2
permission validation. Their output is in [protected-checks.txt](protected-checks.txt).
The temporary copies were removed afterward so ordinary tests need no environment
variables. These are local reruns, not an independent verifier's attestation.

| Artifact | Runtime size | Constructor |
| --- | --- | --- |
| FareToken | 1,738 bytes | No arguments |
| MedallionHook | 12,613 bytes | One address |

Both are below EIP-170. The artifact checker walks creation and runtime bytecode
of every compiled contract, skipping PUSH operands, and finds zero `F2`, `F4` or
`FF` instructions. It checks compiler settings, ABI exports, manifest field
shape, the literal constructor argument, permitted callback names, note length,
pool parameters and v4-core 1.0.2. It does not substitute for the launcher's schema
or admission service, whose canonical schema was not provided.

## Coverage

- `FareToken.t.sol`: exact supply and metadata, transfers, allowances, burns,
  rollback, forbidden privilege selectors, supply conservation and opcode walk.
- `MedallionHook.t.sol`: all four fee directions, no external payouts in swaps,
  partial fills, fee-free non-ETH pools, donation accounting, cap crossing and
  one-time event, exact status strings, pinned fare text/hash, unauthorized
  callers, NFT unavailability/refusal/false transfer, approval, atomic payout,
  rejected payment, reentrancy, both burn modes, fixed pools and batch sizing,
  cooldown/minimum order, stale/malformed references, favorable price direction,
  quote floors, partial burn fills and anchor rate limiting.
- `RealPool.t.sol`: unmodified local v4-core PoolManager, CREATE2-deployed hook,
  real FARE447 and mocked mainnet counterparties. Initialization, liquidity,
  all four settled trades, all four raw partial fills, reserve/claim donations,
  retirement and both IMD burn routes, non-ETH pools, single-sided first trade,
  withdrawal, top-level restrictions and the manifest's initial price. Every
  completed unlock has zero outstanding manager deltas.
- `MathBoundary.t.sol`: extreme signed amounts, complete tick-range anchor walks,
  same-block immobility, monotone quotes and the quote formula's precision branch.
- `LedgerInvariant.t.sol`: mixed swaps, claim donations, burns and retirement.
  Ghost accounting verifies fees only arise from swaps; claims cover every
  obligation; creator payment is zero or the cap with the NFT retired; burn
  amounts equal sink receipts and never consume the creator reserve.

## Advisory review and remaining external validation

Three separate local review contexts covered twelve consolidated specialties:
math/precision/invariants/boundaries; access/execution/periphery/flow; and
economics/first principles/asymmetry/trust. They reported no concrete actionable
findings or unresolved exploit leads in the two production contracts. Their
focused test runs passed; the added math boundary tests are retained in the
delivered suite. Completeness: zero raw finding/lead function groups, zero omitted.
These reviews are advisory and are not independent IdentityMD contributor receipts.

There was no fork, live NFT approval, external liquidity check, or deployment.
The mainnet dependency addresses, NFT holder/approval behavior, ordinary IMD
transfer semantics, and POOL4 reference meaning need a separate mainnet rehearsal.
The local mocks deliberately model both successful and refusing counterparties;
they are not evidence that the live counterparts will succeed.

The required fallback anchor follows spot over time and allows accumulated idle
blocks to move it substantially. Its 96% floor protects relative to that resulting
reference; it is not a manipulation-resistant oracle. Missing pools, liquidity or
NFT approval can leave recorded obligations pending indefinitely. Those specified
constraints and the absence of an administrative recovery path remain unchanged.
