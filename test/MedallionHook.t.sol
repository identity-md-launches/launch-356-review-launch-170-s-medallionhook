// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {HookFixture} from "./HookFixture.sol";
import {MedallionHook} from "../src/MedallionHook.sol";
import {Hooks} from "v4-core/src/libraries/Hooks.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {SwapParams} from "v4-core/src/types/PoolOperation.sol";
import {BalanceDelta, toBalanceDelta} from "v4-core/src/types/BalanceDelta.sol";
import {BeforeSwapDelta, BeforeSwapDeltaLibrary} from "v4-core/src/types/BeforeSwapDelta.sol";
import {Vm} from "forge-std/Vm.sol";
import {MockMedallion, MockERC20, MockPool4, RefuseEther, ReenterCreator} from "./mocks/MainnetMocks.sol";

contract MedallionHookTest is HookFixture {
    using BeforeSwapDeltaLibrary for BeforeSwapDelta;
    event MedallionRetired(address indexed previousOwner);
    event CreatorPaid(address indexed creator, uint256 amount);
    event LastFare(uint256 indexed medallionId, bytes32 indexed fareHash, string fare);

    function testPermissionsAndConstructorValidation() public {
        Hooks.Permissions memory p = hook.getHookPermissions();
        assertTrue(p.beforeSwap && p.afterSwap && p.beforeSwapReturnDelta && p.afterSwapReturnDelta);
        assertFalse(
            p.beforeInitialize || p.afterInitialize || p.beforeAddLiquidity || p.afterAddLiquidity
                || p.beforeRemoveLiquidity || p.afterRemoveLiquidity || p.beforeDonate || p.afterDonate
                || p.afterAddLiquidityReturnDelta || p.afterRemoveLiquidityReturnDelta
        );
        assertEq(uint160(address(hook)) & 0x3fff, 0xcc);
        assertEq(address(hook.poolManager()), address(manager));
        vm.expectPartialRevert(Hooks.HookAddressNotValid.selector);
        new MedallionHook(address(manager));
    }

    function testCallbacksAndUnlockRefuseUnauthorizedCallers() public {
        SwapParams memory p = SwapParams(true, -1 ether, 1);
        vm.expectRevert(MedallionHook.OnlyPoolManager.selector);
        hook.beforeSwap(address(this), key, p, "");
        vm.expectRevert(MedallionHook.OnlyPoolManager.selector);
        hook.afterSwap(address(this), key, p, toBalanceDelta(-1 ether, 1 ether), "");
        vm.expectRevert(MedallionHook.OnlyPoolManager.selector);
        hook.unlockCallback(abi.encode(uint8(0), false, CAP, 0));
        vm.prank(address(manager));
        vm.expectRevert(MedallionHook.UnexpectedUnlock.selector);
        hook.unlockCallback(abi.encode(uint8(0), false, CAP, 0));
    }

    function testFourDirectionsCollectOnlyETHClaims() public {
        _trade(true, -1 ether, -0.98 ether, 2 ether, 0.02 ether, 0);
        _trade(false, 1 ether, 1.02 ether, -2 ether, 0.02 ether, 0);
        _trade(true, 2 ether, -1 ether, 2 ether, 0, 0.02 ether);
        _trade(false, -2 ether, 1 ether, -2 ether, 0, 0.02 ether);
        assertEq(hook.totalFees(), 0.08 ether);
        assertEq(manager.balanceOf(address(hook), 0), 0.08 ether);
        assertEq(manager.takes(), 0);
        assertEq(CREATOR.balance, 0);
        assertEq(hook.burnable(), 0);
        assertLedger();
    }

    function _trade(bool buy, int256 amount, int128 d0, int128 d1, int128 beforeFee, int128 afterFee) internal {
        (BeforeSwapDelta b, int128 a) = manager.trade(hook, key, SwapParams(buy, amount, 1), toBalanceDelta(d0, d1));
        assertEq(b.getSpecifiedDelta(), beforeFee);
        assertEq(b.getUnspecifiedDelta(), 0);
        assertEq(a, afterFee);
    }

    function testPartialFillAllFourDirectionsRollsBackFees() public {
        _partial(true, -1 ether, -0.97 ether, 2 ether);
        _partial(false, 1 ether, 1.01 ether, -2 ether);
        _partial(true, 2 ether, -1 ether, 1.9 ether);
        _partial(false, -2 ether, 1 ether, -1.9 ether);
        _partial(true, -1 ether, 0, 0);
        assertEq(hook.totalFees(), 0);
        assertEq(manager.balanceOf(address(hook), 0), 0);
    }

    function _partial(bool buy, int256 amount, int128 d0, int128 d1) internal {
        vm.expectRevert(MedallionHook.PartialFill.selector);
        manager.trade(hook, key, SwapParams(buy, amount, 1), toBalanceDelta(d0, d1));
    }

    function testNonETHPoolsFeeFreeEvenOnPartialFill() public {
        key.currency0 = Currency.wrap(address(1));
        for (uint256 i; i < 4; ++i) {
            _trade(i % 2 == 0, i < 2 ? int256(-1 ether) : int256(1 ether), 0, 0, 0, 0);
        }
        assertEq(hook.totalFees(), 0);
        assertEq(manager.mints(), 0);
    }

    function testFuzzFeeRoundingAndConservation(uint96 ethAmount, bool buy, bool exactInput) public {
        uint256 amount = bound(ethAmount, 1, 10000 ether);
        uint256 fee = amount * 200 / 10000;
        bool specified = buy == exactInput;
        int256 signedAmount = exactInput ? -int256(amount) : int256(amount);
        int128 ethDelta = buy ? -int128(int256(amount)) : int128(int256(amount));
        if (specified) ethDelta += int128(int256(fee));
        int128 tokenDelta = buy ? int128(int256(amount)) : -int128(int256(amount));
        _trade(
            buy,
            signedAmount,
            ethDelta,
            tokenDelta,
            specified ? int128(int256(fee)) : int128(0),
            specified ? int128(0) : int128(int256(fee))
        );
        assertEq(hook.totalFees(), fee);
        assertLedger();
    }

    function testDonationsNeverCreateEntitlementOrBurnBudget() public {
        manager.donate(address(hook), 99 ether);
        accrue(1 ether);
        assertEq(hook.creatorEntitlement(), 1 ether);
        assertEq(hook.burnable(), 0);
        assertLedger();
        vm.roll(block.number + 5);
        vm.expectRevert(MedallionHook.NothingToBurn.selector);
        hook.burnIMD(false, 0);
    }

    function testCapCrossingRecoupedExactlyOnceAndStatus() public {
        assertEq(hook.status(), "IN SERVICE. Recouped 0.00 of 1.64 ETH.");
        accrue(1.639999 ether);
        assertEq(hook.status(), "IN SERVICE. Recouped 1.63 of 1.64 ETH.");
        assertEq(hook.burnable(), 0);
        vm.recordLogs();
        accrue(0.020001 ether);
        accrue(0.02 ether);
        Vm.Log[] memory logs = vm.getRecordedLogs();
        uint256 seen;
        for (uint256 i; i < logs.length; ++i) {
            if (logs[i].topics[0] == keccak256("Recouped(uint256,uint256)")) {
                ++seen;
                (uint256 fees, uint256 at) = abi.decode(logs[i].data, (uint256, uint256));
                assertEq(fees, 1.66 ether);
                assertEq(at, block.number);
            }
        }
        assertEq(seen, 1);
        assertEq(hook.creatorEntitlement(), CAP);
        assertEq(hook.burnable(), 0.04 ether);
        assertEq(hook.creatorPaid(), 0);
        assertEq(
            hook.status(),
            "RECOUPED, NOT RETIRED. The 1.64 ETH is ready and is released only by the transaction that retires medallion #447."
        );
    }

    function testLastFarePinnedAndOpcodeWalk() public view {
        assertEq(bytes(hook.LAST_FARE()).length, 1470);
        assertEq(hook.LAST_FARE_HASH(), 0xa0dafc7711f4bf93a220c7a34fdd211caffeaf1108947b0a7dfaf05abb081ece);
        assertEq(keccak256(bytes(hook.LAST_FARE())), hook.LAST_FARE_HASH());
        bytes memory code = address(hook).code;
        assertLe(code.length, 24576);
        for (uint256 i; i < code.length; ++i) {
            uint8 op = uint8(code[i]);
            if (op >= 0x60 && op <= 0x7f) i += op - 0x5f;
            else assertTrue(op != 0xf2 && op != 0xf4 && op != 0xff, "forbidden opcode");
        }
    }

    function testRetireBeforeCap() public {
        accrue(CAP - 1);
        vm.expectRevert(MedallionHook.NotRecouped.selector);
        hook.retire();
        assertEq(hook.creatorPaid(), 0);
    }

    function testRefusedRetirementLeavesEverythingIntact() public {
        accrue(CAP);
        MockMedallion(NFT).setup(CREATOR, address(0));
        vm.expectRevert(
            abi.encodeWithSelector(
                MedallionHook.RetireRefused.selector, abi.encodeWithSignature("Error(string)", "not approved")
            )
        );
        hook.retire();
        assertFalse(hook.retired());
        assertEq(hook.creatorPaid(), 0);
        assertEq(CREATOR.balance, 0);
        assertEq(MockMedallion(NFT).holder(), CREATOR);
        assertEq(manager.balanceOf(address(hook), 0), CAP);
    }

    function testRetireVerifiesTransferActuallyHappened() public {
        accrue(CAP);
        MockMedallion(NFT).setPretendTransfer(true);
        vm.expectPartialRevert(MedallionHook.RetireRefused.selector);
        hook.retire();
        assertEq(hook.creatorPaid(), 0);
        assertFalse(hook.retired());
    }

    function testRetirementAtomicPayoutAndEvents() public {
        accrue(CAP + 0.1 ether);
        uint256 previousBalance = CREATOR.balance;
        vm.expectEmit(true, false, false, true, address(hook));
        emit MedallionRetired(CREATOR);
        vm.expectEmit(true, false, false, true, address(hook));
        emit CreatorPaid(CREATOR, CAP);
        vm.expectEmit(true, true, false, true, address(hook));
        emit LastFare(447, hook.LAST_FARE_HASH(), hook.LAST_FARE());
        vm.prank(address(0x123));
        hook.retire();
        assertEq(MockMedallion(NFT).holder(), DEAD);
        assertEq(CREATOR.balance - previousBalance, CAP);
        assertEq(hook.creatorPaid(), CAP);
        assertTrue(hook.retired());
        assertEq(manager.balanceOf(address(hook), 0), 0.1 ether);
        assertEq(
            hook.status(),
            "RETIRED. Medallion #447 is at 0x...dEaD. 1.64 ETH paid. Every fee buys $IMD and sends it there. IMD burned so far: 0.0."
        );
        vm.expectRevert(MedallionHook.AlreadyRetired.selector);
        hook.retire();
        assertLedger();
    }

    function testAlreadyDeadDoesNotRequireApproval() public {
        accrue(CAP);
        MockMedallion(NFT).setup(DEAD, address(0));
        hook.retire();
        assertEq(hook.creatorPaid(), CAP);
        assertEq(CREATOR.balance, CAP);
    }

    function testPayoutFailureRollsBackNFTAndLedger() public {
        accrue(CAP);
        vm.etch(CREATOR, address(new RefuseEther()).code);
        vm.expectRevert("ETH refused");
        hook.retire();
        assertEq(MockMedallion(NFT).holder(), CREATOR);
        assertEq(hook.creatorPaid(), 0);
        assertFalse(hook.retired());
        assertEq(manager.balanceOf(address(hook), 0), CAP);
    }

    function testReentrancyOnNFTAndCreatorPaymentIsBlocked() public {
        accrue(CAP);
        MockMedallion(NFT).attack(address(hook), abi.encodeCall(hook.burnIMD, (false, 0)));
        vm.etch(CREATOR, address(new ReenterCreator()).code);
        ReenterCreator(payable(CREATOR)).configure(address(hook));
        hook.retire();
        assertTrue(MockMedallion(NFT).reentryBlocked());
        assertTrue(ReenterCreator(payable(CREATOR)).blocked());
        assertEq(hook.creatorPaid(), CAP);
    }

    function testMissingAndMalformedNFTRevertUnavailable() public {
        accrue(CAP);
        vm.etch(NFT, "");
        vm.expectRevert(MedallionHook.MedallionUnavailable.selector);
        hook.retire();
        vm.etch(NFT, address(new MockMedallion()).code);
        bytes memory selector = abi.encodeWithSignature("ownerOf(uint256)", 447);
        vm.mockCall(NFT, selector, hex"01");
        vm.expectRevert(MedallionHook.MedallionUnavailable.selector);
        hook.retire();
        vm.mockCall(NFT, selector, abi.encode(type(uint256).max));
        vm.expectRevert(MedallionHook.MedallionUnavailable.selector);
        hook.retire();
    }
}

