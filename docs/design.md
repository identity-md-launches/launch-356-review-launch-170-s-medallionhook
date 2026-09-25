# Accounting and lifecycle

`FareToken` and `MedallionHook` are independent contracts. The token never calls
the hook. There is no deployment token address argument: v4 identifies the pool
currencies in each callback. The PoolManager is an immutable trust boundary;
deploying with a counterfeit manager is outside the supported configuration.

## Swap fees

All calculations truncate fees to integer wei. The specified side is currency0
when `zeroForOne == (amountSpecified < 0)`.

| Trade | Specified asset | Fee base | Fee return |
| --- | --- | --- | --- |
| Exact-input buy | ETH input | User's specified ETH input | Positive specified beforeSwap delta |
| Exact-output sell | ETH output | User's specified ETH output | Positive specified beforeSwap delta |
| Exact-output buy | FARE447 output | Absolute raw pool ETH input | Positive unspecified afterSwap delta |
| Exact-input sell | FARE447 input | Raw pool ETH output | Positive unspecified afterSwap delta |

The before fee reduces pool input on an exact-input buy; for example a 1 ETH buy
sends 0.98 ETH into the pool and creates 0.02 ETH of claims. An exact-output sale
requesting 1 ETH makes the pool output 1.02 ETH; 0.02 ETH becomes claims and the
trader receives exactly 1 ETH. The LP swap fee is separate.

Every ETH-pool swap verifies the raw specified delta equals `amountSpecified +
beforeFee`, and is nonzero. A price limit or exhausted liquidity that prevents
full execution raises `PartialFill`; any pre-collected claims and events roll
back. Non-ETH pools return zero fees and do not acquire these fill restrictions.
The only external call in swap callbacks is `poolManager.mint(this, 0, fee)`.

```text
creatorEntitlement = min(totalFees, 1.64 ether)
burnable           = totalFees - creatorEntitlement - burnSpent
outstanding        = totalFees - creatorPaid - burnSpent
PoolManager.balanceOf(hook, 0) >= outstanding
creatorPaid        ∈ {0, 1.64 ether}
```

Only swaps increment `totalFees`. Donations of claims, forced ETH or direct ERC-20
transfers never create entitlement or burn budget and have no recovery path.
`Recouped(totalFees, block.number)` is emitted at the first cap crossing only.
A crossing trade may produce surplus, which becomes burnable immediately even
before retirement; the full creator reserve remains untouched.

## Retirement

`retire()` is permissionless, uses transient lock slot 1, and requires the manager
to be locked before starting its own unlock. It rejects an already retired hook
or an unrecouped cap. It reads `ownerOf(447)` by low-level staticcall and checks
code presence, successful execution, exactly one ABI word, a canonical address
and a nonzero owner. Unavailable data raises `MedallionUnavailable`.

If the owner is not DEAD, the hook calls `transferFrom(currentOwner, DEAD, 447)`.
Reversion becomes `RetireRefused(returndata)`. A second checked owner read must
show DEAD; otherwise `RetireRefused` aborts the transaction. A successful move
emits `MedallionRetired(previousOwner)`. Already-dead ownership skips transfer
and that event, allowing the cap to be paid without needing a dead-address approval.

The hook sets `retired` and `creatorPaid`, opens a manager unlock, burns exactly
the cap in claims and calls `take(ETH, CREATOR, CAP)`. It then emits `CreatorPaid`
and `LastFare(447, LAST_FARE_HASH, LAST_FARE)`. Any failed payment undoes the NFT
transfer and ledger changes. There is no partial creator payment or alternative
creator withdrawal method. Future NFT ownership behavior relies on the immutable
external NFT contract honoring ordinary ERC-721 transfer semantics.

The last fare is 1,470 bytes, with Keccak-256
`0xa0dafc7711f4bf93a220c7a34fdd211caffeaf1108947b0a7dfaf05abb081ece`.

## Burning and reference modes

The only selectable keys, in `(currency0, currency1, fee, tickSpacing, hooks)` order:

