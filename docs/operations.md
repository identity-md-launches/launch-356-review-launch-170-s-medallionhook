# Deployment and operation

The repository supplies source, ABI exports, tests and a manifest. It does not
submit transactions. The independent release operator is responsible for chain
selection, matching the canonical manager, mining the CREATE2 salt, supplying
liquidity and obtaining a separate security review before production use.

`launch.json` uses the published `univ4_hook` manifest shape: `kind`, `hook`,
`token`, `pool`, `notes`; hook permissions are names, not an extra numeric field.
For comparison, see the published
[Tollgate manifest](https://github.com/identity-md-launches/launch-168-release-tollgate-symbol-toll/blob/main/launch.json).
No canonical schema file was supplied with this assignment, so the local artifact
check verifies these fields and their correspondence to the compiled ABI; it does
not claim independent launcher admission.

The selected literal manager is Sepolia's
`0xE03A1074c86CFeDd5C142C4F04F1a1536e203543`. Mainnet would instead use
`0x000000000004444c5dc75cB358380D2e3dE08A90` in a separately reviewed manifest.
These addresses were checked against the
[official deployment list](https://developers.uniswap.org/docs/protocols/v4/deployments)
on 2026-09-25. The mainnet NFT, IMD and POOL4 addresses are the task's fixed
constants. Their current mainnet state and behavior were not queried by the tests.

## Release sequence

1. Rebuild offline with the pinned compiler and run the documented checks.
2. Confirm the chosen PoolManager and the intended chain. Constructor arguments
   must be a single literal address, with no `$token`, `$owner` or replacement
   oracle/NFT/token parameter. `FareToken` takes no arguments.
3. Mine the hook deployment salt against the actual deployment factory and
   `keccak256(creationCode || abi.encode(manager))`. The low 14 bits of
   `keccak256(0xff || factory || salt || initCodeHash)` must be `0x00CC` after
   truncation to an address. Constructor validation must remain enabled. The
   tests demonstrate the CREATE2 search and deployment, without overriding checks.
4. Verify the resulting token and hook runtime against the rebuilt artifacts,
   accounting for the immutable manager address. Confirm token supply and holder,
   permission mask and `LAST_FARE_HASH` before opening the pool.
5. Initialize ETH/FARE447 with LP fee 3000, spacing 60 and the manifest price.
   The price assumption is 1,000,000 FARE447 per ETH. The operator chooses actual
   liquidity ranges and amounts; no initialization or liquidity callback restricts
   the operator or ordinary LP withdrawals. Factory allocation policy is external
   to this manifest.
6. On mainnet, the current owner of NFT #447 approves the exact deployed hook for
   that NFT. After recoupment, any caller can execute `retire()`. Approval may be
   revoked before retirement; in that case funds remain reserved until it is restored.
   The payout always goes to CREATOR even if the NFT changed hands beforehand.

## Keeper responsibilities

No privileged keeper exists and no one is paid to call maintenance. Callers fund
their own gas. They should inspect `burnable`, `lastBurnBlock`, `hasBurned`,
`anchorTick`, `anchorBlock` and the two fixed pools before submitting a burn.
`callerMinOut` can only strengthen the quote floor. There is no batch-size argument.

The first burn uses plain fallback. A missing, closed, malformed or stale POOL4
reference also requires plain fallback, with a smaller batch. If the anchor is
too far above the current plain price, a keeper can call `pokeAnchor()` as blocks
pass without spending the surplus. Poking cannot run during an unlocked manager
transaction, which excludes observations inside a v4 flash settlement. It does
not exclude persistent manipulated spot prices or sandwiches across transactions.

Burning after the cap can proceed before retirement and cannot consume its reserve.
Normal burns can resume after a successful fallback burn if POOL4's views are
available and open. Neither deployment nor failed burns count as a successful burn
for reference freshness. Batches below the minimum remain until more fees arrive.

## Operational limits

- Sepolia deliberately retains the mainnet constants: no real NFT retirement or
  IMD burning is available there. After applicable guards, `MedallionUnavailable`,
  `Pool4Unavailable` or `MissingPool` is expected. Test mocks are never deployed
  through the manifest.
- A missing NFT approval, refusing NFT transfer or rejected creator ETH receipt
  makes retirement revert atomically; there is no administrative escape hatch.
- Burn pools must be initialized and sufficiently liquid for the fixed batch and
  minimum output. Low liquidity, partial fills, depleted pools or transfer failures
  can delay burning indefinitely. The batch cannot be reduced by a caller.
- The spot anchor and POOL4 reference are assumptions, not independently proven
  price oracles. The allowed rate of anchor catch-up accumulates during inactivity.
- Direct token, claim and forced native-ETH donations are unrecoverable and do not
  change recorded fees. Do not send assets directly to the hook as a funding method.
- Dead-address transfers are irreversible under the assumed NFT/ERC-20 semantics.
  The hook has no owner, setter, pause, upgrade, external call executor or sweep.

Mainnet production release still needs an independent contributor's adversarial
review and a fork rehearsal of the real NFT approval/transfer, IMD transfers,
POOL4 views and pool liquidity. This assignment's offline mocks establish the
hook's responses, not those external contracts' live behavior.
