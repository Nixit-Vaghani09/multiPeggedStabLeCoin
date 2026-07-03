//SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {Test} from "lib/forge-std/src/Test.sol";
import {BasketPrice} from "src/BasketPrice.sol";
import {HelperConfig} from "script/HelperConfig.s.sol";
import {MockV3Aggregator} from "./mocks/MockV3Aggregator.sol";
import {MockPyth} from "./mocks/MockPyth.sol";
import {ERC20Mock} from "./mocks/ERC20Mock.sol";

/// @title BasketPriceTest
/// @notice Tests for BasketPrice — addCollateral, changeWeight, getBasketPrice, getCollateral, getFeedWeight.
/// @dev Constructor signature changed: BasketPrice(helperConfig, pythAddress)
///      getBasketPrice() → getBasketPrice(chainId)
///      addFeed()        → addCollateral()    (collateral address, not price feed address)
///      getCollateral now requires (chainId, index)
contract BasketPriceTest is Test {
    BasketPrice basket;
    HelperConfig helperConfig;
    ERC20Mock collateral;
    ERC20Mock collateral2;
    MockV3Aggregator mockV3Aggregator;
    MockV3Aggregator mockV3Aggregator2;
    MockPyth mockPyth;

    bytes32 constant PRICE_ID = bytes32(uint256(1));
    uint256 chainId;

    function setUp() external {
        chainId = block.chainid;

        helperConfig = new HelperConfig();

        collateral = new ERC20Mock("MockCollateral", "MCL", msg.sender, 0);
        mockV3Aggregator = new MockV3Aggregator(8, 2000e8);

        collateral2 = new ERC20Mock("SecondToken", "TKN2", msg.sender, 0);
        mockV3Aggregator2 = new MockV3Aggregator(8, 4000e8);

        // Register collaterals in HelperConfig
        helperConfig.addCollateral(chainId, address(collateral), address(mockV3Aggregator), PRICE_ID);
        helperConfig.addCollateral(chainId, address(collateral2), address(mockV3Aggregator2), PRICE_ID);

        // Deploy MockPyth (LOW vol)
        mockPyth = new MockPyth(2000, 10, -2);

        // Deploy BasketPrice (requires helperConfig + pyth address)
        basket = new BasketPrice(address(helperConfig), address(mockPyth));
    }

    // ──────────────────────────────────────────────
    //  addCollateral Tests
    // ──────────────────────────────────────────────

    function testAddCollateralSuccessAndEmitsEvent() external {
        vm.expectEmit(true, true, false, true);
        emit BasketPrice.FeedAdded(chainId, address(collateral), 40);

        basket.addCollateral(address(collateral), 40);

        address basketCollateral = basket.getCollateral(chainId, 0);
        assertEq(basketCollateral, address(collateral));
        uint256 weight = basket.getFeedWeight(address(collateral));
        assertEq(weight, 40);
    }

    function testAddCollateralRevertsIfAlreadyExists() external {
        basket.addCollateral(address(collateral), 40);

        vm.expectRevert(BasketPrice.BasketPrice__FeedAlreadyExists.selector);
        basket.addCollateral(address(collateral), 50);
    }

    function testAddCollateralRevertsIfNotOwner() external {
        address nonOwner = makeAddr("nonOwner");

        vm.startPrank(nonOwner);
        vm.expectRevert();
        basket.addCollateral(address(collateral), 40);
        vm.stopPrank();
    }

    // ──────────────────────────────────────────────
    //  changeWeight Tests
    // ──────────────────────────────────────────────

    function testChangeWeightSuccessAndEmitsEvent() external {
        basket.addCollateral(address(collateral), 40);

        vm.expectEmit(true, true, false, true);
        emit BasketPrice.WeightChanged(chainId, address(collateral), 60);

        basket.changeWeight(address(collateral), 60);

        uint256 weight = basket.getFeedWeight(address(collateral));
        assertEq(weight, 60);
    }

    function testChangeWeightRevertsIfNotOwner() external {
        basket.addCollateral(address(collateral), 40);
        address nonOwner = makeAddr("nonOwner");

        vm.startPrank(nonOwner);
        vm.expectRevert();
        basket.changeWeight(address(collateral), 60);
        vm.stopPrank();
    }

    function testChangeWeightRevertsIfCollateralNotFound() external {
        vm.expectRevert(BasketPrice.BasketPrice__FeedNotFound.selector);
        basket.changeWeight(address(collateral), 60);
    }

    // ──────────────────────────────────────────────
    //  getBasketPrice Tests
    // ──────────────────────────────────────────────

    function testGetBasketPriceRevertsIfWeightSumZero() external {
        vm.expectRevert(BasketPrice.BasketPrice__WeightSumZero.selector);
        basket.getBasketPrice(chainId);
    }

    function testGetBasketPriceSingleCollateral() external {
        basket.addCollateral(address(collateral), 100); // MCL @ $2000
        uint256 price = basket.getBasketPrice(chainId);
        // At LOW vol (V=50 bps), systemDampening = 1.0 (PRECISION)
        // So basket price = $2000 * 1.0 = $2000e18
        assertEq(price, 2000e18, "Single collateral basket should return its price");
    }

    function testGetBasketPriceTwoEqualWeights() external {
        // collateral @ $2000, collateral2 @ $4000, equal weight 100 each
        // raw avg = (2000 + 4000) / 2 = $3000 → dampened by 1.0 = $3000
        basket.addCollateral(address(collateral), 100);
        basket.addCollateral(address(collateral2), 100);
        uint256 price = basket.getBasketPrice(chainId);
        assertEq(price, 3000e18, "Equal-weight basket should be average of both prices");
    }

    function testGetBasketPriceWeightedAverage() external {
        // collateral @ $2000 weight 1, collateral2 @ $4000 weight 3
        // weighted avg = (2000*1 + 4000*3) / 4 = $3500 → dampened by 1.0 = $3500
        basket.addCollateral(address(collateral), 1);
        basket.addCollateral(address(collateral2), 3);
        uint256 price = basket.getBasketPrice(chainId);
        assertEq(price, 3500e18, "Weighted basket price should be correct");
    }

    // ──────────────────────────────────────────────
    //  Getter Tests
    // ──────────────────────────────────────────────

    function testGetCollateral() external {
        basket.addCollateral(address(collateral), 50);
        basket.addCollateral(address(collateral2), 75);

        assertEq(basket.getCollateral(chainId, 0), address(collateral));
        assertEq(basket.getCollateral(chainId, 1), address(collateral2));
    }

    function testGetFeedWeight() external {
        basket.addCollateral(address(collateral), 40);
        assertEq(basket.getFeedWeight(address(collateral)), 40);
    }

    function testGetCollateralFeed() external {
        basket.addCollateral(address(collateral), 100);
        address feed = basket.getCollateralFeed(address(collateral));
        assertEq(feed, address(mockV3Aggregator), "Should return the Chainlink aggregator address");
    }

    // ──────────────────────────────────────────────
    //  VolatilityShield Integration
    // ──────────────────────────────────────────────

    function testVolatilityShieldDeployedByBasketPrice() external view {
        address vsAddr = address(basket.volatilityShield());
        assertTrue(vsAddr != address(0), "VolatilityShield should be deployed");
    }


    function testGetPrecision() public {
        assertEq(1e18,basket.getPrecision());
    }
}