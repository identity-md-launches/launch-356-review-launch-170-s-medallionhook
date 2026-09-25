// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {SwapParams, ModifyLiquidityParams} from "v4-core/src/types/PoolOperation.sol";
import {BalanceDelta} from "v4-core/src/types/BalanceDelta.sol";

contract MockERC20 {
    string public name;
    string public symbol;
    uint8 public constant decimals = 18;
    uint256 public totalSupply;
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    constructor(string memory n, string memory s, uint256 supply) {
        name = n;
        symbol = s;
        mint(msg.sender, supply);
    }

    function mint(address to, uint256 amount) public {
        balanceOf[to] += amount;
        totalSupply += amount;
    }

    function approve(address to, uint256 amount) external returns (bool) {
        allowance[msg.sender][to] = amount;
        return true;
    }

    function transfer(address to, uint256 amount) external returns (bool) {
        balanceOf[msg.sender] -= amount;
        balanceOf[to] += amount;
        return true;
    }

    function transferFrom(address from, address to, uint256 amount) external returns (bool) {
        if (allowance[from][msg.sender] != type(uint256).max) allowance[from][msg.sender] -= amount;
        balanceOf[from] -= amount;
        balanceOf[to] += amount;
        return true;
    }
}

contract MockMedallion {
    address public holder;
    address public approval;
    bool public pretendTransfer;
    address public reenter;
    bool public reentryBlocked;
    bytes public reentryData;

    function setup(address initialHolder, address approved) external {
        holder = initialHolder;
        approval = approved;
    }

    function setPretendTransfer(bool value) external {
        pretendTransfer = value;
    }

    function attack(address target, bytes calldata data) external {
        reenter = target;
        reentryData = data;
    }

    function ownerOf(uint256 id) external view returns (address) {
        require(id == 447, "wrong medallion");
        return holder;
    }

    function transferFrom(address from, address to, uint256 id) external {
        require(id == 447 && from == holder, "wrong medallion or holder");
        require(msg.sender == approval, "not approved");
        if (reenter != address(0)) {
            (bool ok, bytes memory reason) = reenter.call(reentryData);
            require(!ok && bytes4(reason) == bytes4(keccak256("Reentrancy()")), "lock failed");
            reentryBlocked = true;
        }
        if (!pretendTransfer) holder = to;
    }
}

/// @dev Etched at the immutable POOL4 address, whose flags enable these three callbacks.
contract MockPool4 {
    bool public marketOpen;
    int24 public refTick;

    function configure(bool open, int24 tick) external {
        marketOpen = open;
        refTick = tick;
    }

    function beforeInitialize(address, PoolKey calldata, uint160) external pure returns (bytes4) {
        return IHooks.beforeInitialize.selector;
    }

    function beforeAddLiquidity(address, PoolKey calldata, ModifyLiquidityParams calldata, bytes calldata)
        external
        pure
        returns (bytes4)
    {
        return IHooks.beforeAddLiquidity.selector;
    }

    function afterSwap(address, PoolKey calldata, SwapParams calldata, BalanceDelta, bytes calldata)
        external
        pure
        returns (bytes4, int128)
    {
        return (IHooks.afterSwap.selector, 0);
    }
}

contract RefuseEther {
    fallback() external payable {
        revert("payment refused");
    }
}

contract ReenterCreator {
    address public hook;
    bool public blocked;

    function configure(address target) external {
        hook = target;
    }

    receive() external payable {
        (bool ok, bytes memory reason) = hook.call(abi.encodeWithSignature("retire()"));
        require(!ok && bytes4(reason) == bytes4(keccak256("Reentrancy()")), "reentry");
        blocked = true;
    }
}
