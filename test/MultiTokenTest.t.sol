//SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {MultiToken} from "src/MultiToken.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Test} from "lib/forge-std/src/Test.sol";

contract MultiTokenTest is Test {
    MultiToken token;
    uint256 constant AMOUNT=0.1 ether;
    address user = makeAddr("user");
    function setUp() external{

        token=new MultiToken();
        
    }


    ////////////////////////////
    //       Mint test        //
    ////////////////////////////

    function testRevertedMintIfAddressZero() external{
        vm.expectRevert(MultiToken.MultiToken__ZeroAddress.selector);
        token.mint(address(0),AMOUNT);
    }

    function testErrorIfMintByNotOwner() external{
        vm.startPrank(user);
        vm.expectRevert();
        token.mint(user,AMOUNT);
        vm.stopPrank();
    }

    function testUserCantMintIfAmountZero() external {
        vm.expectRevert(MultiToken.MultiToken__AmountMustBeGreaterThanZero.selector);
        token.mint(user,0);
    }

    function testReturnsTrueIfMintSuccessful() external {
        bool value=token.mint(user,AMOUNT);
        assertEq(value,true);
    }



    ////////////////////////////
    //        burn test       //
    ////////////////////////////

    function testErrorRevertedBurnIfAddressZero() external{
        vm.expectRevert(MultiToken.MultiToken__ZeroAddress.selector);
        token.burn(address(0),AMOUNT);
    }

    function testErrorIfBurnByNotOwner() external{
        vm.startPrank(user);
        vm.expectRevert();
        token.burn(user,AMOUNT);
        vm.stopPrank();
    }

    function testUserCantBurnIfAmountZero() external {
        vm.expectRevert(MultiToken.MultiToken__AmountMustBeGreaterThanZero.selector);
        token.burn(user,0);
    }

    function testUserCantBurnIfExceedsBalance() external {
        token.mint(user,0.01 ether);
        vm.expectRevert(MultiToken.MultiToken__AmountExceedsBalance.selector);
        token.burn(user,AMOUNT);
    }

    function testReturnsTrueIfBurnSuccessful() external {
        token.mint(user,AMOUNT);
        bool value=token.burn(user,AMOUNT);
        assertEq(value,true);
    }


    ///////////////////////////
    //     transfer test     //
    ///////////////////////////


    function testUserCantTransferIfFromIsZero() external {
        
        token.mint(user,AMOUNT);
        vm.startPrank(user);
        vm.expectRevert(MultiToken.MultiToken__ZeroAddress.selector);
        token.transfer(address(0),AMOUNT);
    }

    function testUserCantTransferIfAmountIsZero() external {
        address user2=makeAddr("user2");
        token.mint(user,AMOUNT);
        vm.startPrank(user);
        vm.expectRevert(MultiToken.MultiToken__AmountMustBeGreaterThanZero.selector);
        token.transfer(user2,0);
    }

    function testUserCantTransferIfAmountExceedsBalance() external {
        address user2=makeAddr("user2");
        token.mint(user,0.01 ether);
        vm.startPrank(user);
        vm.expectRevert(MultiToken.MultiToken__AmountExceedsBalance.selector);
        token.transfer(user2,AMOUNT);
    }

    function testReturnsTrueIfTransferSuccessful() external {
        address user2=makeAddr("user2");
        token.mint(user,AMOUNT);
        vm.startPrank(user);
        
        bool value=token.transfer(user2,AMOUNT);
        assertEq(value,true);
    }

    ///////////////////////////////////
    //      transferfrom test        //
    ///////////////////////////////////
    function testUserCantTransferFromIfAddressIsZero() external {
        
        token.mint(user,AMOUNT);
        vm.startPrank(user);
        vm.expectRevert(MultiToken.MultiToken__ZeroAddress.selector);
        token.transferFrom(user,address(0),AMOUNT);
    }

    function testUserCantTransferFromIfAmountIsZero() external {
        address user2=makeAddr("user2");
        token.mint(user,AMOUNT);
        vm.startPrank(user);
        vm.expectRevert(MultiToken.MultiToken__AmountMustBeGreaterThanZero.selector);
        token.transferFrom(user,user2,0);
    }

    function testUserCantTransferFromIfAmountExceedsBalance() external {
        address user2=makeAddr("user2");
        token.mint(user,0.01 ether);
        vm.startPrank(user);
        vm.expectRevert(MultiToken.MultiToken__AmountExceedsBalance.selector);
        token.transferFrom(user,user2,AMOUNT);
    }

    function testReturnsTrueIfTransferFromSuccessful() external {
        address user2=makeAddr("user2");
        token.mint(user,AMOUNT);
        vm.startPrank(user);
        
        bool value=token.transferFrom(user,user2,0.01 ether);
        assertEq(value,true);
    }

}