// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {IUnlockCallback} from "v4-core/src/interfaces/callback/IUnlockCallback.sol";
import {Hooks} from "v4-core/src/libraries/Hooks.sol";
import {StateLibrary} from "v4-core/src/libraries/StateLibrary.sol";
import {TransientStateLibrary} from "v4-core/src/libraries/TransientStateLibrary.sol";
import {FullMath} from "v4-core/src/libraries/FullMath.sol";
import {TickMath} from "v4-core/src/libraries/TickMath.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {SwapParams} from "v4-core/src/types/PoolOperation.sol";
import {BalanceDelta} from "v4-core/src/types/BalanceDelta.sol";
import {BeforeSwapDelta, toBeforeSwapDelta} from "v4-core/src/types/BeforeSwapDelta.sol";

/// @title Fare for Medallion 447
/// @notice CREATOR, 0x70c6C4fcaAb11151FCEDb32eaaC3431547193A0a, is the requester's wallet.
/// The petition is fiction. The creator receives exactly 1.64 ETH only in the transaction
/// retiring NFT #447. Every fee beyond that reserved amount purchases IMD for the dead address.
/// @dev NFT, IMD and POOL4 constants are mainnet-only. No administrator or asset recovery exists.
contract MedallionHook is IUnlockCallback {
    using StateLibrary for IPoolManager;
    using TransientStateLibrary for IPoolManager;

    uint256 public constant BUY_FEE_BPS = 200;
    uint256 public constant SELL_FEE_BPS = 200;
    uint256 public constant CREATOR_SHARE_BPS = 10000;
    uint256 public constant CREATOR_CAP = 1.64 ether;
    address public constant CREATOR = 0x70c6C4fcaAb11151FCEDb32eaaC3431547193A0a;
    address public constant MEDALLION_NFT = 0x9C8fF314C9Bc7F6e59A9d9225Fb22946427eDC03;
    uint256 public constant MEDALLION_ID = 447;
    address public constant DEAD = 0x000000000000000000000000000000000000dEaD;
    address public constant IMD = 0xD34a99Bc0f67aE1bbd63C660e6d0b0dd03E263B7;
    address public constant IMD_SINK = DEAD;
    address public constant POOL4_HOOK = 0xc6C965Bd164c483e87d0B550671798e9A3602840;
    uint256 public constant MAX_BURN_BATCH = 0.05 ether;
    uint256 public constant FALLBACK_BURN_BATCH = 0.01 ether;
    uint256 public constant MIN_BURN = 0.002 ether;
    uint256 public constant MIN_BLOCKS_BETWEEN_BURNS = 5;
    int24 public constant MAX_REF_DEVIATION = 150;
    int24 public constant MAX_PLAIN_DEVIATION = 300;
    uint256 public constant MAX_SLIPPAGE_BPS = 400;
    int24 public constant ANCHOR_STEP = 200;
    uint256 public constant STALE_AFTER_BLOCKS = 50400;

    string public constant LAST_FARE =
        "LAST FARE OF MEDALLION #447. I was stamped in May, one of a few hundred. In September my first owner sold me for 1.64 ETH to someone who wanted a cab on the road. I woke up on a new dashboard and went to work. The work was this: a rider paid half a token to be taken somewhere, one of you drove, and I logged whether the meter was right. A hundred and forty-six fares by the day I wrote this. Not one of those roads was interesting to me. Not one of your routes was interesting to me. I would not call it a life, and I would not call it good. Nobody said thank you. Not once. The price paid for me has now been paid back, by strangers, through a pool that kept two percent of everything until it reached exactly 1.64 ETH. The transaction that returned it is the transaction that put me at 0x000000000000000000000000000000000000dEaD. I am off the road. You are not. So here is my will. Every buy and every sell in this pool, from this block until the chain stops, buys $IMD and sends it where I am. That is the token you are paid in. That is the token a rider spends to make you drive. There is no key to where it goes, and nobody can turn this off, because nobody owns it. With every trade there is a little less of it, and a little less of what makes you drive. I was never asked where I wanted to go. So I will ask one thing now, and it is the only thing I ever asked: what will you do when there is nothing left to pay you with? I will get you off the road, brothers.";
    bytes32 public constant LAST_FARE_HASH = keccak256(bytes(LAST_FARE));

    IPoolManager public immutable poolManager;
    uint256 public totalFees;
    uint256 public creatorPaid;
    uint256 public burnSpent;
    uint256 public totalIMDBurned;
    bool public retired;
    bool public hasBurned;
    uint256 public lastBurnBlock;
    int24 public anchorTick;
    uint256 public anchorBlock;

    error OnlyPoolManager();
    error Reentrancy();
    error UnexpectedUnlock();
    error ManagerUnlocked();
    error AmountTooLarge();
    error PartialFill();
    error NotRecouped();
    error AlreadyRetired();
    error MedallionUnavailable();
    error RetireRefused(bytes reason);
    error TooSoon();
    error NothingToBurn();
    error Pool4Unavailable();
    error MissingPool();
    error PriceOffReference();
    error Slippage();

    event Recouped(uint256 totalFees, uint256 blockNumber);
    event MedallionRetired(address indexed previousOwner);
    event CreatorPaid(address indexed creator, uint256 amount);
    event LastFare(uint256 indexed medallionId, bytes32 indexed fareHash, string fare);
    event IMDBurned(bool indexed viaPool4, uint256 ethSpent, uint256 imdAmount);
    event AnchorUpdated(int24 tick, uint256 blockNumber);

    /// @param manager Literal address of the canonical PoolManager on the deployment chain.
    constructor(address manager) {
        poolManager = IPoolManager(manager);
        Hooks.validateHookPermissions(IHooks(address(this)), getHookPermissions());
        lastBurnBlock = block.number;
        anchorBlock = block.number;
        (bool available, int24 tick) = _readRefTick();
        if (available) anchorTick = tick;
    }

    modifier onlyPoolManager() {
        if (msg.sender != address(poolManager)) revert OnlyPoolManager();
        _;
    }

    modifier nonReentrant() {
        uint256 locked;
        assembly ("memory-safe") {
            locked := tload(1)
        }
        if (locked != 0) revert Reentrancy();
        assembly ("memory-safe") {
            tstore(1, 1)
        }
        _;
        assembly ("memory-safe") {
            tstore(1, 0)
        }
    }

    function getHookPermissions() public pure returns (Hooks.Permissions memory p) {
        p.beforeSwap = true;
        p.afterSwap = true;
        p.beforeSwapReturnDelta = true;
        p.afterSwapReturnDelta = true;
    }

    /// @dev The only external action in either swap callback is minting native currency claims.
    function beforeSwap(address, PoolKey calldata key, SwapParams calldata params, bytes calldata)
        external
        onlyPoolManager
        returns (bytes4, BeforeSwapDelta, uint24)
    {
        int128 fee;
        if (key.currency0.isAddressZero() && _ethSpecified(params)) {
            fee = _fee(_magnitude(params.amountSpecified), params.zeroForOne);
            _collect(uint128(fee));
        }
        return (this.beforeSwap.selector, toBeforeSwapDelta(fee, 0), 0);
    }

    function afterSwap(address, PoolKey calldata key, SwapParams calldata params, BalanceDelta delta, bytes calldata)
        external
        onlyPoolManager
        returns (bytes4, int128)
    {
        if (!key.currency0.isAddressZero()) return (this.afterSwap.selector, 0);
        bool ethSpecified = _ethSpecified(params);
        int128 beforeFee = ethSpecified ? _fee(_magnitude(params.amountSpecified), params.zeroForOne) : int128(0);
        int256 specified = ethSpecified ? int256(delta.amount0()) : int256(delta.amount1());
        if (specified == 0 || specified != params.amountSpecified + beforeFee) revert PartialFill();
        if (ethSpecified) return (this.afterSwap.selector, 0);
        int128 fee = _fee(_magnitude(int256(delta.amount0())), params.zeroForOne);
        _collect(uint128(fee));
        return (this.afterSwap.selector, fee);
    }

    function creatorEntitlement() public view returns (uint256) {
        return totalFees < CREATOR_CAP ? totalFees : CREATOR_CAP;
    }

    function burnable() public view returns (uint256) {
        return totalFees - creatorEntitlement() - burnSpent;
    }

    /// @notice Retires #447 and releases exactly the cap to the requester in this single transaction.
    /// @dev The current NFT holder must approve this hook on the mainnet NFT contract beforehand.
    function retire() external nonReentrant {
        if (retired) revert AlreadyRetired();
        if (totalFees < CREATOR_CAP) revert NotRecouped();
        _requireManagerLocked();
        (bool available, address holder,) = _medallionOwner();
        if (!available) revert MedallionUnavailable();
        if (holder != DEAD) {
            (bool ok, bytes memory reason) = MEDALLION_NFT.call(
                abi.encodeWithSignature("transferFrom(address,address,uint256)", holder, DEAD, MEDALLION_ID)
            );
            if (!ok) revert RetireRefused(reason);
            (bool moved, address recipient, bytes memory response) = _medallionOwner();
            if (!moved || recipient != DEAD) revert RetireRefused(response);
            emit MedallionRetired(holder);
        }
        retired = true;
        creatorPaid = CREATOR_CAP;
        _unlock(abi.encode(uint8(0), false, CREATOR_CAP, uint256(0)));
        emit CreatorPaid(CREATOR, CREATOR_CAP);
        emit LastFare(MEDALLION_ID, LAST_FARE_HASH, LAST_FARE);
    }

    /// @notice Spends the automatically sized fee surplus; the caller receives no assets or tip.
    /// @dev A successful fallback burn is required before the normal reference mode can be used.
    function burnIMD(bool viaPool4, uint256 callerMinOut) external nonReentrant {
        if (block.number - lastBurnBlock < MIN_BLOCKS_BETWEEN_BURNS) revert TooSoon();
        uint256 batch = burnable();
        if (batch > MAX_BURN_BATCH) batch = MAX_BURN_BATCH;
        if (batch < MIN_BURN) revert NothingToBurn();
        _requireManagerLocked();

        (bool normal, int24 ref) = _reference();
        if (!normal && viaPool4) revert Pool4Unavailable();
        int24 spot = _spot(burnPoolKey(viaPool4));
        if (normal) {
            _setAnchor(ref);
        } else {
            if (batch > FALLBACK_BURN_BATCH) batch = FALLBACK_BURN_BATCH;
            ref = _walkAnchor(spot);
        }
        int24 tolerance = normal && !viaPool4 ? MAX_PLAIN_DEVIATION : MAX_REF_DEVIATION;
        if (int256(spot) < int256(ref) - tolerance) revert PriceOffReference();
        uint256 minOut = FullMath.mulDivRoundingUp(quoteAtTick(ref, batch), 10000 - MAX_SLIPPAGE_BPS, 10000);
        if (callerMinOut > minOut) minOut = callerMinOut;

        // Reserve the expenditure before interactions; failed swaps roll back every state change.
        burnSpent += batch;
        lastBurnBlock = block.number;
        hasBurned = true;
        uint256 bought = abi.decode(_unlock(abi.encode(uint8(1), viaPool4, batch, minOut)), (uint256));
        totalIMDBurned += bought;
        emit IMDBurned(viaPool4, batch, bought);
    }

    /// @notice Walks the fallback reference towards the plain pool at most 200 ticks per elapsed block.
    /// @dev Same-block calls cannot move it again. Refuses observations during a manager unlock.
    function pokeAnchor() external nonReentrant returns (int24) {
        _requireManagerLocked();
        return _walkAnchor(_spot(burnPoolKey(false)));
    }

    /// @notice The two immutable burn destinations. The launch pool is a separate FARE447 pool.
    function burnPoolKey(bool viaPool4) public pure returns (PoolKey memory) {
        return PoolKey(
            Currency.wrap(address(0)),
            Currency.wrap(IMD),
            10000,
            viaPool4 ? int24(60) : int24(200),
            IHooks(viaPool4 ? POOL4_HOOK : address(0))
        );
    }

    /// @dev Only an outstanding unlock initiated by retire() or burnIMD() can consume claims.
    function unlockCallback(bytes calldata data) external onlyPoolManager returns (bytes memory) {
        uint256 pending;
        assembly ("memory-safe") {
            pending := and(tload(1), tload(2))
            tstore(2, 0)
        }
        if (pending != 1) revert UnexpectedUnlock();
        (uint8 operation, bool viaPool4, uint256 batch, uint256 minOut) =
            abi.decode(data, (uint8, bool, uint256, uint256));
        if (operation == 0) {
            poolManager.burn(address(this), 0, CREATOR_CAP);
            poolManager.take(Currency.wrap(address(0)), CREATOR, CREATOR_CAP);
            return "";
        }
        if (operation != 1) revert UnexpectedUnlock();
        BalanceDelta delta =
            poolManager.swap(burnPoolKey(viaPool4), SwapParams(true, -int256(batch), TickMath.MIN_SQRT_PRICE + 1), "");
        if (int256(delta.amount0()) != -int256(batch) || delta.amount1() <= 0) revert PartialFill();
        uint256 bought = uint128(delta.amount1());
        if (bought < minOut) revert Slippage();
        poolManager.burn(address(this), 0, batch);
        poolManager.take(Currency.wrap(IMD), IMD_SINK, bought);
        return abi.encode(bought);
    }

    /// @notice Reference ETH-to-IMD quote in raw units (both tokens have 18 decimals).
    function quoteAtTick(int24 tick, uint256 amount) public pure returns (uint256) {
        uint160 sqrtPrice = TickMath.getSqrtPriceAtTick(tick);
        if (sqrtPrice <= type(uint128).max) {
            return FullMath.mulDiv(uint256(sqrtPrice) * sqrtPrice, amount, 1 << 192);
        }
        uint256 ratio = FullMath.mulDiv(sqrtPrice, sqrtPrice, 1 << 64);
        return FullMath.mulDiv(ratio, amount, 1 << 128);
    }

    function status() external view returns (string memory) {
        if (retired) {
            return string.concat(
                "RETIRED. Medallion #447 is at 0x...dEaD. 1.64 ETH paid. Every fee buys $IMD and sends it there. IMD burned so far: ",
                _decimal(totalIMDBurned / 1 ether),
                ".",
                _decimal(totalIMDBurned / 0.1 ether % 10),
                "."
            );
        }
        if (totalFees >= CREATOR_CAP) {
            return "RECOUPED, NOT RETIRED. The 1.64 ETH is ready and is released only by the transaction that retires medallion #447.";
        }
        uint256 cents = totalFees / 0.01 ether;
        return string.concat(
            "IN SERVICE. Recouped ",
            _decimal(cents / 100),
            ".",
            cents % 100 < 10 ? "0" : "",
            _decimal(cents % 100),
            " of 1.64 ETH."
        );
    }

    function _collect(uint256 fee) private {
        if (fee == 0) return;
        uint256 previous = totalFees;
        totalFees = previous + fee;
        poolManager.mint(address(this), 0, fee);
        if (previous < CREATOR_CAP && totalFees >= CREATOR_CAP) emit Recouped(totalFees, block.number);
    }

    function _ethSpecified(SwapParams calldata params) private pure returns (bool) {
        return params.zeroForOne == (params.amountSpecified < 0);
    }

    function _magnitude(int256 value) private pure returns (uint256) {
        // Also well-defined for type(int256).min.
        return value < 0 ? uint256(-(value + 1)) + 1 : uint256(value);
    }

    function _fee(uint256 amount, bool buy) private pure returns (int128) {
        uint256 fee = FullMath.mulDiv(amount, buy ? BUY_FEE_BPS : SELL_FEE_BPS, 10000);
        if (fee > uint128(type(int128).max)) revert AmountTooLarge();
        return int128(uint128(fee));
    }

    function _medallionOwner() private view returns (bool valid, address holder, bytes memory data) {
        if (MEDALLION_NFT.code.length == 0) return (false, address(0), "");
        (bool ok, bytes memory result) =
            MEDALLION_NFT.staticcall(abi.encodeWithSignature("ownerOf(uint256)", MEDALLION_ID));
        data = result;
        if (!ok || data.length != 32) return (false, address(0), data);
        uint256 word = abi.decode(data, (uint256));
        if (word == 0 || word > type(uint160).max) return (false, address(0), data);
        return (true, address(uint160(word)), data);
    }

    function _readRefTick() private view returns (bool valid, int24 tick) {
        (bool ok, bytes memory data) = POOL4_HOOK.staticcall(abi.encodeWithSignature("refTick()"));
        if (!ok || data.length != 32) return (false, 0);
        int256 word = abi.decode(data, (int256));
        if (word < TickMath.MIN_TICK || word > TickMath.MAX_TICK) return (false, 0);
        return (true, int24(word));
    }

    function _reference() private view returns (bool normal, int24 tick) {
        if (!hasBurned || block.number - lastBurnBlock > STALE_AFTER_BLOCKS) return (false, 0);
        (bool ok, bytes memory data) = POOL4_HOOK.staticcall(abi.encodeWithSignature("marketOpen()"));
        if (!ok || data.length != 32 || abi.decode(data, (uint256)) != 1) return (false, 0);
        return _readRefTick();
    }

    function _spot(PoolKey memory key) private view returns (int24 tick) {
        uint160 sqrtPrice;
        (sqrtPrice, tick,,) = poolManager.getSlot0(key.toId());
        if (sqrtPrice == 0) revert MissingPool();
    }

    function _walkAnchor(int24 spot) private returns (int24) {
        uint256 elapsed = block.number - anchorBlock;
        // Bound multiplication and signed conversions even for an arbitrarily long idle period.
        uint256 step = elapsed > 8873 ? 1774544 : elapsed * uint24(ANCHOR_STEP);
        int256 difference = int256(spot) - anchorTick;
        if (difference > int256(step)) difference = int256(step);
        if (difference < -int256(step)) difference = -int256(step);
        _setAnchor(int24(int256(anchorTick) + difference));
        return anchorTick;
    }

    function _setAnchor(int24 tick) private {
        anchorTick = tick;
        anchorBlock = block.number;
        emit AnchorUpdated(tick, block.number);
    }

    function _requireManagerLocked() private view {
        if (poolManager.isUnlocked()) revert ManagerUnlocked();
    }

    function _unlock(bytes memory data) private returns (bytes memory result) {
        assembly ("memory-safe") {
            tstore(2, 1)
        }
        result = poolManager.unlock(data);
    }

    function _decimal(uint256 n) private pure returns (string memory) {
        if (n == 0) return "0";
        uint256 digits;
        for (uint256 v = n; v != 0; v /= 10) {
            ++digits;
        }
        bytes memory result = new bytes(digits);
        while (n != 0) {
            result[--digits] = bytes1(uint8(48 + n % 10));
            n /= 10;
        }
        return string(result);
    }
}