contract MedallionBurnTest is HookFixture {
    function testBurnGuardOrderAndDeploymentCooldown() public {
        vm.expectRevert(MedallionHook.TooSoon.selector);
        hook.burnIMD(true, 0);
        vm.roll(block.number + 4);
        vm.expectRevert(MedallionHook.TooSoon.selector);
        hook.burnIMD(false, 0);
        vm.roll(block.number + 1);
        vm.expectRevert(MedallionHook.NothingToBurn.selector);
        hook.burnIMD(true, 0);
        accrue(CAP + 0.002 ether - 1);
        vm.expectRevert(MedallionHook.NothingToBurn.selector);
        hook.burnIMD(false, 0);
        accrue(1);
        hook.burnIMD(false, 0);
        assertEq(manager.lastBatch(), 0.002 ether);
    }

    function testFirstBurnFallbackThenNormalFixedKeysAndBatches() public {
        readyBurn();
        vm.expectRevert(MedallionHook.Pool4Unavailable.selector);
        hook.burnIMD(true, 0);
        uint256 callerBalance = address(this).balance;
        hook.burnIMD(false, 0);
        assertEq(manager.lastBatch(), 0.01 ether);
        _checkKey(false, 200, address(0));
        assertEq(manager.lastRecipient(), DEAD);
        assertEq(MockERC20(IMD).balanceOf(DEAD), 0.0099 ether);
        assertEq(address(this).balance, callerBalance);
        assertEq(CREATOR.balance, 0);
        vm.expectRevert(MedallionHook.TooSoon.selector);
        hook.burnIMD(false, 0);
        vm.roll(block.number + 5);
        hook.burnIMD(true, 0);
        _checkKey(true, 60, POOL4);
        assertEq(manager.lastBatch(), 0.05 ether);
        assertEq(hook.burnSpent(), 0.06 ether);
        assertEq(hook.totalIMDBurned(), 0.0594 ether);
        assertLedger();
    }

    function _checkKey(bool via, int24 spacing, address hooks) internal view {
        PoolKey memory selected = hook.burnPoolKey(via);
        assertEq(Currency.unwrap(selected.currency0), address(0));
        assertEq(Currency.unwrap(selected.currency1), IMD);
        assertEq(selected.fee, 10000);
        assertEq(selected.tickSpacing, spacing);
        assertEq(address(selected.hooks), hooks);
        assertEq(manager.lastPoolId(), keccak256(abi.encode(selected)));
    }

    function testBurnBeforeRetirementPreservesCapAndAfterRetirementStillBurns() public {
        enableNormalMode();
        hook.burnIMD(false, 0);
        hook.retire();
        assertEq(CREATOR.balance, CAP);
        vm.roll(block.number + 5);
        accrue(0.001 ether);
        hook.burnIMD(false, 0);
        assertEq(CREATOR.balance, CAP);
        assertLedger();
    }

    function testMinimumUsesReference96PercentAndCallerFloor() public {
        enableNormalMode();
        manager.setOutput(0.048 ether - 1);
        uint256 oldBlock = hook.lastBurnBlock();
        uint256 oldSpent = hook.burnSpent();
        vm.expectRevert(MedallionHook.Slippage.selector);
        hook.burnIMD(false, 0);
        assertEq(hook.lastBurnBlock(), oldBlock);
        assertEq(hook.burnSpent(), oldSpent);
        manager.setOutput(0.048 ether);
        vm.expectRevert(MedallionHook.Slippage.selector);
        hook.burnIMD(false, 0.048 ether + 1);
        hook.burnIMD(false, 0.048 ether);
        assertEq(hook.burnSpent(), oldSpent + 0.05 ether);
    }

    function testPartialAndZeroBurnFillRevertWithoutSpending() public {
        enableNormalMode();
        uint256 oldSpent = hook.burnSpent();
        manager.configureFill(9999, 10000);
        vm.expectRevert(MedallionHook.PartialFill.selector);
        hook.burnIMD(false, 0);
        manager.configureFill(0, 0);
        vm.expectRevert(MedallionHook.PartialFill.selector);
        hook.burnIMD(false, 0);
        manager.configureFill(10000, 0);
        vm.expectRevert(MedallionHook.PartialFill.selector);
        hook.burnIMD(false, 0);
        assertEq(hook.burnSpent(), oldSpent);
        assertLedger();
    }

    function testOneSidedNormalGuardsAndFavorablePriceAllowed() public {
        enableNormalMode();
        manager.setSpot(hook.burnPoolKey(false), -301);
        vm.expectRevert(MedallionHook.PriceOffReference.selector);
        hook.burnIMD(false, 0);
        manager.setSpot(hook.burnPoolKey(false), -300);
        hook.burnIMD(false, 0);
        vm.roll(block.number + 5);
        manager.setSpot(hook.burnPoolKey(true), -151);
        vm.expectRevert(MedallionHook.PriceOffReference.selector);
        hook.burnIMD(true, 0);
        manager.setSpot(hook.burnPoolKey(true), -150);
        hook.burnIMD(true, 0);
        vm.roll(block.number + 5);
        manager.setSpot(hook.burnPoolKey(false), 10000);
        hook.burnIMD(false, 0);
    }

    function testReferenceQuoteIsNotWeakenedToManipulatedSpot() public {
        enableNormalMode();
        manager.setSpot(hook.burnPoolKey(false), -300);
        manager.setOutput(0.047 ether);
        vm.expectRevert(MedallionHook.Slippage.selector);
        hook.burnIMD(false, 0);
        // Non-zero trusted reference changes the absolute minimum as well.
        MockPool4(POOL4).configure(true, 10000);
        manager.setSpot(hook.burnPoolKey(false), 10000);
        uint256 minimum = (hook.quoteAtTick(10000, 0.05 ether) * 96 + 99) / 100;
        manager.setOutput(minimum - 1);
        vm.expectRevert(MedallionHook.Slippage.selector);
        hook.burnIMD(false, 0);
        manager.setOutput(minimum);
        hook.burnIMD(false, 0);
        assertEq(hook.anchorTick(), 10000);
    }

    function testClosedMarketFallbackAndAnchorRateLimitBothDirections() public {
        enableNormalMode();
        MockPool4(POOL4).configure(false, 0);
        vm.expectRevert(MedallionHook.Pool4Unavailable.selector);
        hook.burnIMD(true, 0);
        manager.setSpot(hook.burnPoolKey(false), -10000);
        int24 previous = hook.anchorTick();
        uint256 previousBlock = hook.anchorBlock();
        int24 current = hook.pokeAnchor();
        assertEq(int256(previous) - current, int256(200 * (block.number - previousBlock)));
        assertEq(hook.pokeAnchor(), current);
        vm.roll(block.number + 1);
        assertEq(hook.pokeAnchor(), current - 200);
        manager.setSpot(hook.burnPoolKey(false), 10000);
        vm.roll(block.number + 1);
        assertEq(hook.pokeAnchor(), current);
    }

    function testFallbackPriceGuardAndPokeCanRecoverWithoutBurn() public {
        readyBurn();
        manager.setSpot(hook.burnPoolKey(false), -1151);
        vm.expectRevert(MedallionHook.PriceOffReference.selector);
        hook.burnIMD(false, 0);
        manager.setSpot(hook.burnPoolKey(false), -1150);
        manager.setOutput(hook.quoteAtTick(-1000, 0.01 ether));
        hook.burnIMD(false, 0);
        assertEq(hook.anchorTick(), -1000);
        MockPool4(POOL4).configure(false, 0);
        manager.setSpot(hook.burnPoolKey(false), -4000);
        vm.roll(block.number + 5);
        vm.expectRevert(MedallionHook.PriceOffReference.selector);
        hook.burnIMD(false, 0);
        hook.pokeAnchor();
        vm.roll(block.number + 10);
        manager.setOutput(hook.quoteAtTick(-4000, 0.01 ether));
        hook.burnIMD(false, 0);
        assertEq(hook.anchorTick(), -4000);
    }

    function testStalenessBoundaryAndFallbackBatch() public {
        enableNormalMode();
        vm.roll(hook.lastBurnBlock() + 50400);
        hook.burnIMD(true, 0);
        vm.roll(hook.lastBurnBlock() + 50401);
        vm.expectRevert(MedallionHook.Pool4Unavailable.selector);
        hook.burnIMD(true, 0);
        hook.burnIMD(false, 0);
        assertEq(manager.lastBatch(), 0.01 ether);
    }

    function testMalformedPool4ViewsFallBackWithoutDecodePanic() public {
        enableNormalMode();
        bytes memory open = abi.encodeWithSignature("marketOpen()");
        bytes memory tick = abi.encodeWithSignature("refTick()");
        vm.mockCall(POOL4, open, abi.encode(uint256(2)));
        _assertUnavailable();
        vm.mockCall(POOL4, open, hex"01");
        _assertUnavailable();
        vm.mockCallRevert(POOL4, open, "failed");
        _assertUnavailable();
        vm.clearMockedCalls();
        vm.mockCall(POOL4, tick, abi.encode(int256(887273)));
        _assertUnavailable();
        vm.mockCall(POOL4, tick, abi.encode(int256(-887273)));
        _assertUnavailable();
        vm.mockCall(POOL4, tick, hex"ffffff");
        _assertUnavailable();
        hook.burnIMD(false, 0);
        assertEq(manager.lastBatch(), 0.01 ether);
    }

    function _assertUnavailable() internal {
        vm.expectRevert(MedallionHook.Pool4Unavailable.selector);
        hook.burnIMD(true, 0);
    }

    function testMissingMainnetContractsOnSepolia() public {
        readyBurn();
        vm.chainId(11155111);
        vm.etch(NFT, "");
        vm.etch(POOL4, "");
        vm.etch(IMD, "");
        vm.expectRevert(MedallionHook.MedallionUnavailable.selector);
        hook.retire();
        _assertUnavailable();
        // Use a different manager with no initialized burn pools, as on Sepolia.
        PoolKey memory plain = hook.burnPoolKey(false);
        bytes32 slot = keccak256(abi.encode(plain.toId(), uint256(6)));
        // AccountingManager.slots is storage mapping at slot 1.
        vm.store(address(manager), keccak256(abi.encode(slot, uint256(1))), bytes32(0));
        vm.expectRevert(MedallionHook.MissingPool.selector);
        hook.burnIMD(false, 0);
    }

    function testConstructorSeedsAnchorOrSafelyDefaultsWhenUnavailable() public {
        MockPool4(POOL4).configure(false, -20000);
        MedallionHook another = deployHook(address(manager));
        assertEq(another.anchorTick(), -20000);
        vm.etch(POOL4, "");
        // A different manager makes a different init code hash/address.
        MedallionHook unavailable = deployHook(address(0x456));
        assertEq(unavailable.anchorTick(), 0);
        assertEq(unavailable.anchorBlock(), block.number);
    }

    function testTopLevelBurnRetireAndPokeCannotRunInsideForeignUnlock() public {
        readyBurn();
        manager.setUnlocked(true);
        vm.expectRevert(MedallionHook.ManagerUnlocked.selector);
        hook.burnIMD(false, 0);
        vm.expectRevert(MedallionHook.ManagerUnlocked.selector);
        hook.retire();
        vm.expectRevert(MedallionHook.ManagerUnlocked.selector);
        hook.pokeAnchor();
        assertLedger();
    }

    function testStatusBurnAmountTruncatesOneDecimal() public {
        readyBurn();
        manager.setOutput(123.49999 ether);
        hook.burnIMD(false, 0);
        hook.retire();
        assertEq(
            hook.status(),
            "RETIRED. Medallion #447 is at 0x...dEaD. 1.64 ETH paid. Every fee buys $IMD and sends it there. IMD burned so far: 123.4."
        );
    }

    function testFuzzAnchorMovementBound(uint24 elapsedSeed, int24 targetSeed) public {
        uint256 elapsed = bound(elapsedSeed, 0, 100000);
        int24 target = int24(bound(int256(targetSeed), -887272, 887272));
        manager.setSpot(hook.burnPoolKey(false), target);
        vm.roll(block.number + elapsed);
        int24 result = hook.pokeAnchor();
        assertLe(uint256(result < 0 ? -int256(result) : int256(result)), elapsed * 200);
        assertEq(hook.pokeAnchor(), result);
        if (target < 0) assertGe(result, target);
        else assertLe(result, target);
    }
}
