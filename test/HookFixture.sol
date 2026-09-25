// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {MedallionHook} from "../src/MedallionHook.sol";
import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {SwapParams} from "v4-core/src/types/PoolOperation.sol";
import {toBalanceDelta} from "v4-core/src/types/BalanceDelta.sol";
import {AccountingManager} from "./mocks/AccountingManager.sol";
import {MockMedallion, MockERC20, MockPool4} from "./mocks/MainnetMocks.sol";

abstract contract HookDeployment is Test {
    address internal constant CREATOR = 0x70c6C4fcaAb11151FCEDb32eaaC3431547193A0a;
    address internal constant NFT = 0x9C8fF314C9Bc7F6e59A9d9225Fb22946427eDC03;
    address internal constant IMD = 0xD34a99Bc0f67aE1bbd63C660e6d0b0dd03E263B7;
    address internal constant POOL4 = 0xc6C965Bd164c483e87d0B550671798e9A3602840;
    address internal constant DEAD = address(0xdead);
    uint256 internal constant CAP = 1.64 ether;

    function deployHook(address manager) internal returns (MedallionHook hook) {
        bytes memory code = abi.encodePacked(type(MedallionHook).creationCode, abi.encode(manager));
        bytes32 hash = keccak256(code);
        for (uint256 i; i < 200000; ++i) {
            bytes32 salt = bytes32(i);
            address at = address(uint160(uint256(keccak256(abi.encodePacked(bytes1(0xff), address(this), salt, hash)))));
            if (uint160(at) & 0x3fff != 0xcc || at.code.length != 0) continue;
            assembly ("memory-safe") {
                at := create2(0, add(code, 32), mload(code), salt)
            }
            require(at != address(0), "deployment failed");
            return MedallionHook(at);
        }
        revert("salt not found");
    }

    function installMainnetMocks() internal {
        vm.etch(NFT, address(new MockMedallion()).code);
        vm.etch(IMD, address(new MockERC20("IMD", "IMD", 0)).code);
        vm.etch(POOL4, address(new MockPool4()).code);
        MockPool4(POOL4).configure(true, 0);
    }
}

abstract contract HookFixture is HookDeployment {
    AccountingManager internal manager;
    MedallionHook internal hook;
    PoolKey internal key;

    function setUp() public virtual {
        installMainnetMocks();
        manager = new AccountingManager();
        hook = deployHook(address(manager));
        key = PoolKey(Currency.wrap(address(0)), Currency.wrap(address(0xBEEF)), 3000, 60, IHooks(address(hook)));
        MockMedallion(NFT).setup(CREATOR, address(hook));
        vm.deal(address(manager), 10000 ether);
        MockERC20(IMD).mint(address(manager), 1e36);
        manager.setSpot(hook.burnPoolKey(false), 0);
        manager.setSpot(hook.burnPoolKey(true), 0);
    }

    function accrue(uint256 fee) internal {
        int128 amount = int128(int256(fee * 50));
        manager.trade(
            hook, key, SwapParams(true, -int256(amount), 1), toBalanceDelta(-amount + int128(int256(fee)), amount)
        );
    }

    function readyBurn() internal {
        accrue(CAP + 0.2 ether);
        vm.roll(block.number + 5);
    }

    function enableNormalMode() internal {
        readyBurn();
        hook.burnIMD(false, 0);
        vm.roll(block.number + 5);
    }

    function assertLedger() internal view {
        assertGe(manager.balanceOf(address(hook), 0), hook.totalFees() - hook.creatorPaid() - hook.burnSpent());
        assertEq(hook.burnable(), hook.totalFees() - hook.creatorEntitlement() - hook.burnSpent());
        assertTrue(hook.creatorPaid() == 0 || hook.creatorPaid() == CAP);
    }
}
