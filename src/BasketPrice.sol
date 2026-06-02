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

    function getBaketPrice() public view returns(uint256){
        uint256 total;
        uint256 weightSum;
        for(uint i=0;i<basketFeeds.length;i++)
        {
            uint256 price=_getPrice(i);
            total+=uint256(price)*feedWeights[basketFeeds[i]];
            weightSum=feedWeights[basketFeeds[i]];
        }
        return total/weightSum;
    }
    function _getPrice(uint256 index) internal view returns(uint256){
            (,int256 price,,,) = AggregatorV3Interface(basketFeeds[index]).latestRoundData();
            return uint256(price);    
    }

    function changeWeight(address feed,uint256 weight) external {
        feedWeights
        [feed]=weight;
    }

}