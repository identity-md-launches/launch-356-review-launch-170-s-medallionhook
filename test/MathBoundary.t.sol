// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {HookFixture} from "./HookFixture.sol";
import {MedallionHook} from "../src/MedallionHook.sol";
import {SwapParams} from "v4-core/src/types/PoolOperation.sol";
import {toBalanceDelta} from "v4-core/src/types/BalanceDelta.sol";
import {TickMath} from "v4-core/src/libraries/TickMath.sol";

contract MathBoundaryTest is HookFixture {
    function testExtremeSpecifiedFeesRejectWithoutTruncating() public {
        vm.expectRevert(MedallionHook.AmountTooLarge.selector);
        manager.trade(hook, key, SwapParams(true, type(int256).min, 1), toBalanceDelta(-1, 1));
        vm.expectRevert(MedallionHook.AmountTooLarge.selector);
        manager.trade(hook, key, SwapParams(false, type(int256).max, 1), toBalanceDelta(1, -1));
        assertEq(hook.totalFees(), 0);
        assertEq(manager.balanceOf(address(hook), 0), 0);
    }

    function testAnchorTraversesFullTickRangeAndNeverMovesTwiceWithinBlock() public {
        manager.setSpot(hook.burnPoolKey(false), TickMath.MIN_TICK);
        vm.roll(block.number + 8874);
        assertEq(hook.pokeAnchor(), TickMath.MIN_TICK);
        manager.setSpot(hook.burnPoolKey(false), TickMath.MAX_TICK);
        assertEq(hook.pokeAnchor(), TickMath.MIN_TICK);
        vm.roll(block.number + 8873);
        assertEq(hook.pokeAnchor(), TickMath.MAX_TICK);
        manager.setSpot(hook.burnPoolKey(false), TickMath.MIN_TICK);
        vm.roll(block.number + 1);
        assertEq(hook.pokeAnchor(), TickMath.MAX_TICK - 200);
    }

    function testFuzzQuoteMonotoneAcrossFullTickRange(int24 tickSeed, uint64 amountSeed) public view {
        int24 tick = int24(bound(int256(tickSeed), TickMath.MIN_TICK, TickMath.MAX_TICK - 1));
        uint256 amount = bound(uint256(amountSeed), hook.MIN_BURN(), hook.MAX_BURN_BATCH());
        assertLe(hook.quoteAtTick(tick, amount), hook.quoteAtTick(tick + 1, amount));
        assertLe(hook.quoteAtTick(tick, amount), hook.quoteAtTick(tick, amount + 1));
    }

    function testQuoteFormulaBranchBoundaryIsContinuousAndMonotonic() public view {
        for (int24 tick = 443630; tick < 443644; ++tick) {
            assertLt(hook.quoteAtTick(tick, 0.05 ether), hook.quoteAtTick(tick + 1, 0.05 ether));
        }
        assertEq(hook.quoteAtTick(0, 0.05 ether), 0.05 ether);
        assertEq(hook.quoteAtTick(TickMath.MIN_TICK, 0.05 ether), 0);
        assertGt(hook.quoteAtTick(TickMath.MAX_TICK, 0.05 ether), 0.05 ether);
    }
}
