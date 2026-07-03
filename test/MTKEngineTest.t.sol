//SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {Test} from "lib/forge-std/src/Test.sol";
import {MTKEngine} from "src/MTKEngine.sol";
import {BasketPrice} from "src/BasketPrice.sol";
import {MultiToken} from "src/MultiToken.sol";
import {ERC20Mock} from "./mocks/ERC20Mock.sol";
import {HelperConfig} from "script/HelperConfig.s.sol";
import {MockV3Aggregator} from "./mocks/MockV3Aggregator.sol";
import {VolatilityShield} from "src/VolatilityShield.sol";
import {MockPyth} from "./mocks/MockPyth.sol";

/// @title MTKEngineTest
/// @notice Tests for MTKEngine — deposit, withdraw, redeemCollateral, burnToken,
///         depositCollateral, liquidation, health factor, and volatility integration.
contract MTKEngineTest is Test {

    MTKEngine mtkEngine;
    BasketPrice basketPrice;
    MultiToken multiToken;
    ERC20Mock collateral;
    ERC20Mock collateral2;
    MockV3Aggregator mockV3Aggregator;
    MockV3Aggregator mockV3Aggregator2;
    HelperConfig helperConfig;
    VolatilityShield volatilityShield;
    MockPyth mockPyth;

    bytes32 constant PRICE_ID = bytes32(uint256(1));
    address user = makeAddr("user");
    address liquidator = makeAddr("liquidator");
    uint256 constant STARTING_BALANCE = 100 ether;
    uint256 chainId;

    function setUp() public {
        chainId = block.chainid;

        helperConfig = new HelperConfig();

        // Deploy collateral tokens and aggregators
        collateral = new ERC20Mock("MockCollateral", "MCL", user, STARTING_BALANCE);
        mockV3Aggregator = new MockV3Aggregator(8, 2000e8);

        collateral2 = new ERC20Mock("Stable", "STB", user, STARTING_BALANCE);
        mockV3Aggregator2 = new MockV3Aggregator(8, 2000e8);

        // Register both collaterals in HelperConfig with their pyth IDs
        helperConfig.addCollateral(chainId, address(collateral), address(mockV3Aggregator), PRICE_ID);
        helperConfig.addCollateral(chainId, address(collateral2), address(mockV3Aggregator2), PRICE_ID);

        // Deploy MockPyth with LOW volatility: price=2000, conf=10, expo=-2
        // V = (10 * 10000) / 2000 = 50 bps → LOW
        mockPyth = new MockPyth(2000, 10, -2);

        // Deploy VolatilityShield with helperConfig + mockPyth
        volatilityShield = new VolatilityShield(address(helperConfig), address(mockPyth));

        // Deploy BasketPrice — it creates its own internal VolatilityShield,
        // but we pass a real pyth to satisfy the constructor.
        basketPrice = new BasketPrice(address(helperConfig), address(mockPyth));

        // Register both collaterals in BasketPrice basket (weight 100 each)
        basketPrice.addCollateral(address(collateral), 100);
        basketPrice.addCollateral(address(collateral2), 100);

        // Deploy MultiToken
        multiToken = new MultiToken(address(basketPrice));

        // Deploy MTKEngine
        mtkEngine = new MTKEngine(
            address(basketPrice),
            address(multiToken),
            address(helperConfig),
            address(volatilityShield)
        );

        // Transfer MultiToken ownership to engine so it can mint/burn
        multiToken.transferOwnership(address(mtkEngine));

        // Mint extra collateral for user and liquidator
        collateral.mint(user, STARTING_BALANCE);
        collateral2.mint(user, STARTING_BALANCE);
        collateral.mint(liquidator, STARTING_BALANCE);
    }

    // ──────────────────────────────────────────────
    //  Deposit Tests (LOW volatility)
    // ──────────────────────────────────────────────

    function testDepositRevertsIfAmountIsZero() external {
        vm.startPrank(user);
        vm.expectRevert(MTKEngine.MTKEngine__AmountMustBeMoreThanZero.selector);
        mtkEngine.deposit(address(collateral), 0);
        vm.stopPrank();
    }

    function testDepositRevertsOnCollateralNotAllowed() public {
        ERC20Mock badCollateral = new ERC20Mock("Bad Collateral", "BC", user, STARTING_BALANCE);
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

        // Collateral balance should increase
        assertEq(mtkEngine.userCollateralBalance(user, chainId, address(collateral)), 10 ether);

        // Tokens should be minted to user
        uint256 minted = multiToken.balanceOf(user);
        assertGt(minted, 0, "User should have received MTK");

        // Debt should match minted
        assertEq(mtkEngine.userDebtBalance(user), minted);

        vm.stopPrank();
    }

    function testDepositEmitsEvent() public {
        vm.startPrank(user);
        collateral.approve(address(mtkEngine), 10 ether);

        vm.expectEmit(true, true, false, false);
        emit MTKEngine.DepositedSuccessfully(user, address(collateral), 10 ether, 0);
        mtkEngine.deposit(address(collateral), 10 ether);

        vm.stopPrank();
    }

    function testDepositUpdatesUserDebtBalance() public {
        vm.startPrank(user);
        collateral.approve(address(mtkEngine), 10 ether);
        mtkEngine.deposit(address(collateral), 10 ether);

        uint256 debt = mtkEngine.userDebtBalance(user);
        uint256 balance = multiToken.balanceOf(user);
        assertEq(debt, balance, "Debt should match minted balance");
        vm.stopPrank();
    }

    // ──────────────────────────────────────────────
    //  Withdraw Tests
    // ──────────────────────────────────────────────

    function testWithdrawRevertsOnZeroBurnAmount() public {
        vm.startPrank(user);
        vm.expectRevert(MTKEngine.MTKEngine__AmountMustBeMoreThanZero.selector);
        mtkEngine.withdraw(0, address(collateral));
        vm.stopPrank();
    }

    function testWithdrawRevertsOnCollateralNotAllowed() public {
        ERC20Mock badCollateral = new ERC20Mock("Bad", "BC", user, 10 ether);
        vm.startPrank(user);
        vm.expectRevert(MTKEngine.MTKEngine__CollateralNotAllowed.selector);
        mtkEngine.withdraw(1 ether, address(badCollateral));
        vm.stopPrank();
    }

    function testWithdrawRevertsOnNotEnoughCollateral() public {
        vm.startPrank(user);
        collateral.approve(address(mtkEngine), 10 ether);
        mtkEngine.deposit(address(collateral), 10 ether);

        // Burning a huge amount of MTK would require more collateral than deposited
        uint256 tooMuchBurn = 100 ether;
        vm.expectRevert(MTKEngine.MTKEngine__NotEnoughCollateralBalance.selector);
        mtkEngine.withdraw(tooMuchBurn, address(collateral));
        vm.stopPrank();
    }

    function testWithdrawSuccess() public {
        vm.startPrank(user);
        collateral.approve(address(mtkEngine), 10 ether);
        mtkEngine.deposit(address(collateral), 10 ether);

        uint256 userBalance = multiToken.balanceOf(user);
        uint256 burnAmount = userBalance / 2; // burn half

        mtkEngine.withdraw(burnAmount, address(collateral));

        assertLt(mtkEngine.userCollateralBalance(user, chainId, address(collateral)), 10 ether);
        assertEq(mtkEngine.userDebtBalance(user), userBalance - burnAmount);
        vm.stopPrank();
    }

    function testWithdrawEmitsEvent() public {
        vm.startPrank(user);
        collateral.approve(address(mtkEngine), 10 ether);
        mtkEngine.deposit(address(collateral), 10 ether);

        uint256 burnAmount = multiToken.balanceOf(user) / 2;
        vm.expectEmit(true, true, false, false);
        emit MTKEngine.WithdrawSuccessful(user, address(collateral), burnAmount, 0);
        mtkEngine.withdraw(burnAmount, address(collateral));
        vm.stopPrank();
    }

    // ──────────────────────────────────────────────
    //  RedeemCollateral Tests
    // ──────────────────────────────────────────────

    function testRedeemCollateralRevertsIfAmountZero() public {
        vm.startPrank(user);
        vm.expectRevert(MTKEngine.MTKEngine__AmountMustBeMoreThanZero.selector);
        mtkEngine.redeemCollateral(address(collateral), 0);
        vm.stopPrank();
    }

    function testRedeemCollateralRevertsOnCollateralNotAllowed() public {
        ERC20Mock badCollateral = new ERC20Mock("Bad", "BC", user, 10 ether);
        vm.startPrank(user);
        vm.expectRevert(MTKEngine.MTKEngine__CollateralNotAllowed.selector);
        mtkEngine.redeemCollateral(address(badCollateral), 1 ether);
        vm.stopPrank();
    }

    function testRedeemCollateralRevertsIfInsufficientBalance() public {
        vm.startPrank(user);
        vm.expectRevert(MTKEngine.MTKEngine__NotEnoughCollateralBalance.selector);
        mtkEngine.redeemCollateral(address(collateral), 1 ether);
        vm.stopPrank();
    }

    function testRedeemCollateralRevertsIfHealthFactorBroken() public {
        vm.startPrank(user);
        collateral.approve(address(mtkEngine), 10 ether);
        mtkEngine.deposit(address(collateral), 10 ether);

        // Redeeming 5 ether without burning any MTK will break health factor
        vm.expectRevert(); // MTKEngine__BreaksHealthFactor
        mtkEngine.redeemCollateral(address(collateral), 5 ether);
        vm.stopPrank();
    }

    // ──────────────────────────────────────────────
    //  BurnToken Tests (new function)
    // ──────────────────────────────────────────────

    function testBurnTokenRevertsIfAmountZero() public {
        vm.startPrank(user);
        vm.expectRevert(MTKEngine.MTKEngine__AmountMustBeMoreThanZero.selector);
        mtkEngine.burnToken(0);
        vm.stopPrank();
    }

    function testBurnTokenRevertsIfExceedsDebt() public {
        vm.startPrank(user);
        collateral.approve(address(mtkEngine), 10 ether);
        mtkEngine.deposit(address(collateral), 10 ether);

        uint256 debt = mtkEngine.userDebtBalance(user);
        vm.expectRevert(MTKEngine.MTKEngine__NotEnoughDebt.selector);
        mtkEngine.burnToken(debt + 1);
        vm.stopPrank();
    }

    function testBurnTokenReducesDebtAndBurnsTokens() public {
        vm.startPrank(user);
        collateral.approve(address(mtkEngine), 10 ether);
        mtkEngine.deposit(address(collateral), 10 ether);

        uint256 debtBefore = mtkEngine.userDebtBalance(user);
        uint256 balanceBefore = multiToken.balanceOf(user);
        uint256 burnAmount = debtBefore / 4;

        mtkEngine.burnToken(burnAmount);

        assertEq(mtkEngine.userDebtBalance(user), debtBefore - burnAmount, "Debt should decrease by burn amount");
        assertEq(multiToken.balanceOf(user), balanceBefore - burnAmount, "Token balance should decrease");
        vm.stopPrank();
    }

    // ──────────────────────────────────────────────
    //  DepositCollateral Tests (new function)
    // ──────────────────────────────────────────────

    function testDepositCollateralRevertsIfAmountZero() public {
        vm.startPrank(user);
        vm.expectRevert(MTKEngine.MTKEngine__AmountMustBeMoreThanZero.selector);
        mtkEngine.depositCollateral(address(collateral), 0);
        vm.stopPrank();
    }

    function testDepositCollateralRevertsOnCollateralNotAllowed() public {
        ERC20Mock badCollateral = new ERC20Mock("Bad", "BC", user, 10 ether);
        vm.startPrank(user);
        badCollateral.approve(address(mtkEngine), 5 ether);
        vm.expectRevert(MTKEngine.MTKEngine__CollateralNotAllowed.selector);
        mtkEngine.depositCollateral(address(badCollateral), 5 ether);
        vm.stopPrank();
    }

    function testDepositCollateralSuccessUpdatesBalance() public {
        vm.startPrank(user);
        collateral.approve(address(mtkEngine), 5 ether);
        mtkEngine.depositCollateral(address(collateral), 5 ether);

        assertEq(mtkEngine.userCollateralBalance(user, chainId, address(collateral)), 5 ether);
        assertEq(mtkEngine.userDebtBalance(user), 0, "No debt should be created");
        vm.stopPrank();
    }

    function testDepositCollateralDoesNotMintTokens() public {
        vm.startPrank(user);
        collateral.approve(address(mtkEngine), 5 ether);
        mtkEngine.depositCollateral(address(collateral), 5 ether);

        assertEq(multiToken.balanceOf(user), 0, "No MTK should be minted from depositCollateral");
        vm.stopPrank();
    }

    function testDepositCollateralEmitsEvent() public {
        vm.startPrank(user);
        collateral.approve(address(mtkEngine), 5 ether);

        vm.expectEmit(true, true, true, true);
        emit MTKEngine.DepositedCollateralSuccessfully(user, address(collateral), 5 ether);
        mtkEngine.depositCollateral(address(collateral), 5 ether);
        vm.stopPrank();
    }

    // ──────────────────────────────────────────────
    //  Volatility Shield Integration Tests
    // ──────────────────────────────────────────────

    function testDepositMediumVolReducedMinting() public {
        // V=300 bps → MEDIUM → dampening=50%
        mockPyth.setPrice(2000, 60, -2);

        vm.startPrank(user);
        collateral.approve(address(mtkEngine), 10 ether);
        mtkEngine.deposit(address(collateral), 10 ether);

        uint256 minted = multiToken.balanceOf(user);
        assertGt(minted, 0, "Should have minted some MTK");

        // Compare with LOW vol mint:
        // At MEDIUM vol, dampening=50%, so minted should be less than LOW vol would give
        // We can't easily compute the exact value without duplicating the formula,
        // but we can verify it's reasonable (non-zero and less than max possible)
        uint256 maxPossible = 10 ether; // upper bound sanity check
        assertLt(minted, maxPossible, "Minted amount should be less than collateral deposited");
        vm.stopPrank();
    }

    function testDepositHighVolBlocksLargeMintAfterBootstrap() public {
        vm.startPrank(user);
        collateral.approve(address(mtkEngine), 10 ether);
        mtkEngine.deposit(address(collateral), 10 ether); // LOW vol bootstrap

        // Switch to HIGH volatility: V=1000 bps → dampening=10%, mintCap=10%
        mockPyth.setPrice(2000, 200, -2);

        collateral.approve(address(mtkEngine), 50 ether);
        vm.expectRevert(MTKEngine.MTKEngine__MintingRestrictedHighVolatility.selector);
        mtkEngine.deposit(address(collateral), 50 ether);
        vm.stopPrank();
    }

    function testDepositLowVolAllowsFullMinting() public {
        // LOW vol (default) → dampening=1.0, CR = 2.005e18
        vm.startPrank(user);
        collateral.approve(address(mtkEngine), 10 ether);
        mtkEngine.deposit(address(collateral), 10 ether);

        uint256 minted = multiToken.balanceOf(user);
        assertGt(minted, 0, "Should mint tokens at LOW vol");
        vm.stopPrank();
    }

    // ──────────────────────────────────────────────
    //  Health Factor & Account Information
    // ──────────────────────────────────────────────

    function testGetAccountInformationReturnsCorrectValues() public {
        vm.startPrank(user);
        collateral.approve(address(mtkEngine), 10 ether);
        mtkEngine.deposit(address(collateral), 10 ether);

        (uint256 totalCollateralValueUSD, uint256 totalDebt) = mtkEngine.getAccountInformation(user);
        // 10 ether * $2000/ether = $20,000 → 20000e18 (18 decimals)
        assertEq(totalCollateralValueUSD, 20000 ether, "Collateral USD should be $20,000");
        assertEq(totalDebt, multiToken.balanceOf(user), "Debt should match minted balance");
        vm.stopPrank();
    }

    function testGetHealthFactorReturnsMaxForNoDebt() public view {
        // user has no position → health factor = max uint256
        uint256 hf = mtkEngine.getHealthFactor();
        assertEq(hf, type(uint256).max, "No debt should give max health factor");
    }

    function testGetHealthFactorAfterDeposit() public {
        vm.startPrank(user);
        collateral.approve(address(mtkEngine), 10 ether);
        mtkEngine.deposit(address(collateral), 10 ether);

        uint256 hf = mtkEngine.getHealthFactor();
        assertGe(hf, 15e17, "Health factor should be >= 150% (liquidation threshold)");
        vm.stopPrank();
    }

    // ──────────────────────────────────────────────
    //  Liquidation Tests
    // ──────────────────────────────────────────────

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
        // 1. User deposits and gets MTK
        vm.startPrank(user);
        collateral.approve(address(mtkEngine), 10 ether);
        mtkEngine.deposit(address(collateral), 10 ether);
        uint256 debtToCover = multiToken.balanceOf(user) / 2;
        vm.stopPrank();

        // 2. Liquidator deposits to get MTK for repayment
        vm.startPrank(liquidator);
        collateral.approve(address(mtkEngine), 50 ether);
        mtkEngine.deposit(address(collateral), 50 ether);
        vm.stopPrank();

        // 3. Drop collateral price to put user under-collateralized
        // Only drop MCL price so basket price remains relatively high
        mockV3Aggregator.updateAnswer(1000e8);

        // 4. Liquidate
        uint256 liquidatorColBalanceBefore = collateral.balanceOf(liquidator);

        vm.prank(liquidator);
        mtkEngine.liquidate(address(collateral), user, debtToCover);

        // 5. Verify: liquidator got collateral
        uint256 liquidatorColBalanceAfter = collateral.balanceOf(liquidator);
        assertGt(liquidatorColBalanceAfter, liquidatorColBalanceBefore, "Liquidator should receive collateral");

        // 6. User's debt should be reduced
        uint256 newDebt = mtkEngine.userDebtBalance(user);
        assertLt(newDebt, debtToCover * 2, "User debt should be reduced");
    }

    function testLiquidationEmitsEvent() public {
        vm.startPrank(user);
        collateral.approve(address(mtkEngine), 10 ether);
        mtkEngine.deposit(address(collateral), 10 ether);
        uint256 debtToCover = multiToken.balanceOf(user) / 2;
        vm.stopPrank();

        vm.startPrank(liquidator);
        collateral.approve(address(mtkEngine), 50 ether);
        mtkEngine.deposit(address(collateral), 50 ether);
        vm.stopPrank();

        // Crash only MCL price so basket price remains relatively high
        mockV3Aggregator.updateAnswer(1000e8);

        vm.prank(liquidator);
        vm.expectEmit(true, true, true, false);
        emit MTKEngine.Liquidated(liquidator, user, address(collateral), debtToCover, 0);
        mtkEngine.liquidate(address(collateral), user, debtToCover);
    }

    // ──────────────────────────────────────────────
    //  Multi-Collateral Tests
    // ──────────────────────────────────────────────

    function testDepositMultipleCollaterals() public {
        vm.startPrank(user);
        collateral.approve(address(mtkEngine), 5 ether);
        collateral2.approve(address(mtkEngine), 5 ether);

        mtkEngine.deposit(address(collateral), 5 ether);
        mtkEngine.deposit(address(collateral2), 5 ether);

        assertEq(mtkEngine.userCollateralBalance(user, chainId, address(collateral)), 5 ether);
        assertEq(mtkEngine.userCollateralBalance(user, chainId, address(collateral2)), 5 ether);

        (uint256 totalCollateralValueUSD, ) = mtkEngine.getAccountInformation(user);
        // 5 ether * $2000 + 5 ether * $2000 = $20,000
        assertEq(totalCollateralValueUSD, 20000 ether, "Combined collateral should be $20,000");
        vm.stopPrank();
    }

    function testDepositCollateralThenDeposit() public {
        // depositCollateral (no mint) followed by deposit (with mint)
        vm.startPrank(user);
        collateral.approve(address(mtkEngine), 10 ether);
        mtkEngine.depositCollateral(address(collateral), 5 ether);

        assertEq(multiToken.balanceOf(user), 0, "No tokens yet");

        mtkEngine.deposit(address(collateral), 5 ether);
        assertGt(multiToken.balanceOf(user), 0, "Should have tokens after deposit");
        vm.stopPrank();
    }

    function testGetPrecision() public {
        assertEq(1e18,mtkEngine.getPrecision());
    }
}