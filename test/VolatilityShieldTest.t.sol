//SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {Test, console} from "lib/forge-std/src/Test.sol";
import {VolatilityShield} from "src/VolatilityShield.sol";
import {HelperConfig} from "script/HelperConfig.s.sol";
import {MockPyth} from "./mocks/MockPyth.sol";
import {MockV3Aggregator} from "./mocks/MockV3Aggregator.sol";
import {ERC20Mock} from "./mocks/ERC20Mock.sol";

/// @title VolatilityShieldTest
/// @notice Full test suite for VolatilityShield.
/// @dev Signature changes vs old tests:
///   getVolatilityIndex()           → getVolatilityIndex(chainId, collateral)
///   getEffectiveCollateralRatio()  → getEffectiveCollateralRatio(CRbase, collateral, chainId)
///   getDampeningFactor()           → getDampeningFactor(chainId, collateral)
///   checkMintAllowed()             → checkMintAllowed(chainId, collateral, mintAmount, totalSupply)
contract VolatilityShieldTest is Test {

    VolatilityShield volatilityShield;
    HelperConfig helperConfig;
    MockPyth mockPyth;
    ERC20Mock collateral;
    MockV3Aggregator mockV3Aggregator;

    bytes32 constant PRICE_ID = bytes32(uint256(1));
    address owner;
    address nonOwner = makeAddr("nonOwner");
    uint256 chainId;

    function setUp() public {
        owner = address(this);
        chainId = block.chainid;

        // Deploy HelperConfig and a mock collateral + aggregator
        helperConfig = new HelperConfig();
        collateral = new ERC20Mock("MockCollateral", "MCL", owner, 0);
        mockV3Aggregator = new MockV3Aggregator(8, 2000e8);

        // Register the collateral in HelperConfig with PRICE_ID for Pyth
        helperConfig.addCollateral(chainId, address(collateral), address(mockV3Aggregator), PRICE_ID);

        // Default: price = 2000, conf = 10 → V = (10 * 10000) / 2000 = 50 bps → LOW
        mockPyth = new MockPyth(2000, 10, -2);
        volatilityShield = new VolatilityShield(address(helperConfig), address(mockPyth));
    }

    // ──────────────────────────────────────────────
    //  Volatility Band Classification
    // ──────────────────────────────────────────────

    function testLowVolatilityBand() public view {
        // conf=10, price=2000 → V = 50 bps → LOW (< 200)
        (uint256 V, VolatilityShield.VolatilityBand band) = volatilityShield.getVolatilityIndex(chainId, address(collateral));
        assertEq(V, 50, "V should be 50 bps");
        assertEq(uint256(band), uint256(VolatilityShield.VolatilityBand.LOW), "Should be LOW band");
    }

    function testMediumVolatilityBand() public {
        // conf=60, price=2000 → V = 300 bps → MEDIUM (200 <= V < 500)
        mockPyth.setPrice(2000, 60, -2);
        (uint256 V, VolatilityShield.VolatilityBand band) = volatilityShield.getVolatilityIndex(chainId, address(collateral));
        assertEq(V, 300, "V should be 300 bps");
        assertEq(uint256(band), uint256(VolatilityShield.VolatilityBand.MEDIUM), "Should be MEDIUM band");
    }

    function testHighVolatilityBand() public {
        // conf=200, price=2000 → V = 1000 bps → HIGH (>= 500)
        mockPyth.setPrice(2000, 200, -2);
        (uint256 V, VolatilityShield.VolatilityBand band) = volatilityShield.getVolatilityIndex(chainId, address(collateral));
        assertEq(V, 1000, "V should be 1000 bps");
        assertEq(uint256(band), uint256(VolatilityShield.VolatilityBand.HIGH), "Should be HIGH band");
    }

    function testBoundaryLowToMedium() public {
        // conf=40, price=2000 → V = 200 bps → MEDIUM (threshold is <200 for LOW)
        mockPyth.setPrice(2000, 40, -2);
        (, VolatilityShield.VolatilityBand band) = volatilityShield.getVolatilityIndex(chainId, address(collateral));
        assertEq(uint256(band), uint256(VolatilityShield.VolatilityBand.MEDIUM), "200 bps should be MEDIUM");
    }

    function testBoundaryMediumToHigh() public {
        // conf=100, price=2000 → V = 500 bps → HIGH (threshold is <500 for MEDIUM)
        mockPyth.setPrice(2000, 100, -2);
        (, VolatilityShield.VolatilityBand band) = volatilityShield.getVolatilityIndex(chainId, address(collateral));
        assertEq(uint256(band), uint256(VolatilityShield.VolatilityBand.HIGH), "500 bps should be HIGH");
    }

    // ──────────────────────────────────────────────
    //  Effective Collateral Ratio Scaling
    // ──────────────────────────────────────────────

    function testEffectiveCRScalingLowVol() public view {
        // V=50 bps, alpha=5000/10000=0.5
        // scalingFactor = 1 + (5000 * 50) / (10000 * 10000) = 1.0025
        uint256 crEffective = volatilityShield.getEffectiveCollateralRatio(1e18, address(collateral), chainId);
        uint256 expected = 1e18 + (5000 * 50 * 1e18) / (10000 * 10000);
        assertEq(crEffective, expected, "CR should scale with V=50, alpha=0.5");
    }

    function testEffectiveCRScalingHighVol() public {
        // conf=200, price=2000 → V=1000 bps
        // scalingFactor = 1 + (5000 * 1000) / (10000 * 10000) = 1.05
        mockPyth.setPrice(2000, 200, -2);
        uint256 crEffective = volatilityShield.getEffectiveCollateralRatio(1e18, address(collateral), chainId);
        uint256 expected = 1e18 + (5000 * 1000 * 1e18) / (10000 * 10000);
        assertEq(crEffective, expected, "CR should scale with V=1000, alpha=0.5");
    }

    function testEffectiveCRWithCustomBase() public view {
        // CRbase = 1.5e18 (150%), V=50 bps
        uint256 crBase = 15e17;
        uint256 crEffective = volatilityShield.getEffectiveCollateralRatio(crBase, address(collateral), chainId);
        uint256 scalingFactor = 1e18 + (5000 * 50 * 1e18) / (10000 * 10000);
        uint256 expected = (crBase * scalingFactor) / 1e18;
        assertEq(crEffective, expected, "CR should scale proportionally to base");
    }

    function testEffectiveCRIncreasesWithHigherVolatility() public {
        uint256 crLow = volatilityShield.getEffectiveCollateralRatio(2e18, address(collateral), chainId);

        mockPyth.setPrice(2000, 200, -2); // HIGH vol
        uint256 crHigh = volatilityShield.getEffectiveCollateralRatio(2e18, address(collateral), chainId);

        assertGt(crHigh, crLow, "Higher volatility should increase effective CR");
    }

    // ──────────────────────────────────────────────
    //  Dampening Factor
    // ──────────────────────────────────────────────

    function testDampeningFactorLow() public view {
        uint256 factor = volatilityShield.getDampeningFactor(chainId, address(collateral));
        assertEq(factor, 1e18, "LOW vol dampening should be 1.0");
    }

    function testDampeningFactorMedium() public {
        mockPyth.setPrice(2000, 60, -2); // V=300 → MEDIUM
        uint256 factor = volatilityShield.getDampeningFactor(chainId, address(collateral));
        assertEq(factor, 5e17, "MEDIUM vol dampening should be 0.5");
    }

    function testDampeningFactorHigh() public {
        mockPyth.setPrice(2000, 200, -2); // V=1000 → HIGH
        uint256 factor = volatilityShield.getDampeningFactor(chainId, address(collateral));
        assertEq(factor, 1e17, "HIGH vol dampening should be 0.1");
    }

    // ──────────────────────────────────────────────
    //  System-Wide Functions
    // ──────────────────────────────────────────────

    function testGetSystemVolatilityIndexLow() public view {
        (uint256 V, VolatilityShield.VolatilityBand band) = volatilityShield.getSystemVolatilityIndex(chainId);
        assertEq(V, 50, "System V should be 50 bps");
        assertEq(uint256(band), uint256(VolatilityShield.VolatilityBand.LOW), "System band should be LOW");
    }

    function testGetSystemVolatilityIndexHigh() public {
        mockPyth.setPrice(2000, 200, -2); // V=1000 → HIGH
        (uint256 V, VolatilityShield.VolatilityBand band) = volatilityShield.getSystemVolatilityIndex(chainId);
        assertEq(V, 1000, "System V should be 1000 bps");
        assertEq(uint256(band), uint256(VolatilityShield.VolatilityBand.HIGH), "System band should be HIGH");
    }

    function testGetSystemDampeningFactorLow() public view {
        uint256 factor = volatilityShield.getSystemDampeningFactor(chainId);
        assertEq(factor, 1e18, "System dampening should be 1.0 for LOW");
    }

    function testGetSystemDampeningFactorHigh() public {
        mockPyth.setPrice(2000, 200, -2); // HIGH vol
        uint256 factor = volatilityShield.getSystemDampeningFactor(chainId);
        assertEq(factor, 1e17, "System dampening should be 0.1 for HIGH");
    }

    function testGetSystemEffectiveCollateralRatio() public view {
        uint256 crEffective = volatilityShield.getSystemEffectiveCollateralRatio(chainId, 2e18);
        uint256 expected = 2e18 + (5000 * 50 * 2e18) / (10000 * 10000);
        assertEq(crEffective, expected, "System effective CR should scale correctly");
    }

    // ──────────────────────────────────────────────
    //  Minting Restrictions
    // ──────────────────────────────────────────────

    function testMintAllowedLowVol() public view {
        // LOW vol → any amount allowed
        bool allowed = volatilityShield.checkMintAllowed(chainId, address(collateral), 1000e18, 100e18);
        assertTrue(allowed, "LOW vol should allow any mint");
    }

    function testMintAllowedMediumVol() public {
        mockPyth.setPrice(2000, 60, -2); // MEDIUM
        bool allowed = volatilityShield.checkMintAllowed(chainId, address(collateral), 1000e18, 100e18);
        assertTrue(allowed, "MEDIUM vol should allow any mint");
    }

    function testMintCapBlocksLargeMints() public {
        mockPyth.setPrice(2000, 200, -2); // HIGH vol
        // totalSupply=1000e18, mintCapBps=1000 (10%), maxMint=100e18
        bool allowed = volatilityShield.checkMintAllowed(chainId, address(collateral), 200e18, 1000e18);
        assertFalse(allowed, "HIGH vol should block mint > 10% of supply");
    }

    function testMintCapAllowsSmallMints() public {
        mockPyth.setPrice(2000, 200, -2); // HIGH vol
        bool allowed = volatilityShield.checkMintAllowed(chainId, address(collateral), 50e18, 1000e18);
        assertTrue(allowed, "HIGH vol should allow mint <= 10% of supply");
    }

    function testMintCapAllowsExactCap() public {
        mockPyth.setPrice(2000, 200, -2); // HIGH vol
        bool allowed = volatilityShield.checkMintAllowed(chainId, address(collateral), 100e18, 1000e18);
        assertTrue(allowed, "HIGH vol should allow mint exactly at cap");
    }

    function testMintAllowedBootstrapping() public {
        mockPyth.setPrice(2000, 200, -2); // HIGH vol
        // totalSupply=0 → bootstrapping always allowed
        bool allowed = volatilityShield.checkMintAllowed(chainId, address(collateral), 1000e18, 0);
        assertTrue(allowed, "Bootstrapping should always be allowed");
    }

    // ──────────────────────────────────────────────
    //  Stale Data
    // ──────────────────────────────────────────────

    function testStaleDataReverts() public {
        vm.warp(1000);
        // Set publish time to 200 seconds ago (maxStaleness=60)
        mockPyth.setPublishTime(block.timestamp - 200);
        vm.expectRevert(); // MockPyth.StalePrice
        volatilityShield.getVolatilityIndex(chainId, address(collateral));
    }

    // ──────────────────────────────────────────────
    //  Invalid Price
    // ──────────────────────────────────────────────

    function testInvalidPriceReverts() public {
        mockPyth.setPrice(0, 10, -2);
        vm.expectRevert(VolatilityShield.VolatilityShield__InvalidPrice.selector);
        volatilityShield.getVolatilityIndex(chainId, address(collateral));
    }

    function testNegativePriceReverts() public {
        mockPyth.setPrice(-100, 10, -2);
        vm.expectRevert(VolatilityShield.VolatilityShield__InvalidPrice.selector);
        volatilityShield.getVolatilityIndex(chainId, address(collateral));
    }

    // ──────────────────────────────────────────────
    //  Owner Configuration
    // ──────────────────────────────────────────────

    function testOwnerCanUpdateThresholds() public {
        volatilityShield.setThresholds(100, 300);
        assertEq(volatilityShield.lowVolThreshold(), 100);
        assertEq(volatilityShield.highVolThreshold(), 300);
    }

    function testSetThresholdsRevertsIfInvalid() public {
        vm.expectRevert(VolatilityShield.VolatilityShield__InvalidThresholds.selector);
        volatilityShield.setThresholds(500, 200); // low >= high

        vm.expectRevert(VolatilityShield.VolatilityShield__InvalidThresholds.selector);
        volatilityShield.setThresholds(300, 300); // equal
    }

    function testNonOwnerCannotUpdateThresholds() public {
        vm.startPrank(nonOwner);
        vm.expectRevert();
        volatilityShield.setThresholds(100, 300);
        vm.stopPrank();
    }

    function testOwnerCanUpdateAlpha() public {
        volatilityShield.setAlpha(8000);
        assertEq(volatilityShield.alphaSensitivity(), 8000);
    }

    function testOwnerCanUpdateMintCap() public {
        volatilityShield.setMintCap(500);
        assertEq(volatilityShield.mintCapBps(), 500);
    }

    function testOwnerCanUpdateMaxStaleness() public {
        volatilityShield.setMaxStaleness(120);
        assertEq(volatilityShield.maxStaleness(), 120);
    }

    function testOwnerCanUpdatePythConfig() public {
        address newPyth = makeAddr("newPyth");
        bytes32 newId = bytes32(uint256(42));
        volatilityShield.setPythConfig(newPyth, newId);
        assertEq(address(volatilityShield.pyth()), newPyth);
        assertEq(volatilityShield.pythPriceId(), newId);
    }

    function testSetPythConfigRevertsOnZeroAddress() public {
        vm.expectRevert(VolatilityShield.VolatilityShield__ZeroAddress.selector);
        volatilityShield.setPythConfig(address(0), PRICE_ID);
    }

    function testConstructorRevertsOnZeroHelperConfig() public {
        vm.expectRevert(VolatilityShield.VolatilityShield__ZeroAddress.selector);
        new VolatilityShield(address(0), address(mockPyth));
    }

    function testConstructorRevertsOnZeroPythAddress() public {
        vm.expectRevert(VolatilityShield.VolatilityShield__ZeroAddress.selector);
        new VolatilityShield(address(helperConfig), address(0));
    }

    // ──────────────────────────────────────────────
    //  Events
    // ──────────────────────────────────────────────

    function testThresholdsUpdatedEvent() public {
        vm.expectEmit(false, false, false, true);
        emit VolatilityShield.ThresholdsUpdated(100, 300);
        volatilityShield.setThresholds(100, 300);
    }

    function testAlphaUpdatedEvent() public {
        vm.expectEmit(false, false, false, true);
        emit VolatilityShield.AlphaUpdated(8000);
        volatilityShield.setAlpha(8000);
    }

    function testMintCapUpdatedEvent() public {
        vm.expectEmit(false, false, false, true);
        emit VolatilityShield.MintCapUpdated(500);
        volatilityShield.setMintCap(500);
    }

    function testMaxStalenessUpdatedEvent() public {
        vm.expectEmit(false, false, false, true);
        emit VolatilityShield.MaxStalenessUpdated(120);
        volatilityShield.setMaxStaleness(120);
    }

    function testPythConfigUpdatedEvent() public {
        address newPyth = makeAddr("newPyth");
        bytes32 newId = bytes32(uint256(42));
        vm.expectEmit(false, false, false, true);
        emit VolatilityShield.PythConfigUpdated(newPyth, newId);
        volatilityShield.setPythConfig(newPyth, newId);
    }

    // ──────────────────────────────────────────────
    //  Custom Alpha Sensitivity
    // ──────────────────────────────────────────────

    function testHighAlphaScalesCRMoreAggressively() public {
        uint256 crDefault = volatilityShield.getEffectiveCollateralRatio(2e18, address(collateral), chainId);
        volatilityShield.setAlpha(10000); // 2x alpha
        uint256 crHighAlpha = volatilityShield.getEffectiveCollateralRatio(2e18, address(collateral), chainId);
        assertGt(crHighAlpha, crDefault, "Higher alpha should increase effective CR");
    }

    function testZeroAlphaLeavesBaseUnchanged() public {
        volatilityShield.setAlpha(0);
        uint256 crEffective = volatilityShield.getEffectiveCollateralRatio(2e18, address(collateral), chainId);
        assertEq(crEffective, 2e18, "Zero alpha should leave CR unchanged");
    }

    // ──────────────────────────────────────────────
    //  Custom Mint Cap
    // ──────────────────────────────────────────────

    function testCustomMintCapBlocksMore() public {
        mockPyth.setPrice(2000, 200, -2); // HIGH vol
        volatilityShield.setMintCap(500); // 5% cap (was 10%)
        // totalSupply=1000e18, maxMint=50e18 → 60e18 blocked
        bool allowed = volatilityShield.checkMintAllowed(chainId, address(collateral), 60e18, 1000e18);
        assertFalse(allowed, "5% cap should block 60e18 mint from 1000e18 supply");
    }
}
