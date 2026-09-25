// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {MedallionHook} from "../../src/MedallionHook.sol";
import {IUnlockCallback} from "v4-core/src/interfaces/callback/IUnlockCallback.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {SwapParams} from "v4-core/src/types/PoolOperation.sol";
import {BalanceDelta, toBalanceDelta} from "v4-core/src/types/BalanceDelta.sol";
import {BeforeSwapDelta} from "v4-core/src/types/BeforeSwapDelta.sol";
import {TickMath} from "v4-core/src/libraries/TickMath.sol";
import {MockERC20} from "./MainnetMocks.sol";

/// @dev Controllable price/fill fixture, not a substitute for the real PoolManager integration tests.
contract AccountingManager {
    mapping(address => mapping(uint256 => uint256)) public balanceOf;
    mapping(bytes32 => bytes32) public slots;
    bool public unlocked;
    uint256 public inputBps = 10000;
    uint256 public outputBps = 9900;
    uint256 public fixedOutput;
    bool public useFixedOutput;
    bytes32 public lastPoolId;
    uint256 public lastBatch;
    address public lastRecipient;
    uint256 public takes;
    uint256 public mints;

    receive() external payable {}

    function setSpot(PoolKey memory key, int24 tick) external {
        bytes32 slot = keccak256(abi.encode(key.toId(), uint256(6)));
        slots[slot] = bytes32(uint256(TickMath.getSqrtPriceAtTick(tick)) | (uint256(uint24(tick)) << 160));
    }

    function extsload(bytes32 slot) external view returns (bytes32) {
        return slots[slot];
    }

    function exttload(bytes32) external view returns (bytes32) {
        return bytes32(uint256(unlocked ? 1 : 0));
    }

    function setUnlocked(bool value) external {
        unlocked = value;
    }

    function configureFill(uint256 input, uint256 output) external {
        inputBps = input;
        outputBps = output;
        useFixedOutput = false;
    }

    function setOutput(uint256 amount) external {
        useFixedOutput = true;
        fixedOutput = amount;
    }

    function mint(address to, uint256 id, uint256 amount) external {
        balanceOf[to][id] += amount;
        ++mints;
    }

    function burn(address from, uint256 id, uint256 amount) external {
        require(unlocked && from == msg.sender, "burn authorization");
        balanceOf[from][id] -= amount;
    }

    function donate(address to, uint256 amount) external {
        balanceOf[to][0] += amount;
    }

    function unlock(bytes calldata data) external returns (bytes memory result) {
        require(!unlocked, "already unlocked");
        unlocked = true;
        result = IUnlockCallback(msg.sender).unlockCallback(data);
        unlocked = false;
    }

    function take(Currency currency, address to, uint256 amount) external {
        require(unlocked, "locked");
        lastRecipient = to;
        ++takes;
        if (currency.isAddressZero()) {
            (bool ok,) = to.call{value: amount}("");
            require(ok, "ETH refused");
        } else {
            require(MockERC20(Currency.unwrap(currency)).transfer(to, amount));
        }
    }

    function swap(PoolKey memory key, SwapParams memory params, bytes calldata) external returns (BalanceDelta) {
        require(unlocked && params.zeroForOne && params.amountSpecified < 0, "invalid swap");
        lastPoolId = keccak256(abi.encode(key));
        lastBatch = uint256(-params.amountSpecified);
        uint256 out = useFixedOutput ? fixedOutput : lastBatch * outputBps / 10000;
        return toBalanceDelta(-int128(int256(lastBatch * inputBps / 10000)), int128(int256(out)));
    }

    function trade(MedallionHook hook, PoolKey calldata key, SwapParams calldata params, BalanceDelta delta)
        external
        returns (BeforeSwapDelta beforeDelta, int128 afterDelta)
    {
        (, beforeDelta,) = hook.beforeSwap(msg.sender, key, params, "");
        (, afterDelta) = hook.afterSwap(msg.sender, key, params, delta, "");
    }
}
