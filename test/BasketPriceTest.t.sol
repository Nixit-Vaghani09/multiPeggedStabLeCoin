//SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {Test} from "lib/forge-std/src/Test.sol";
import {BasketPrice} from "src/BasketPrice.sol";
import {HelperConfig} from "script/HelperConfig.s.sol";

contract BasketPriceTest is Test{
    BasketPrice basket;
    HelperConfig helperConfig;
    function setUp() external {
        helperConfig = new HelperConfig();
        basket=new BasketPrice(address(helperConfig));

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

    function testgetBasketPrice() external {

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
}