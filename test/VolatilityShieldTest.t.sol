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
        // Register pyth address in HelperConfig (new design: pyth resolved per chainId)
        helperConfig.addPythAddress(chainId, address(mockPyth));
        volatilityShield = new VolatilityShield(address(helperConfig));
    }

    // ──────────────────────────────────────────────
    //  Volatility Band Classification
    // ──────────────────────────────────────────────

    function testLowVolatilityBand() public view {
        // conf=10, price=2000 → V = 50 bps → LOW (< 200)
        (uint256 V, VolatilityShield.VolatilityBand band) =
            volatilityShield.getVolatilityIndex(chainId, address(collateral));
        assertEq(V, 50, "V should be 50 bps");
        assertEq(uint256(band), uint256(VolatilityShield.VolatilityBand.LOW), "Should be LOW band");
    }

    function testMediumVolatilityBand() public {
        // conf=60, price=2000 → V = 300 bps → MEDIUM (200 <= V < 500)
        mockPyth.setPrice(2000, 60, -2);
        (uint256 V, VolatilityShield.VolatilityBand band) =
            volatilityShield.getVolatilityIndex(chainId, address(collateral));
        assertEq(V, 300, "V should be 300 bps");
        assertEq(uint256(band), uint256(VolatilityShield.VolatilityBand.MEDIUM), "Should be MEDIUM band");
    }

    function testHighVolatilityBand() public {
        // conf=200, price=2000 → V = 1000 bps → HIGH (>= 500)
        mockPyth.setPrice(2000, 200, -2);
        (uint256 V, VolatilityShield.VolatilityBand band) =
            volatilityShield.getVolatilityIndex(chainId, address(collateral));
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

    function testConstructorRevertsOnZeroHelperConfig() public {
        vm.expectRevert(VolatilityShield.VolatilityShield__ZeroAddress.selector);
        new VolatilityShield(address(0));
    }

    // ── Pyth address is no longer a constructor arg; it is stored per-chainId in HelperConfig.
    // testConstructorRevertsOnZeroPythAddress removed — constructor no longer accepts _pythAddress.

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

    // testPythConfigUpdatedEvent removed — setPythConfig was deleted in the new design.
    // Pyth address management is now done through HelperConfig.addPythAddress / updatePythAddress.

    function testAddPythAddressAndGet() public {
        // addPythAddress sets the pyth oracle for a given chainId
        MockPyth newPyth = new MockPyth(3000, 20, -2);
        helperConfig.addPythAddress(chainId, address(newPyth));
        assertEq(
            helperConfig.getPythAddress(chainId), address(newPyth), "getPythAddress should return newly added address"
        );
    }

    function testUpdatePythAddress() public {
        MockPyth newPyth = new MockPyth(3000, 20, -2);
        helperConfig.updatePythAddress(chainId, address(newPyth));
        assertEq(
            helperConfig.getPythAddress(chainId),
            address(newPyth),
            "updatePythAddress should overwrite existing address"
        );
    }

    function testAddPythAddressRevertsIfZero() public {
        vm.expectRevert(HelperConfig.HelperConfig__addressCantBeZero.selector);
        helperConfig.addPythAddress(chainId, address(0));
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

    function testGetPrecision() public view {
        assertEq(volatilityShield.getPrecision(), 1e18);
    }

    // ──────────────────────────────────────────────
    //  adjustCR Tests
    // ──────────────────────────────────────────────

    /// @dev LOW vol: dampeningFactor = 1e18 (no dampening).
    ///      rawCR = 2e18 (200%). adjusted = 2e18 * 1e18 / 1e18 = 2e18 → in range → returned as-is.
    function testAdjustCR_LowVol_InRange() public view {
        uint256 rawCR = 2e18; // 200%
        uint256 dampening = 1e18; // LOW vol → no dampening
        uint256 adjusted = volatilityShield.adjustCR(rawCR, dampening);
        assertEq(adjusted, 2e18, "LOW vol: CR should stay at 200%");
    }

    /// @dev MEDIUM vol: dampeningFactor = 0.5e18.
    ///      rawCR = 3e18 (300%). adjusted = 3e18 * 0.5e18 / 1e18 = 1.5e18 → in range.
    function testAdjustCR_MediumVol_InRange() public view {
        uint256 rawCR = 3e18; // 300%
        uint256 dampening = 5e17; // MEDIUM vol → 50% dampening
        uint256 adjusted = volatilityShield.adjustCR(rawCR, dampening);
        assertEq(adjusted, 15e17, "MEDIUM vol: CR should be halved to 150%");
    }

    /// @dev HIGH vol: dampeningFactor = 0.1e18.
    ///      rawCR = 3e18 (300%). adjusted = 3e18 * 0.1e18 / 1e18 = 0.3e18 < MIN_CR(1e18) → clamped to 1e18.
    function testAdjustCR_HighVol_ClampedToMinCR() public view {
        uint256 rawCR = 3e18; // 300%
        uint256 dampening = 1e17; // HIGH vol → 90% dampening
        uint256 adjusted = volatilityShield.adjustCR(rawCR, dampening);
        // 3e18 * 1e17 / 1e18 = 0.3e18 < MIN_CR (1e18) → clamped
        assertEq(adjusted, 1e18, "HIGH vol: CR below MIN_CR should be clamped to 1e18 (100%)");
    }

    /// @dev rawCR is pushed above MAX_CR (5e18) by a very large dampening factor.
    ///      adjusted = 6e18 → clamped to MAX_CR = 5e18.
    function testAdjustCR_AboveMaxCR_ClampedToMaxCR() public view {
        // Dampening > 1 simulates an amplifying factor
        uint256 rawCR = 4e18; // 400%
        uint256 dampening = 2e18; // amplify × 2 → 8e18 > MAX_CR
        uint256 adjusted = volatilityShield.adjustCR(rawCR, dampening);
        assertEq(adjusted, 5e18, "CR above MAX_CR should be clamped to 5e18 (500%)");
    }

    /// @dev Identity check: dampening = 1e18 and rawCR right on the boundary.
    ///      MIN_CR < rawCR < MAX_CR → value passes through unchanged.
    function testAdjustCR_NoDampening_RetainsRawCR() public view {
        uint256 rawCR = 25e17; // 250% — well within [100%, 500%]
        uint256 dampening = 1e18; // identity
        uint256 adjusted = volatilityShield.adjustCR(rawCR, dampening);
        assertEq(adjusted, 25e17, "Identity dampening should return rawCR unchanged");
    }

    /// @dev Boundary: adjusted exactly at MIN_CR (1e18) — should NOT be clamped.
    function testAdjustCR_ExactlyMinCR_NotClamped() public view {
        uint256 rawCR = 2e18;
        uint256 dampening = 5e17; // 2e18 * 5e17 / 1e18 = 1e18 exactly
        uint256 adjusted = volatilityShield.adjustCR(rawCR, dampening);
        // adjusted == MIN_CR → condition is `adjusted < MIN_CR` so no clamp
        assertEq(adjusted, 1e18, "Adjusted exactly at MIN_CR should not be clamped");
    }

    /// @dev Boundary: adjusted exactly at MAX_CR (5e18) — should NOT be clamped.
    function testAdjustCR_ExactlyMaxCR_NotClamped() public view {
        uint256 rawCR = 5e18;
        uint256 dampening = 1e18; // 5e18 * 1e18 / 1e18 = 5e18 exactly
        uint256 adjusted = volatilityShield.adjustCR(rawCR, dampening);
        // adjusted == MAX_CR → condition is `adjusted > MAX_CR` so no clamp
        assertEq(adjusted, 5e18, "Adjusted exactly at MAX_CR should not be clamped");
    }
}

