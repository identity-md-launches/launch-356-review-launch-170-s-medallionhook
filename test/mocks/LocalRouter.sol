// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {IUnlockCallback} from "v4-core/src/interfaces/callback/IUnlockCallback.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {BalanceDelta} from "v4-core/src/types/BalanceDelta.sol";
import {SwapParams, ModifyLiquidityParams} from "v4-core/src/types/PoolOperation.sol";

interface ITransferToken {
    function transfer(address to, uint256 amount) external returns (bool);
}

/// @dev Test-only router funded by the test. Settles every real v4 delta in each unlock.
contract LocalRouter is IUnlockCallback {
    IPoolManager public immutable manager;

    constructor(IPoolManager m) {
        manager = m;
    }
    receive() external payable {}

    function swap(PoolKey memory key, SwapParams memory params) external returns (BalanceDelta) {
        return abi.decode(manager.unlock(abi.encode(uint8(0), key, abi.encode(params))), (BalanceDelta));
    }

    function liquidity(PoolKey memory key, int24 lower, int24 upper, int256 amount) external returns (BalanceDelta) {
        return abi.decode(
            manager.unlock(
                abi.encode(uint8(1), key, abi.encode(ModifyLiquidityParams(lower, upper, amount, bytes32(0))))
            ),
            (BalanceDelta)
        );
    }

    function donateClaims(address to, uint256 amount) external {
        PoolKey memory unused;
        manager.unlock(abi.encode(uint8(2), unused, abi.encode(to, amount)));
    }

    function donateToLPs(PoolKey memory key, uint256 ethAmount, uint256 tokens) external {
        manager.unlock(abi.encode(uint8(3), key, abi.encode(ethAmount, tokens)));
    }

    function callDuringUnlock(address target, bytes memory data) external {
        PoolKey memory unused;
        manager.unlock(abi.encode(uint8(4), unused, abi.encode(target, data)));
    }

    function unlockCallback(bytes calldata data) external returns (bytes memory) {
        require(msg.sender == address(manager), "only manager");
        (uint8 op, PoolKey memory key, bytes memory payload) = abi.decode(data, (uint8, PoolKey, bytes));
        BalanceDelta delta;
        if (op == 0) {
            delta = manager.swap(key, abi.decode(payload, (SwapParams)), "");
        } else if (op == 1) {
            (delta,) = manager.modifyLiquidity(key, abi.decode(payload, (ModifyLiquidityParams)), "");
        } else if (op == 2) {
            (address to, uint256 amount) = abi.decode(payload, (address, uint256));
            manager.mint(to, 0, amount);
            manager.sync(Currency.wrap(address(0)));
            manager.settle{value: amount}();
            return "";
        } else if (op == 3) {
            (uint256 a, uint256 b) = abi.decode(payload, (uint256, uint256));
            delta = manager.donate(key, a, b, "");
        } else {
            (address target, bytes memory callData) = abi.decode(payload, (address, bytes));
            (bool ok, bytes memory result) = target.call(callData);
            if (!ok) assembly ("memory-safe") { revert(add(result, 32), mload(result)) }
            return result;
        }
        _settle(key.currency0, delta.amount0());
        _settle(key.currency1, delta.amount1());
        return abi.encode(delta);
    }

    function _settle(Currency currency, int128 delta) private {
        if (delta > 0) {
            manager.take(currency, address(this), uint128(delta));
        } else if (delta < 0) {
            uint256 debt = uint256(-int256(delta));
            manager.sync(currency);
            if (currency.isAddressZero()) {
                manager.settle{value: debt}();
            } else {
                require(ITransferToken(Currency.unwrap(currency)).transfer(address(manager), debt));
                manager.settle();
            }
        }
    }
}
