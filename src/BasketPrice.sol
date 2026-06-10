//SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;


import {AggregatorV3Interface} from "@chainlink/contracts/src/v0.8/shared/interfaces/AggregatorV3Interface.sol";

/// @title BasketPrice
/// @author Nixit Vaghani
/// @notice Core logic to manage a basket of Chainlink price feeds with weights.
/// @dev Provides weighted average basket price normalized to 18 decimals.
///      Allows adding feeds, changing weights, and querying feed details.

contract BasketPrice{
    
    /// @notice List of price feed addresses in the basket
    address[] public basketFeeds;


    /// @notice Mapping of feed address to its weight
    mapping(address => uint256) public feedWeights;


    /// @notice Add a new feed to the basket with a given weight
    /// @param feed The address of the Chainlink price feed
    /// @param weight The weight assigned to this feed in the basket calculation
    function addFeed(address feed,uint256 weight) external {
        basketFeeds.push(feed);
        feedWeights[feed]=weight;
    }



    /// @notice Get the weighted average basket price
    /// @dev Normalizes each feed price to 18 decimals before applying weights
    /// @return basketPrice The weighted average price of all feeds in the basket (18 decimals)
    
    function getBasketPrice() public view returns(uint256){
        uint256 total=0;
        uint256 weightSum=0;
        for(uint i=0;i<basketFeeds.length;i++)
        {
            (uint256 price,uint8 decimals)=_getPrice(i);
            
            //updating the price to a standard 18 decimals notation
            price =price * (1e18/10**decimals);
            total+=uint256(price)*feedWeights[basketFeeds[i]];
            weightSum+=feedWeights[basketFeeds[i]];
        }
        return total/weightSum;
    }


    /// @notice helper function to fetch price and decimals from a feed
    /// @param index The index of the feed in the basketFeeds array
    /// @return price The latest price from the feed
    /// @return decimals The decimals used by the feed
    function _getPrice(uint256 index) internal view returns(uint256,uint8){
            (,int256 price,,,) = AggregatorV3Interface(basketFeeds[index]).latestRoundData();
            uint8 decimals = AggregatorV3Interface(basketFeeds[index]).decimals();
            return (uint256(price),decimals);    
    }


    /// @notice Change the weight of an existing feed
    /// @param feed The address of the feed whose weight is to be updated
    /// @param weight The new weight value
    function changeWeight(address feed,uint256 weight) external {
        feedWeights
        [feed]=weight;
    }


    /// @notice Get the feed address at a given index
    /// @param index The index in the basketFeeds array
    /// @return feed The address of the feed
    function getPriceFeed(uint256 index) external view returns(address) {
        return basketFeeds[index];
    }


    /// @notice Get the weight assigned to a specific feed
    /// @param priceFeed The address of the feed
    /// @return weight The weight value assigned to the feed
    function getFeedWeight(address priceFeed) external view returns(uint256) {
        return feedWeights[priceFeed];
    }

}