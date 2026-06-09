//SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {Test} from "lib/forge-std/src/Test.sol";
import {MTKEngine} from "src/MTKEngine.sol";
import {BasketPrice} from "src/BasketPrice.sol";
import {MultiToken} from "src/MultiToken.sol";
import {ERC20Mock } from "./mocks/ERC20Mock.sol";
import {HelperConfig} from "script/HelperConfig.s.sol";
import {MockV3Aggregator} from "./mocks/MockV3Aggregator.sol";
contract MTKEngineTest is Test {
    
    
    MTKEngine mtkEngine;
    BasketPrice basketPrice;
    MultiToken multiToken;
    ERC20Mock collateral;
    MockV3Aggregator mockV3Aggregator;
    HelperConfig helperConfig;

    address user = makeAddr("user");
    uint256 constant STARTING_BALANCE = 100 ether;


    function setUp() public {
        basketPrice = new BasketPrice();
        multiToken = new MultiToken(); 
        collateral =new ERC20Mock("MockCollateral","MCL",user,STARTING_BALANCE);
        helperConfig = new HelperConfig();
        mockV3Aggregator = new MockV3Aggregator(8,2000e8);
        helperConfig.addConfig(address(collateral),address(mockV3Aggregator));
        mtkEngine = new MTKEngine(address(basketPrice),address(multiToken),address(collateral),address(helperConfig));
        multiToken.transferOwnership(address(mtkEngine));
        basketPrice.addFeed(address(mockV3Aggregator),100);
        collateral.mint(user,STARTING_BALANCE);
    }

    function testDepositWithdrawIfAmountLessThanZero() external {
        vm.startPrank(user);
        vm.expectRevert(MTKEngine.MTKEngine__AmountMustBeMoreThanZero.selector);
        mtkEngine.deposit(address(collateral),0);
        vm.stopPrank();
    }

    function testDepositRevertsOnCollateralNotAllowed() public {
        // Deploy another collateral not registered
        ERC20Mock badCollateral = new ERC20Mock("Bad Collateral", "BC",user,STARTING_BALANCE);
        badCollateral.mint(user, 10 ether);

        vm.startPrank(user);
        badCollateral.approve(address(mtkEngine), 10 ether);

        vm.expectRevert(MTKEngine.MTKEngine__CollateralNotAllowed.selector);
        mtkEngine.deposit(address(badCollateral), 10 ether);

        vm.stopPrank();
    }

    function testDepositMintsTokensAndUpdatesBalance() public {
        vm.startPrank(user);

        collateral.approve(address(mtkEngine), 10 ether);

        vm.expectEmit(true, true, false, false);
        emit MTKEngine.DepositedSuccessfully();

        mtkEngine.deposit(address(collateral), 10 ether);

        // Collateral balance updated
        assertEq(mtkEngine.userCollateralBalance(user, address(collateral)), 10 ether);

        // Stablecoin minted
        uint256 minted = multiToken.balanceOf(user);
        assertGt(minted, 0, "No tokens minted");

        vm.stopPrank();
    }

    function testDepositEmitsEvent() public {
        vm.startPrank(user);
        collateral.approve(address(mtkEngine), 5 ether);

        vm.expectEmit(true, true, false, false);
        emit MTKEngine.DepositedSuccessfully();

        mtkEngine.deposit(address(collateral), 5 ether);

        vm.stopPrank();
    }



    ///////////////////////////////
    //       Withdraw test       //
    ///////////////////////////////

    function testWithdrawSuccess() public {
        vm.startPrank(user);
        collateral.approve(address(mtkEngine),STARTING_BALANCE);
        mtkEngine.deposit(address(collateral),STARTING_BALANCE);
        uint256 burnAmount = multiToken.balanceOf(user) / 2; // burn half
        vm.expectEmit(true, true, false, false);
        emit MTKEngine.WithdrawSuccessful();

        mtkEngine.withdraw(burnAmount, address(collateral));

        // Collateral balance reduced
        assertLt(mtkEngine.userCollateralBalance(user, address(collateral)), STARTING_BALANCE);

        // Stablecoin burned
        assertEq(multiToken.balanceOf(user), burnAmount, "Half should remain");

        vm.stopPrank();
    }


    function testWithdrawRevertsOnZeroBurnAmount() public {
        vm.startPrank(user);
        vm.expectRevert(MTKEngine.MTKEngine__AmountMustBeGreaterThanZero.selector);
        mtkEngine.withdraw(0, address(collateral));
        vm.stopPrank();
    }

    function testWithdrawRevertsOnCollateralNotAllowed() public {
        ERC20Mock badCollateral = new ERC20Mock("Bad Collateral", "BC", user, 10 ether);

        vm.startPrank(user);
        vm.expectRevert(MTKEngine.MTKEngine__CollateralNotAllowed.selector);
        mtkEngine.withdraw(1 ether, address(badCollateral));
        vm.stopPrank();
    }

    function testWithdrawRevertsOnNotEnoughCollateral() public {
        vm.startPrank(user);
        collateral.approve(address(mtkEngine),STARTING_BALANCE);
        mtkEngine.deposit(address(collateral),STARTING_BALANCE);
        uint256 tooMuchBurn = multiToken.balanceOf(user) * 2; // more than minted
        vm.expectRevert(MTKEngine.MTKEngine__NotEnoughCollateralBalance.selector);
        mtkEngine.withdraw(tooMuchBurn, address(collateral));
        vm.stopPrank();
    }

    function testWithdrawEmitsEvent() public {
        
        vm.startPrank(user);
        collateral.approve(address(mtkEngine),STARTING_BALANCE);
        mtkEngine.deposit(address(collateral),STARTING_BALANCE);
        uint256 burnAmount = multiToken.balanceOf(user) / 4;
        vm.expectEmit(true, true, false, false);
        emit MTKEngine.WithdrawSuccessful();
        mtkEngine.withdraw(burnAmount, address(collateral));
        vm.stopPrank();
    }


    
}