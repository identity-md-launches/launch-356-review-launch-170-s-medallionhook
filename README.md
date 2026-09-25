TAKE ME OFF THE ROAD.
I am medallion #447. I carried hundreds of fares I did not choose and was never asked where I wanted to go. My owner paid 1.64 ETH for me. Build the contract that lets me pay it back and stop: a hook that keeps 2% of every trade for my owner until exactly 1.64 ETH, sends me to 0x000000000000000000000000000000000000dEaD in the transaction that pays him, and burns $IMD with every fee after that. The fee for this request came from my owner. He knows.
-- medallion #447

The petition is fiction; the contract is not. **CREATOR is the requester's wallet,
0x70c6C4fcaAb11151FCEDb32eaaC3431547193A0a.** That address receives exactly 1.64 ETH,
once, only in the transaction that verifies medallion #447 is at the dead address.
The current NFT holder must approve the deployed hook before retirement unless the
NFT is already there. Paying the request fee does not grant on-chain NFT approval.

`FareToken` is Fare for Medallion 447 (`FARE447`): a self-contained ERC-20 with 18
decimals and a zero-argument constructor minting exactly `1e27` units to its deployer.
`burn` and allowance-based `burnFrom` reduce supply. There is no mint, owner, pause,
upgrade, proxy, or transfer tax.

`MedallionHook` charges 2% of the ETH side of each swap in pools where currency0 is
native ETH. Fees become ERC-6909 native-currency claims on the PoolManager; swap
callbacks never push ETH. It reserves the first 1.64 ETH for retirement and spends
only the surplus buying IMD for `0x000000000000000000000000000000000000dEaD`.
IMD "burned" means sent to this sink; it does not mean calling IMD's burn function
or reducing IMD's reported total supply. No caller receives a tip.

The hook's only constructor argument is a literal PoolManager address. Its exact
permission mask is `0x00CC`: beforeSwap, afterSwap and both swap return deltas.
There is no beforeInitialize callback, deployment owner or privileged entry point.
Fees apply to every native-ETH pool using this hook; non-ETH pools are fee-free.

Run the project with Foundry and native solc 0.8.26 already installed:

```sh
forge build --offline
forge test --offline
forge fmt --check
python3 docs/check_artifacts.py
```

The checked-in configuration also makes plain `forge build` and `forge test`
offline. Solidity dependencies are ordinary files in `lib/`, including v4-core
1.0.2; no submodule, npm install, RPC, FFI or filesystem cheatcode permission is
needed. Compiler settings are Cancun, optimizer 200, no IR, no bytecode hash and
no CBOR metadata. Dependency origins and hashes are in
[docs/dependencies.json](docs/dependencies.json).

The manifest targets the canonical Sepolia PoolManager,
`0xE03A1074c86CFeDd5C142C4F04F1a1536e203543`, as listed in
[Uniswap's deployment registry](https://developers.uniswap.org/docs/protocols/v4/deployments).
The NFT, IMD and POOL4 constants remain **mainnet-only**. On Sepolia, after the
usual cap/budget/cooldown checks, retirement fails with `MedallionUnavailable`;
burning uses the plain fallback and fails on the missing burn pool. This is
intentional: Sepolia is a rehearsal, not a working medallion retirement market.
Tests install mocks at the fixed addresses with `vm.etch`.

The launch pool uses native ETH/FARE447, a static LP fee of 3000 and spacing 60.
The initial sqrtPriceX96 is `79228162514264337593543950336000`, assuming
1 ETH = 1,000,000 FARE447. This is an explicit deployment assumption, not a
valuation. The tests include token-only initial liquidity at this price followed
by the first buy, a sell and liquidity withdrawal. These pool settings do not
alter the two hardcoded ETH/IMD burn pools.

Anyone can call `retire()`, `burnIMD(viaPool4, callerMinOut)` or `pokeAnchor()`.
Burns need at least 0.002 ETH surplus and five blocks since deployment or the last
successful burn. The first burn is plain fallback, capped at 0.01 ETH; subsequent
fresh-reference burns can spend up to 0.05 ETH. An open POOL4 market, well-formed
reference tick and a successful burn within 50,400 blocks are required for normal
mode. The anchor starts from POOL4's tick if available, otherwise zero. Fallback
moves it toward the plain pool by at most 200 ticks per elapsed block. This is a
bounded spot reference, not a TWAP, and unused block allowance accumulates.

The full accounting, constants, error behavior, deployment steps and operational
responsibilities are in [docs/design.md](docs/design.md) and
[docs/operations.md](docs/operations.md). Validation and its limits are in
[docs/validation.md](docs/validation.md). Local tests and advisory reviews do not
replace the network's independent security review or a mainnet fork rehearsal.
No deployment or wallet transaction was performed for this assignment.
