//SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {Test} from "lib/forge-std/src/Test.sol";
import {MTKEngine} from "src/MTKEngine.sol";
import {BasketPrice} from "src/BasketPrice.sol";
import {MultiToken} from "src/MultiToken.sol";
import {ERC20Mock } from "./mocks/ERC20Mock.sol";
import {HelperConfig} from "script/HelperConfig.s.sol";
import {MockV3Aggregator} from "./mocks/MockV3Aggregator.sol";
import {VolatilityShield} from "src/VolatilityShield.sol";
import {MockPyth} from "./mocks/MockPyth.sol";

contract MTKEngineTest is Test {
    
    MTKEngine mtkEngine;
    BasketPrice basketPrice;
    MultiToken multiToken;
    ERC20Mock collateral;
    ERC20Mock collateral2; // Used to decouple basket price from single collateral price
    MockV3Aggregator mockV3Aggregator;
    MockV3Aggregator mockV3Aggregator2;
    HelperConfig helperConfig;
    VolatilityShield volatilityShield;
    MockPyth mockPyth;

    bytes32 constant PRICE_ID = bytes32(uint256(1));
    address user = makeAddr("user");
    address liquidator = makeAddr("liquidator");
    uint256 constant STARTING_BALANCE = 100 ether;

    function setUp() public {
        helperConfig = new HelperConfig();
        basketPrice = new BasketPrice(address(helperConfig));
        multiToken = new MultiToken(); 
        
        collateral = new ERC20Mock("MockCollateral", "MCL", user, STARTING_BALANCE);
        mockV3Aggregator = new MockV3Aggregator(8, 2000e8);
        helperConfig.addConfig(address(collateral), address(mockV3Aggregator));

        collateral2 = new ERC20Mock("Stable", "STB", user, STARTING_BALANCE);
        mockV3Aggregator2 = new MockV3Aggregator(8, 2000e8);
        helperConfig.addConfig(address(collateral2), address(mockV3Aggregator2));

        // Deploy MockPyth with LOW volatility defaults: price=2000, conf=10, expo=-2
        mockPyth = new MockPyth(2000, 10, -2);
        volatilityShield = new VolatilityShield(address(mockPyth), PRICE_ID);

        address[] memory cTokens = new address[](2);
        cTokens[0] = address(collateral);
        cTokens[1] = address(collateral2);

        mtkEngine = new MTKEngine(
            address(basketPrice),
            address(multiToken),
            address(helperConfig),
            address(volatilityShield),
            cTokens
        );
        
        multiToken.transferOwnership(address(mtkEngine));
        basketPrice.addFeed(address(collateral), 100); // weight 100
        basketPrice.addFeed(address(collateral2), 100); // weight 100
        // Initial Basket Price: 100 * 2000 + 100 * 2000 = 4000e18
        
        collateral.mint(user, STARTING_BALANCE);
        collateral2.mint(user, STARTING_BALANCE);

        // Give liquidator some MTK to perform liquidations
        // We'll just mint collateral to them, let them deposit to get MTK
        collateral.mint(liquidator, STARTING_BALANCE);
    }

    // ──────────────────────────────────────────────
    //  Original Deposit Tests (LOW volatility)
    // ──────────────────────────────────────────────

    function testDepositWithdrawIfAmountLessThanZero() external {
        vm.startPrank(user);
        vm.expectRevert(MTKEngine.MTKEngine__AmountMustBeMoreThanZero.selector);
        mtkEngine.deposit(address(collateral),0);
        vm.stopPrank();
    }

    function testDepositRevertsOnCollateralNotAllowed() public {
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
        mtkEngine.deposit(address(collateral), 10 ether);

        assertEq(mtkEngine.userCollateralBalance(user, block.chainid, address(collateral)), 10 ether);
        
        // Base CR = 2.0. effectiveCR = 2.0 * (1 + 0.0025) = 2.005e18.
        // collateralUSD = 10 * 2000 = $20,000.
        // maxDebtUSD = $20,000 / 2.005 = $9975.0623
        // basketPrice = $4000
        // minted MTK = $9975.0623 / 4000 = ~2.4937 ether
        uint256 minted = multiToken.balanceOf(user);
        uint256 expectedMint = 20000 ether;
        expectedMint = (expectedMint * 1e18) / 2005000000000000000;
        expectedMint = (expectedMint * 1e18) / 2000e18; // Basket Price is $2000
        assertEq(minted, expectedMint, "Incorrect tokens minted based on CR");

        vm.stopPrank();
    }

    ///////////////////////////////
    //       Withdraw test       //
    ///////////////////////////////

    function testWithdrawSuccess() public {
        vm.startPrank(user);
        collateral.approve(address(mtkEngine), 10 ether);
        mtkEngine.deposit(address(collateral), 10 ether);
        
        uint256 userBalance = multiToken.balanceOf(user);
        uint256 burnAmount = userBalance / 2; // burn half

        mtkEngine.withdraw(burnAmount, address(collateral));

        // Since we burned half the MTK, we should get half the USD value in collateral back
        assertLt(mtkEngine.userCollateralBalance(user, block.chainid, address(collateral)), 10 ether);
        vm.stopPrank();
    }

    function testWithdrawRevertsOnZeroBurnAmount() public {
        vm.startPrank(user);
        vm.expectRevert(MTKEngine.MTKEngine__AmountMustBeMoreThanZero.selector);
        mtkEngine.withdraw(0, address(collateral));
        vm.stopPrank();
    }

    function testWithdrawRevertsOnNotEnoughCollateral() public {
        vm.startPrank(user);
        collateral.approve(address(mtkEngine), 10 ether);
        mtkEngine.deposit(address(collateral), 10 ether);
        // User has 10 ether collateral. To withdraw > 10 ether, they must burn > 10 ether MTK.
        uint256 tooMuchBurn = 11 ether;
        vm.expectRevert(MTKEngine.MTKEngine__NotEnoughCollateralBalance.selector);
        mtkEngine.withdraw(tooMuchBurn, address(collateral));
        vm.stopPrank();
    }

    // ──────────────────────────────────────────────
    //  Volatility Shield Integration Tests
    // ──────────────────────────────────────────────

    function testDepositMediumVolReducedMinting() public {
        mockPyth.setPrice(2000, 60, -2); // V=300 bps (MEDIUM)
        
        vm.startPrank(user);
        collateral.approve(address(mtkEngine), 10 ether);
        mtkEngine.deposit(address(collateral), 10 ether);

        uint256 minted = multiToken.balanceOf(user);
        // CR = 2.0 * (1 + 0.015) = 2.03
        // maxDebtUSD = 20000 / 2.03 = 9852.216
        // normalMint = 9852.216 / 4000 = 2.463
        // dampened = 2.463 * 0.5 = 1.2315
        uint256 effectiveCR = 2030000000000000000;
        uint256 normalMint = 20000 ether;
        normalMint = (normalMint * 1e18) / effectiveCR;
        normalMint = (normalMint * 1e18) / 2000e18; // Basket Price is $2000
        uint256 expectedMint = normalMint * 5e17 / 1e18; // 50% dampening
        
        assertEq(minted, expectedMint, "MEDIUM vol should dampen mint by 50%");
        vm.stopPrank();
    }

    function testDepositHighVolBlocksLargeMintAfterBootstrap() public {
        vm.startPrank(user);
        collateral.approve(address(mtkEngine), 10 ether);
        mtkEngine.deposit(address(collateral), 10 ether); // LOW vol bootstrap

        mockPyth.setPrice(2000, 200, -2); // V=1000 → HIGH
        
        // At HIGH vol, dampening is 10%, mintCap is 10% of total supply
        // Minting 50 ether collateral would try to mint ~1.25 ether MTK (after dampening)
        // Mint cap is 10% of existing ~2.49 ether = ~0.249 ether. 
        // 1.25 > 0.249 → blocked
        collateral.approve(address(mtkEngine), 50 ether);
        vm.expectRevert(MTKEngine.MTKEngine__MintingRestrictedHighVolatility.selector);
        mtkEngine.deposit(address(collateral), 50 ether);
        vm.stopPrank();
    }

    // ──────────────────────────────────────────────
    //  Health Factor & Liquidation Tests
    // ──────────────────────────────────────────────

    function testHealthFactorCalculatesCorrectly() public {
        vm.startPrank(user);
        collateral.approve(address(mtkEngine), 10 ether);
        mtkEngine.deposit(address(collateral), 10 ether);
        
        (uint256 totalCollateralValueUSD, uint256 totalDebt) = mtkEngine.getAccountInformation(user);
        assertEq(totalCollateralValueUSD, 20000 ether); // 10 ether * $2000
        assertEq(totalDebt, multiToken.balanceOf(user));
        
        vm.stopPrank();
    }

    function testRedeemCollateralRevertsIfHealthFactorBroken() public {
        vm.startPrank(user);
        collateral.approve(address(mtkEngine), 10 ether);
        mtkEngine.deposit(address(collateral), 10 ether);
        
        // Withdrawing 5 ether without burning any MTK will definitely break the health factor
        // 10 ether in -> CR is 200%. If we take out 5 ether, CR drops to 100%.
        // LIQUIDATION_THRESHOLD is 150%.
        vm.expectRevert(); // MTKEngine__BreaksHealthFactor
        mtkEngine.redeemCollateral(address(collateral), 5 ether);
        
        vm.stopPrank();
    }

    function testLiquidationRevertsIfHealthIsOk() public {
        vm.startPrank(user);
        collateral.approve(address(mtkEngine), 10 ether);
        mtkEngine.deposit(address(collateral), 10 ether);
        vm.stopPrank();

        vm.prank(liquidator);
        vm.expectRevert(MTKEngine.MTKEngine__HealthFactorOk.selector);
        mtkEngine.liquidate(address(collateral), user, 1 ether);
    }

    function testLiquidationSuccessfullyImprovesHealth() public {
        // 1. User deposits and mints
        vm.startPrank(user);
        collateral.approve(address(mtkEngine), 10 ether);
        mtkEngine.deposit(address(collateral), 10 ether);
        uint256 debtToCover = multiToken.balanceOf(user) / 2;
        vm.stopPrank();

        // 2. Liquidator gets MTK ready
        vm.startPrank(liquidator);
        collateral.approve(address(mtkEngine), 50 ether);
        mtkEngine.deposit(address(collateral), 50 ether);
        vm.stopPrank();

        // 3. Drop collateral price to put user under-collateralized
        // Drop MCL price from 2000 to 1000.
        // New MCL value = 10 * 1000 = $10,000.
        // New Basket Price = (100 * 1000 + 100 * 2000) / 200 = $1500.
        // Debt USD = ~4.98 * 1500 = $7,470.
        // New CR = 10,000 / 7,470 = ~133% (< 150%)
        mockV3Aggregator.updateAnswer(1000e8);

        // 4. Liquidate
        uint256 liquidatorColBalanceBefore = collateral.balanceOf(liquidator);
        
        vm.prank(liquidator);
        mtkEngine.liquidate(address(collateral), user, debtToCover);

        // 5. Verify balances
        uint256 liquidatorColBalanceAfter = collateral.balanceOf(liquidator);
        assertGt(liquidatorColBalanceAfter, liquidatorColBalanceBefore, "Liquidator should receive collateral");
        
        uint256 newDebt = mtkEngine.userDebtBalance(user);
        assertLt(newDebt, debtToCover * 2, "User debt should be reduced");
    }
}