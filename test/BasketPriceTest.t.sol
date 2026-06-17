//SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {Test} from "lib/forge-std/src/Test.sol";
import {BasketPrice} from "src/BasketPrice.sol";
import {HelperConfig} from "script/HelperConfig.s.sol";
import {MockV3Aggregator} from "./mocks/MockV3Aggregator.sol";
import {ERC20Mock} from "./mocks/ERC20Mock.sol";

contract BasketPriceTest is Test{
    BasketPrice basket;
    HelperConfig helperConfig;
    ERC20Mock collateral;
    MockV3Aggregator mockV3Aggregator;
    function setUp() external {
        helperConfig = new HelperConfig();
        basket=new BasketPrice(address(helperConfig));
        collateral = new ERC20Mock("MockCollateral", "MCL",address(0),0);
        mockV3Aggregator = new MockV3Aggregator(8, 2000e8);
        helperConfig.addConfig(address(collateral),address(mockV3Aggregator));
    }

    function testAddFeedSuccessAndEmitsEvent() external {
        address priceFeed = makeAddr("ethpricefeed");
        
        vm.expectEmit(true, true, false, true);
        emit BasketPrice.FeedAdded(block.chainid, priceFeed, 40);
        
        basket.addFeed(priceFeed, 40);
        
        address basketPriceFeed = basket.getPriceFeed(0);
        assertEq(basketPriceFeed, priceFeed);
        uint256 weight = basket.getFeedWeight(basketPriceFeed);
        assertEq(weight, 40);
    }

    function testAddFeedRevertsIfFeedAlreadyExists() external {
        address priceFeed = makeAddr("ethpricefeed");
        basket.addFeed(priceFeed, 40);
        
        vm.expectRevert(BasketPrice.BasketPrice__FeedAlreadyExists.selector);
        basket.addFeed(priceFeed, 50);
    }

    function testAddFeedRevertsIfNotOwner() external {
        address priceFeed = makeAddr("ethpricefeed");
        address nonOwner = makeAddr("nonOwner");
        
        vm.startPrank(nonOwner);
        vm.expectRevert();
        basket.addFeed(priceFeed, 40);
        vm.stopPrank();
    }

    

    function testChangeWeightSuccessAndEmitsEvent() external {
        address priceFeed = makeAddr("ethpricefeed");
        basket.addFeed(priceFeed, 40);
        
        vm.expectEmit(true, true, false, true);
        emit BasketPrice.WeightChanged(block.chainid, priceFeed, 60);
        
        basket.changeWeight(priceFeed, 60);
        
        uint256 weight = basket.getFeedWeight(priceFeed);
        assertEq(weight, 60);
    }

    function testChangeWeightRevertsIfNotOwner() external {
        address priceFeed = makeAddr("ethpricefeed");
        basket.addFeed(priceFeed, 40);
        
        address nonOwner = makeAddr("nonOwner");
        
        vm.startPrank(nonOwner);
        vm.expectRevert();
        basket.changeWeight(priceFeed, 60);
        vm.stopPrank();
    }

    function testChangeWeightRevertsIfFeedNotFound() external {
        address invalidFeed = makeAddr("invalidFeed");
        
        vm.expectRevert(BasketPrice.BasketPrice__FeedNotFound.selector);
        basket.changeWeight(invalidFeed, 60);
    }

    function testgetBasketPriceRevertsIfWeightSumZero() external {
        vm.expectRevert(BasketPrice.BasketPrice__WeightSumZero.selector);
        basket.getBasketPrice();
    }

    function testgetBasketPriceSuccessAndEmitsEvent() external {
        basket.addFeed(address(mockV3Aggregator),40);
        uint256 totalPrice = basket.getBasketPrice();
        assertEq(totalPrice,2000e18);
    }
}