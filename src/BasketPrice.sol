//SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;


import {AggregatorV3Interface} from "@chainlink/contracts/src/v0.8/shared/interfaces/AggregatorV3Interface.sol";

contract BasketPrice{
    
    address[] public basketFeeds;
    mapping(address => uint256) public feedWeights;

    function addFeed(address feed,uint256 weight) external {
        basketFeeds.push(feed);
        feedWeights[feed]=weight;
    }

    function getBasketPrice() public view returns(uint256){
        uint256 total=0;
        uint256 weightSum=0;
        for(uint i=0;i<basketFeeds.length;i++)
        {
            (uint256 price,uint8 decimals)=_getPrice(i);
            price =price * (1e18/10**decimals);
            total+=uint256(price)*feedWeights[basketFeeds[i]];
            weightSum+=feedWeights[basketFeeds[i]];
        }
        return total/weightSum;
    }
    function _getPrice(uint256 index) internal view returns(uint256,uint8){
            (,int256 price,,,) = AggregatorV3Interface(basketFeeds[index]).latestRoundData();
            uint8 decimals = AggregatorV3Interface(basketFeeds[index]).decimals();
            return (uint256(price),decimals);    
    }

    function changeWeight(address feed,uint256 weight) external {
        feedWeights
        [feed]=weight;
    }


    function getPriceFeed(uint256 index) external view returns(address) {
        return basketFeeds[index];
    }

    function getFeedWeight(address priceFeed) external view returns(uint256) {
        return feedWeights[priceFeed];
    }

}