| Route | Fixed key |
| --- | --- |
| POOL4 | `(ETH, IMD, 10000, 60, POOL4_HOOK)` |
| Plain | `(ETH, IMD, 10000, 200, address(0))` |

`burnIMD` checks cooldown first (`TooSoon`), computes
`min(burnable, MAX_BURN_BATCH)`, then rejects a batch below `MIN_BURN`
(`NothingToBurn`). Subsequent guards require a top-level call with the manager
locked and an initialized selected pool.

Normal mode requires a prior successful burn no more than 50,400 blocks ago,
`marketOpen()` returning the canonical boolean true, and `refTick()` returning a
canonical signed tick within TickMath bounds. The POOL4 view calls use low-level
staticcall and exact return lengths, so missing code, reverts, malformed booleans,
bad lengths and out-of-range ticks lead to fallback instead of ABI decode panics.
Normal mode seeds the local anchor from the trusted reference.

Without those conditions, POOL4 routing raises `Pool4Unavailable`. Plain fallback
limits the batch to 0.01 ETH. It moves the local anchor toward the plain pre-swap
tick by `min(abs(spot-anchor), elapsedBlocks*200)`. Constructor seeding accepts a
valid POOL4 reference even if its market is closed. With no valid initial reference,
the anchor starts at zero and can walk from there. `pokeAnchor()` uses the same
bounded walk without spending. Calls in the same block have no additional movement
budget; failed burns roll back their attempted anchor update. Long idle periods
allow a correspondingly large catch-up. Neither mode is a manipulation-proof oracle.

The one-sided guard rejects only `spot < reference - tolerance`. Tolerance is
300 ticks for plain normal-mode burns and 150 ticks otherwise. Higher IMD-per-ETH
prices are favorable and are allowed. The quote uses TickMath and full-width
multiplication, without taking the absolute tick or inverting the ETH/IMD ratio.

```text
referenceQuote = floor(batch * priceAtReference)
minimumOutput  = max(callerMinOut, ceil(referenceQuote * 9600 / 10000))
```

The hook reserves `burnSpent` and cooldown before its own manager unlock, swaps
the fixed batch as exact input, verifies the full negative ETH delta and positive
IMD output, and enforces the minimum. It burns claims to settle its ETH debt and
asks the manager to send IMD directly to DEAD. A failed fill or transfer rolls
back every change. `totalIMDBurned` and `IMDBurned` report the output received by
the sink under the assumed ordinary IMD ERC-20 semantics.

Transient slot 1 protects top-level retirement, burns and anchor updates. Slot 2
is a single-use unlock capability, consumed before callback interactions.
`unlockCallback` requires both the manager caller and this outstanding capability.
There is no receive function or direct ETH payout in the hook.

## Constants

| Constant | Value |
| --- | --- |
| BUY_FEE_BPS / SELL_FEE_BPS | 200 / 200 |
| CREATOR_SHARE_BPS / CREATOR_CAP | 10000 / 1.64 ETH |
| CREATOR | `0x70c6C4fcaAb11151FCEDb32eaaC3431547193A0a` |
| MEDALLION_NFT / MEDALLION_ID | `0x9C8fF314C9Bc7F6e59A9d9225Fb22946427eDC03` / 447 |
| DEAD / IMD_SINK | `0x000000000000000000000000000000000000dEaD` |
| IMD | `0xD34a99Bc0f67aE1bbd63C660e6d0b0dd03E263B7` |
| POOL4_HOOK | `0xc6C965Bd164c483e87d0B550671798e9A3602840` |
| MAX_BURN_BATCH / FALLBACK_BURN_BATCH / MIN_BURN | 0.05 / 0.01 / 0.002 ETH |
| MIN_BLOCKS_BETWEEN_BURNS / STALE_AFTER_BLOCKS | 5 / 50400 |
| MAX_REF_DEVIATION / MAX_PLAIN_DEVIATION / ANCHOR_STEP | 150 / 300 / 200 ticks |
| MAX_SLIPPAGE_BPS | 400 |

`status()` displays the exact three specified sentences. Recoupment truncates to
two decimal places; IMD sent to the sink truncates to one. It never implies the
NFT retired merely because the fee cap was reached.
