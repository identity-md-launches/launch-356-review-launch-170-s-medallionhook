// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {HookDeployment} from "./HookFixture.sol";
import {MedallionHook} from "../src/MedallionHook.sol";
import {FareToken} from "../src/FareToken.sol";
import {PoolManager} from "v4-core/src/PoolManager.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {Hooks} from "v4-core/src/libraries/Hooks.sol";
import {CustomRevert} from "v4-core/src/libraries/CustomRevert.sol";
import {TickMath} from "v4-core/src/libraries/TickMath.sol";
import {TransientStateLibrary} from "v4-core/src/libraries/TransientStateLibrary.sol";
import {StateLibrary} from "v4-core/src/libraries/StateLibrary.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {BalanceDelta} from "v4-core/src/types/BalanceDelta.sol";
import {SwapParams} from "v4-core/src/types/PoolOperation.sol";
import {Vm} from "forge-std/Vm.sol";
import {LocalRouter} from "./mocks/LocalRouter.sol";
import {MockMedallion, MockERC20} from "./mocks/MainnetMocks.sol";

contract RealPoolTest is HookDeployment {
    using TransientStateLibrary for IPoolManager;
    using StateLibrary for IPoolManager;
    PoolManager internal manager;
    LocalRouter internal router;
    FareToken internal token;
    MedallionHook internal hook;
    PoolKey internal key;

    function setUp() public {
        installMainnetMocks();
        manager = new PoolManager(address(this));
        router = new LocalRouter(manager);
        vm.deal(address(router), 10000 ether);
        hook = deployHook(address(manager));
        token = new FareToken();
        token.transfer(address(router), 1e25);
        key = PoolKey(Currency.wrap(address(0)), Currency.wrap(address(token)), 3000, 60, IHooks(address(hook)));
        manager.initialize(key, uint160(1 << 96));
        router.liquidity(key, -600, 600, 10000 ether);
        MockMedallion(NFT).setup(CREATOR, address(hook));
        MockERC20(IMD).mint(address(router), 10000 ether);
        for (uint256 i; i < 2; ++i) {
            PoolKey memory burnKey = hook.burnPoolKey(i == 1);
            manager.initialize(burnKey, uint160(1 << 96));
            router.liquidity(burnKey, -60000, 60000, 1000 ether);
        }
    }

    function _swap(bool buy, int256 amount) internal returns (BalanceDelta) {
        return
            router.swap(key, SwapParams(buy, amount, buy ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1));
    }

    function testActualManagerAllFourSwapDirectionsAndClaimSettlement() public {
        _checkTrade(true, -1 ether);
        _checkTrade(false, 1 ether);
        _checkTrade(true, 1 ether);
        _checkTrade(false, -1 ether);
        assertEq(hook.creatorPaid(), 0);
        assertEq(CREATOR.balance, 0);
        assertEq(hook.burnable(), 0);
        assertEq(manager.balanceOf(address(hook), uint160(address(token))), 0);
        _settled();
    }

    function _checkTrade(bool buy, int256 amount) internal {
        uint256 oldFees = hook.totalFees();
        vm.recordLogs();
        BalanceDelta net = _swap(buy, amount);
        Vm.Log[] memory logs = vm.getRecordedLogs();
        int128 raw0;
        int128 raw1;
        bool found;
        for (uint256 i; i < logs.length; ++i) {
            if (
                logs[i].emitter == address(manager)
                    && logs[i].topics[0]
                        == keccak256("Swap(bytes32,address,int128,int128,uint160,uint128,int24,uint24)")
            ) {
                (raw0, raw1,,,,) = abi.decode(logs[i].data, (int128, int128, uint160, uint128, int24, uint24));
                found = true;
            }
        }
        assertTrue(found, "raw pool swap observed");
        bool specified = buy == (amount < 0);
        uint256 basis =
            specified ? uint256(amount < 0 ? -amount : amount) : uint256(raw0 < 0 ? -int256(raw0) : int256(raw0));
        uint256 fee = basis * 200 / 10000;
        assertEq(hook.totalFees() - oldFees, fee);
        assertEq(int256(net.amount0()), int256(raw0) - int256(fee));
        assertEq(net.amount1(), raw1);
        assertEq(manager.balanceOf(address(hook), 0), hook.totalFees());
        if (specified) assertEq(net.amount0(), amount);
        else assertEq(net.amount1(), amount);
    }

    function testActualPartialFillsRevertAllFourWays() public {
        uint256 ethBefore = address(router).balance;
        uint256 tokensBefore = token.balanceOf(address(router));
        for (uint256 i; i < 4; ++i) {
            bool buy = i % 2 == 0;
            int256 specified = i < 2 ? int256(-100 ether) : int256(100 ether);
            uint160 limit = TickMath.getSqrtPriceAtTick(buy ? int24(-1) : int24(1));
            vm.expectRevert(
                abi.encodeWithSelector(
                    CustomRevert.WrappedError.selector,
                    address(hook),
                    IHooks.afterSwap.selector,
                    abi.encodeWithSelector(MedallionHook.PartialFill.selector),
                    abi.encodeWithSelector(Hooks.HookCallFailed.selector)
                )
            );
            router.swap(key, SwapParams(buy, specified, limit));
        }
        assertEq(hook.totalFees(), 0);
        assertEq(manager.balanceOf(address(hook), 0), 0);
        assertEq(address(router).balance, ethBefore);
        assertEq(token.balanceOf(address(router)), tokensBefore);
        _settled();
    }

    function testActualRetirementAndBothBurnPools() public {
        _swap(true, -90 ether);
        assertEq(hook.totalFees(), 1.8 ether);
        hook.retire();
        assertEq(CREATOR.balance, CAP);
        assertEq(MockMedallion(NFT).holder(), DEAD);
        assertEq(manager.balanceOf(address(hook), 0), 0.16 ether);
        vm.roll(block.number + 5);
        hook.burnIMD(false, 0);
        assertEq(hook.burnSpent(), 0.01 ether);
        vm.roll(block.number + 5);
        hook.burnIMD(true, 0);
        assertEq(hook.burnSpent(), 0.06 ether);
        assertGt(MockERC20(IMD).balanceOf(DEAD), 0.058 ether);
        assertEq(MockERC20(IMD).balanceOf(DEAD), hook.totalIMDBurned());
        assertEq(manager.balanceOf(address(hook), 0), 0.1 ether);
        assertEq(CREATOR.balance, CAP);
        _settled();
    }

    function testActualUnapprovedNFTRollsBackAndRetrySucceeds() public {
        _swap(true, -82 ether);
        MockMedallion(NFT).setup(CREATOR, address(0));
        vm.expectPartialRevert(MedallionHook.RetireRefused.selector);
        hook.retire();
        assertEq(manager.balanceOf(address(hook), 0), CAP);
        MockMedallion(NFT).setup(CREATOR, address(hook));
        hook.retire();
        assertEq(manager.balanceOf(address(hook), 0), 0);
        assertEq(CREATOR.balance, CAP);
        _settled();
    }

    function testActualClaimAndLiquidityDonationsPreserveLedger() public {
        _swap(true, -1 ether);
        router.donateClaims(address(hook), 1 ether);
        router.donateToLPs(key, 0.1 ether, 0.1 ether);
        assertEq(hook.totalFees(), 0.02 ether);
        assertEq(hook.creatorEntitlement(), 0.02 ether);
        assertEq(hook.burnable(), 0);
        assertEq(manager.balanceOf(address(hook), 0), 1.02 ether);
        _settled();
    }

    function testActualNonETHPoolTradesWithoutHookFee() public {
        FareToken other = new FareToken();
        other.transfer(address(router), 1e25);
        (address a, address b) =
            address(token) < address(other) ? (address(token), address(other)) : (address(other), address(token));
        PoolKey memory otherKey = PoolKey(Currency.wrap(a), Currency.wrap(b), 3000, 60, IHooks(address(hook)));
        manager.initialize(otherKey, uint160(1 << 96));
        router.liquidity(otherKey, -600, 600, 10000 ether);
        router.swap(otherKey, SwapParams(true, -1 ether, TickMath.MIN_SQRT_PRICE + 1));
        router.swap(otherKey, SwapParams(false, -1 ether, TickMath.MAX_SQRT_PRICE - 1));
        assertEq(hook.totalFees(), 0);
        assertEq(manager.balanceOf(address(hook), 0), 0);
        _settled();
    }

    function testActualSingleSidedFirstBuySellAndUnwind() public {
        // A launch can start with only FARE447 liquidity; this hook does not gate initialization.
        PoolKey memory oneSided = key;
        oneSided.tickSpacing = 120;
        manager.initialize(oneSided, TickMath.getSqrtPriceAtTick(-600));
        // At the upper boundary, the position consists of currency1 only.
        router.liquidity(oneSided, -1200, -600, 1000 ether);
        uint256 nativeBefore = address(router).balance;
        router.swap(oneSided, SwapParams(true, -1 ether, TickMath.MIN_SQRT_PRICE + 1));
        router.swap(oneSided, SwapParams(false, -0.1 ether, TickMath.MAX_SQRT_PRICE - 1));
        assertLt(address(router).balance, nativeBefore);
        router.liquidity(oneSided, -1200, -600, -1000 ether);
        assertGt(hook.totalFees(), 0.02 ether);
        _settled();
    }

    function testActualTopLevelRestriction() public {
        _swap(true, -90 ether);
        vm.roll(block.number + 5);
        vm.expectRevert(MedallionHook.ManagerUnlocked.selector);
        router.callDuringUnlock(address(hook), abi.encodeCall(hook.burnIMD, (false, 0)));
        vm.expectRevert(MedallionHook.ManagerUnlocked.selector);
        router.callDuringUnlock(address(hook), abi.encodeCall(hook.pokeAnchor, ()));
    }

    function testManifestPriceFirstBuyFromTokenOnlyLiquidity() public {
        MedallionHook launchHook = deployHook(address(manager));
        PoolKey memory launchKey = key;
        launchKey.hooks = IHooks(address(launchHook));
        manager.initialize(launchKey, 79228162514264337593543950336000);
        token.transfer(address(router), token.balanceOf(address(this)));
        BalanceDelta seeded = router.liquidity(launchKey, -887220, 138120, 8e23);
        assertEq(seeded.amount0(), 0, "launch seeds no ETH");
        assertLt(seeded.amount1(), 0);
        BalanceDelta buy = router.swap(launchKey, SwapParams(true, -1 ether, TickMath.MIN_SQRT_PRICE + 1));
        assertEq(buy.amount0(), -1 ether);
        assertGt(buy.amount1(), 900000 ether);
        assertEq(launchHook.totalFees(), 0.02 ether);
        assertEq(manager.balanceOf(address(launchHook), 0), 0.02 ether);
        router.swap(launchKey, SwapParams(false, -100000 ether, TickMath.MAX_SQRT_PRICE - 1));
        router.liquidity(launchKey, -887220, 138120, -8e23);
        assertGt(launchHook.totalFees(), 0.02 ether);
        _settled();
    }

    function _settled() internal view {
        IPoolManager pm = manager;
        assertFalse(pm.isUnlocked());
        assertEq(pm.getNonzeroDeltaCount(), 0);
        assertEq(pm.currencyDelta(address(hook), Currency.wrap(address(0))), 0);
        assertGe(manager.balanceOf(address(hook), 0), hook.totalFees() - hook.creatorPaid() - hook.burnSpent());
    }
}
