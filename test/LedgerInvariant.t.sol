// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {HookFixture} from "./HookFixture.sol";
import {Test} from "forge-std/Test.sol";
import {MedallionHook} from "../src/MedallionHook.sol";
import {AccountingManager} from "./mocks/AccountingManager.sol";
import {MockERC20, MockMedallion} from "./mocks/MainnetMocks.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {SwapParams} from "v4-core/src/types/PoolOperation.sol";
import {toBalanceDelta} from "v4-core/src/types/BalanceDelta.sol";

contract LedgerHandler is Test {
    MedallionHook public hook;
    AccountingManager public manager;
    PoolKey internal key;
    uint256 public ghostFees;
    uint256 public ghostDonations;

    constructor(MedallionHook h, AccountingManager m, PoolKey memory k) {
        hook = h;
        manager = m;
        key = k;
    }

    function trade(uint96 seed, bool buy, bool exactIn) external {
        uint256 basis = bound(seed, 50, 20 ether);
        uint256 fee = basis / 50;
        bool specified = buy == exactIn;
        int128 d0 = buy ? -int128(int256(basis)) : int128(int256(basis));
        if (specified) d0 += int128(int256(fee));
        int128 d1 = buy ? int128(int256(basis)) : -int128(int256(basis));
        manager.trade(hook, key, SwapParams(buy, exactIn ? -int256(basis) : int256(basis), 1), toBalanceDelta(d0, d1));
        ghostFees += fee;
    }

    function donate(uint96 seed) external {
        uint256 amount = bound(seed, 0, 10 ether);
        manager.donate(address(hook), amount);
        ghostDonations += amount;
    }

    function burn(bool via) external {
        vm.roll(block.number + 5);
        if (hook.burnable() < hook.MIN_BURN()) return;
        hook.burnIMD(via && hook.hasBurned(), 0);
    }

    function retire() external {
        if (!hook.retired() && hook.totalFees() >= hook.CREATOR_CAP()) hook.retire();
    }
}

contract LedgerInvariantTest is HookFixture {
    LedgerHandler internal handler;

    function setUp() public override {
        super.setUp();
        handler = new LedgerHandler(hook, manager, key);
        bytes4[] memory selectors = new bytes4[](4);
        selectors[0] = LedgerHandler.trade.selector;
        selectors[1] = LedgerHandler.donate.selector;
        selectors[2] = LedgerHandler.burn.selector;
        selectors[3] = LedgerHandler.retire.selector;
        targetSelector(FuzzSelector(address(handler), selectors));
        targetContract(address(handler));
    }

    function invariantLedgerSolventAndOnlySwapFeesCount() public view {
        assertEq(hook.totalFees(), handler.ghostFees());
        assertEq(
            manager.balanceOf(address(hook), 0),
            handler.ghostFees() + handler.ghostDonations() - hook.creatorPaid() - hook.burnSpent()
        );
        assertLedger();
    }

    function invariantCreatorReceivesOnlyCapWithRetiredNFT() public view {
        assertEq(CREATOR.balance, hook.creatorPaid());
        if (hook.retired()) {
            assertEq(MockMedallion(NFT).holder(), DEAD);
            assertEq(hook.creatorPaid(), CAP);
        } else {
            assertEq(hook.creatorPaid(), 0);
            assertEq(MockMedallion(NFT).holder(), CREATOR);
        }
    }

    function invariantBurnAccountingAndDestinations() public view {
        assertEq(hook.totalIMDBurned(), MockERC20(IMD).balanceOf(DEAD));
        assertEq(MockERC20(IMD).balanceOf(address(handler)), 0);
        assertEq(MockERC20(IMD).balanceOf(address(hook)), 0);
        if (hook.totalFees() <= CAP) {
            assertEq(hook.burnSpent(), 0);
            assertEq(hook.burnable(), 0);
        } else {
            assertLe(hook.burnSpent(), hook.totalFees() - CAP);
        }
    }
}
