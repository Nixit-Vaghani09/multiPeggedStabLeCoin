//SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {Test, console} from "lib/forge-std/src/Test.sol";
import {VolatilityShield} from "src/VolatilityShield.sol";
import {MockPyth} from "./mocks/MockPyth.sol";

contract VolatilityShieldTest is Test {

    VolatilityShield volatilityShield;
    MockPyth mockPyth;

    bytes32 constant PRICE_ID = bytes32(uint256(1));
    address owner;
    address nonOwner = makeAddr("nonOwner");

    function setUp() public {
        owner = address(this);

        // Default: price = 2000, conf = 10 (0.5% = LOW volatility)
        // V = (10 * 10000) / 2000 = 50 bps → LOW
        mockPyth = new MockPyth(2000, 10, -2);
        volatilityShield = new VolatilityShield(address(mockPyth), PRICE_ID);
    }

    // ──────────────────────────────────────────────
    //  Volatility Band Classification
    // ──────────────────────────────────────────────

    function testLowVolatilityBand() public view {
        // conf=10, price=2000 → V = 50 bps → LOW (< 200)
        (uint256 V, VolatilityShield.VolatilityBand band) = volatilityShield.getVolatilityIndex();
        assertEq(V, 50, "V should be 50 bps");
        assertEq(uint256(band), uint256(VolatilityShield.VolatilityBand.LOW), "Should be LOW band");
    }

    function testMediumVolatilityBand() public {
        // conf=60, price=2000 → V = 300 bps → MEDIUM (200 ≤ V < 500)
        mockPyth.setPrice(2000, 60, -2);

        (uint256 V, VolatilityShield.VolatilityBand band) = volatilityShield.getVolatilityIndex();
        assertEq(V, 300, "V should be 300 bps");
        assertEq(uint256(band), uint256(VolatilityShield.VolatilityBand.MEDIUM), "Should be MEDIUM band");
    }

    function testHighVolatilityBand() public {
        // conf=200, price=2000 → V = 1000 bps → HIGH (≥ 500)
        mockPyth.setPrice(2000, 200, -2);

        (uint256 V, VolatilityShield.VolatilityBand band) = volatilityShield.getVolatilityIndex();
        assertEq(V, 1000, "V should be 1000 bps");
        assertEq(uint256(band), uint256(VolatilityShield.VolatilityBand.HIGH), "Should be HIGH band");
    }

    function testBoundaryLowToMedium() public {
        // conf=40, price=2000 → V = 200 bps → MEDIUM (threshold is <200 for LOW)
        mockPyth.setPrice(2000, 40, -2);

        (, VolatilityShield.VolatilityBand band) = volatilityShield.getVolatilityIndex();
        assertEq(uint256(band), uint256(VolatilityShield.VolatilityBand.MEDIUM), "200 bps should be MEDIUM");
    }

    function testBoundaryMediumToHigh() public {
        // conf=100, price=2000 → V = 500 bps → HIGH (threshold is <500 for MEDIUM)
        mockPyth.setPrice(2000, 100, -2);

        (, VolatilityShield.VolatilityBand band) = volatilityShield.getVolatilityIndex();
        assertEq(uint256(band), uint256(VolatilityShield.VolatilityBand.HIGH), "500 bps should be HIGH");
    }

    // ──────────────────────────────────────────────
    //  Effective Collateral Ratio Scaling
    // ──────────────────────────────────────────────

    function testEffectiveCRScalingLowVol() public view {
        // V=50 bps, alpha=5000/10000=0.5
        // scalingFactor = 1 + (5000 * 50) / (10000 * 10000) = 1 + 0.0025 = 1.0025
        // CR_effective = 1e18 * 1.0025 = 1.0025e18
        uint256 crEffective = volatilityShield.getEffectiveCollateralRatio(1e18);
        uint256 expected = 1e18 + (5000 * 50 * 1e18) / (10000 * 10000);
        assertEq(crEffective, expected, "CR should scale with V=50, alpha=0.5");
    }

    function testEffectiveCRScalingHighVol() public {
        // conf=200, price=2000 → V=1000 bps
        // scalingFactor = 1 + (5000 * 1000) / (10000 * 10000) = 1 + 0.05 = 1.05
        mockPyth.setPrice(2000, 200, -2);

        uint256 crEffective = volatilityShield.getEffectiveCollateralRatio(1e18);
        uint256 expected = 1e18 + (5000 * 1000 * 1e18) / (10000 * 10000);
        assertEq(crEffective, expected, "CR should scale with V=1000, alpha=0.5");
    }

    function testEffectiveCRWithCustomBase() public view {
        // CRbase = 1.5e18 (150%), V=50 bps
        uint256 crBase = 15e17; // 1.5e18
        uint256 crEffective = volatilityShield.getEffectiveCollateralRatio(crBase);
        uint256 scalingFactor = 1e18 + (5000 * 50 * 1e18) / (10000 * 10000);
        uint256 expected = (crBase * scalingFactor) / 1e18;
        assertEq(crEffective, expected, "CR should scale proportionally to base");
    }

    // ──────────────────────────────────────────────
    //  Dampening Factor
    // ──────────────────────────────────────────────

    function testDampeningFactorLow() public view {
        uint256 factor = volatilityShield.getDampeningFactor();
        assertEq(factor, 1e18, "LOW vol dampening should be 1.0");
    }

    function testDampeningFactorMedium() public {
        mockPyth.setPrice(2000, 60, -2); // V=300 → MEDIUM
        uint256 factor = volatilityShield.getDampeningFactor();
        assertEq(factor, 5e17, "MEDIUM vol dampening should be 0.5");
    }

    function testDampeningFactorHigh() public {
        mockPyth.setPrice(2000, 200, -2); // V=1000 → HIGH
        uint256 factor = volatilityShield.getDampeningFactor();
        assertEq(factor, 1e17, "HIGH vol dampening should be 0.1");
    }

    // ──────────────────────────────────────────────
    //  Minting Restrictions
    // ──────────────────────────────────────────────

    function testMintAllowedLowVol() public view {
        // LOW vol → any amount allowed
        bool allowed = volatilityShield.checkMintAllowed(1000e18, 100e18);
        assertTrue(allowed, "LOW vol should allow any mint");
    }

    function testMintAllowedMediumVol() public {
        mockPyth.setPrice(2000, 60, -2); // MEDIUM
        bool allowed = volatilityShield.checkMintAllowed(1000e18, 100e18);
        assertTrue(allowed, "MEDIUM vol should allow any mint");
    }

    function testMintCapBlocksLargeMints() public {
        mockPyth.setPrice(2000, 200, -2); // HIGH vol
        // totalSupply=1000, mintCapBps=1000(10%), maxMint=100
        bool allowed = volatilityShield.checkMintAllowed(200e18, 1000e18);
        assertFalse(allowed, "HIGH vol should block mint > 10% of supply");
    }

    function testMintCapAllowsSmallMints() public {
        mockPyth.setPrice(2000, 200, -2); // HIGH vol
        // totalSupply=1000, mintCapBps=1000(10%), maxMint=100
        bool allowed = volatilityShield.checkMintAllowed(50e18, 1000e18);
        assertTrue(allowed, "HIGH vol should allow mint <= 10% of supply");
    }

    function testMintCapAllowsExactCap() public {
        mockPyth.setPrice(2000, 200, -2); // HIGH vol
        // totalSupply=1000, mintCapBps=1000(10%), maxMint=100
        bool allowed = volatilityShield.checkMintAllowed(100e18, 1000e18);
        assertTrue(allowed, "HIGH vol should allow mint exactly at cap");
    }

    function testMintAllowedBootstrapping() public {
        mockPyth.setPrice(2000, 200, -2); // HIGH vol
        // totalSupply=0 → bootstrapping always allowed
        bool allowed = volatilityShield.checkMintAllowed(1000e18, 0);
        assertTrue(allowed, "Bootstrapping should always be allowed");
    }

    // ──────────────────────────────────────────────
    //  Stale Data
    // ──────────────────────────────────────────────

    function testStaleDataReverts() public {
        // Warp to a reasonable timestamp so subtraction doesn't underflow
        vm.warp(1000);
        // Set publish time to 200 seconds ago (maxStaleness=60)
        mockPyth.setPublishTime(block.timestamp - 200);

        vm.expectRevert(); // MockPyth.StalePrice
        volatilityShield.getVolatilityIndex();
    }

    // ──────────────────────────────────────────────
    //  Invalid Price
    // ──────────────────────────────────────────────

    function testInvalidPriceReverts() public {
        mockPyth.setPrice(0, 10, -2);
        vm.expectRevert(VolatilityShield.VolatilityShield__InvalidPrice.selector);
        volatilityShield.getVolatilityIndex();
    }

    function testNegativePriceReverts() public {
        mockPyth.setPrice(-100, 10, -2);
        vm.expectRevert(VolatilityShield.VolatilityShield__InvalidPrice.selector);
        volatilityShield.getVolatilityIndex();
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

    function testConstructorRevertsOnZeroAddress() public {
        vm.expectRevert(VolatilityShield.VolatilityShield__ZeroAddress.selector);
        new VolatilityShield(address(0), PRICE_ID);
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
}
