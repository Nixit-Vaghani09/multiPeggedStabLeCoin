//SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {Test} from "lib/forge-std/src/Test.sol";
import {BasketPrice} from "src/BasketPrice.sol";

contract BasketPriceTest is Test{
    BasketPrice basket;
    function setUp() external {
        vm.startBroadcast();
        basket=new BasketPrice();
        vm.stopBroadcast();

    }

    function testaddFeed() external {
        address priceFeed = makeAddr("ethpricefeed");
        basket.addFeed(priceFeed,40);
        address basketPriceFeed = basket.getPriceFeed(0);
        assertEq(basketPriceFeed,priceFeed);
        uint256 weight = basket.getFeedWeight(basketPriceFeed);
        assertEq(weight,40);
    }

    function testgetBasketPrice() external {

    }

    function testchangeWeight() external {
        
    }
}