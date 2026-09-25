// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {FareToken} from "../src/FareToken.sol";

contract FareTokenTest is Test {
    FareToken internal token;
    address internal constant ALICE = address(0xA11CE);
    address internal constant BOB = address(0xB0B);

    function setUp() public {
        token = new FareToken();
    }

    function testMetadataAndEntireFixedSupplyAtDeployer() public view {
        assertEq(token.name(), "Fare for Medallion 447");
        assertEq(token.symbol(), "FARE447");
        assertEq(token.decimals(), 18);
        assertEq(token.totalSupply(), 1e27);
        assertEq(token.balanceOf(address(this)), 1e27);
    }

    function testTransferApprovalAndFiniteAllowance() public {
        token.approve(ALICE, 10 ether);
        vm.prank(ALICE);
        assertTrue(token.transferFrom(address(this), BOB, 4 ether));
        assertEq(token.allowance(address(this), ALICE), 6 ether);
        assertEq(token.balanceOf(BOB), 4 ether);
        assertEq(token.balanceOf(address(this)), 1e27 - 4 ether);
        assertEq(token.totalSupply(), 1e27);
    }

    function testInfiniteAllowanceAndBurnFrom() public {
        token.approve(ALICE, type(uint256).max);
        vm.prank(ALICE);
        token.burnFrom(address(this), 20 ether);
        assertEq(token.allowance(address(this), ALICE), type(uint256).max);
        assertEq(token.totalSupply(), 1e27 - 20 ether);
        assertEq(token.balanceOf(address(this)), token.totalSupply());
    }

    function testInsufficientBalanceAllowanceAndZeroAddress() public {
        vm.expectRevert(FareToken.InsufficientAllowance.selector);
        vm.prank(ALICE);
        token.transferFrom(address(this), BOB, 1);
        vm.expectRevert(FareToken.InsufficientBalance.selector);
        vm.prank(ALICE);
        token.burn(1);
        vm.expectRevert(FareToken.ZeroAddress.selector);
        token.transfer(address(0), 1);
        vm.expectRevert(FareToken.ZeroAddress.selector);
        token.approve(address(0), 1);
        vm.expectRevert(FareToken.InsufficientAllowance.selector);
        vm.prank(ALICE);
        token.burnFrom(address(this), 1);
        assertEq(token.totalSupply(), 1e27);
    }

    function testRevertingBurnRestoresAllowance() public {
        vm.prank(ALICE);
        token.approve(BOB, 100);
        vm.prank(BOB);
        vm.expectRevert(FareToken.InsufficientBalance.selector);
        token.burnFrom(ALICE, 100);
        assertEq(token.allowance(ALICE, BOB), 100);
    }

    function testNoMintAdminPauseOrProxySelectorsEvenForDeployer() public {
        string[8] memory signatures = [
            "mint(address,uint256)",
            "mint(uint256)",
            "pause()",
            "owner()",
            "setOwner(address)",
            "transferOwnership(address)",
            "upgradeTo(address)",
            "initialize(address)"
        ];
        for (uint256 i; i < signatures.length; ++i) {
            (bool ok,) = address(token).call(abi.encodeWithSignature(signatures[i], ALICE, 1e27));
            assertFalse(ok);
        }
        assertEq(token.totalSupply(), 1e27);
        assertEq(token.balanceOf(ALICE), 0);
    }

    function testFuzzTransfersAndBurnsConserveSupply(uint96 transferSeed, uint96 burnSeed) public {
        uint256 amount = bound(transferSeed, 0, 1e27);
        uint256 burned = bound(burnSeed, 0, amount);
        token.transfer(ALICE, amount);
        vm.startPrank(ALICE);
        token.transfer(ALICE, amount);
        token.burn(burned);
        vm.stopPrank();
        assertEq(token.balanceOf(ALICE), amount - burned);
        assertEq(token.totalSupply(), 1e27 - burned);
        assertEq(token.balanceOf(address(this)) + token.balanceOf(ALICE), token.totalSupply());
    }

    function testRuntimeOpcodeWalk() public view {
        bytes memory code = address(token).code;
        assertGt(code.length, 0);
        for (uint256 i; i < code.length; ++i) {
            uint8 op = uint8(code[i]);
            if (op >= 0x60 && op <= 0x7f) i += op - 0x5f;
            else assertTrue(op != 0xf2 && op != 0xf4 && op != 0xff);
        }
    }
}
