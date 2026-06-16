//SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;


import {AggregatorV3Interface} from "@chainlink/contracts/src/v0.8/shared/interfaces/AggregatorV3Interface.sol";
import {HelperConfig} from "../script/HelperConfig.s.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";

/// @title BasketPrice
/// @author Nixit Vaghani
/// @notice Core logic to manage a basket of Chainlink price feeds with weights.
/// @dev Provides weighted average basket price normalized to 18 decimals.
///      Allows adding feeds, changing weights, and querying feed details.

contract BasketPrice is Ownable {
    error BasketPrice__FeedAlreadyExists();
    error BasketPrice__FeedNotFound();
    error BasketPrice__WeightSumZero();

    event FeedAdded(uint256 indexed chainId, address indexed feed, uint256 weight);
    event WeightChanged(uint256 indexed chainId, address indexed feed, uint256 weight);
    event BasketPriceCalculated(uint256 indexed chainId, uint256 price);
    
    /// @notice List of collateral addresses in the basket mapped by chainId
    mapping(uint256 => address[]) public basketFeeds;

    HelperConfig public helperConfig;

    constructor(address _helperConfig) Ownable(msg.sender) {
        helperConfig = HelperConfig(_helperConfig);
    }


    /// @notice Mapping of feed address to its weight
    mapping(uint256 =>mapping(address => uint256)) public feedWeights;


    /// @notice Add a new feed to the basket with a given weight
    /// @param feed The address of the Chainlink price feed
    /// @param weight The weight assigned to this feed in the basket calculation
    function addFeed(address feed,uint256 weight) external onlyOwner {
        for(uint i = 0; i < basketFeeds[block.chainid].length; i++) {
            if(basketFeeds[block.chainid][i] == feed) {
                revert BasketPrice__FeedAlreadyExists();
            }
        }
        basketFeeds[block.chainid].push(feed);
        feedWeights[block.chainid][feed]=weight;
        emit FeedAdded(block.chainid, feed, weight);
    }



    /// @notice Get the weighted average basket price
    /// @dev Normalizes each feed price to 18 decimals before applying weights
    /// @return basketPrice The weighted average price of all feeds in the basket (18 decimals)
    
    function getBasketPrice() public returns(uint256){
        uint256 total=0;
        uint256 weightSum=0;
        for(uint i=0;i<basketFeeds[block.chainid].length;i++)
        {
            (uint256 price,uint8 decimals)=_getPrice(i);
            
            //updating the price to a standard 18 decimals notation
            price =price * (1e18/10**decimals);
            total+=uint256(price)*feedWeights[block.chainid][basketFeeds[block.chainid][i]];
            weightSum+=feedWeights[block.chainid][basketFeeds[block.chainid][i]];
        }
        if (weightSum == 0) {
            revert BasketPrice__WeightSumZero();
        }
        uint256 basketPrice = total / weightSum;
        emit BasketPriceCalculated(block.chainid, basketPrice);
        return basketPrice;
    }


    /// @notice helper function to fetch price and decimals from a feed
    /// @param index The index of the feed in the basketFeeds array
    /// @return price The latest price from the feed
    /// @return decimals The decimals used by the feed
    function _getPrice(uint256 index) internal view returns(uint256,uint8){
            (address priceFeed, uint8 decimals) = helperConfig.getFeed(basketFeeds[block.chainid][index]);
            (,int256 price,,,) = AggregatorV3Interface(priceFeed).latestRoundData();
            return (uint256(price),decimals);    
    }


    /// @notice Change the weight of an existing feed
    /// @param feed The address of the feed whose weight is to be updated
    /// @param weight The new weight value
    function changeWeight(address feed,uint256 weight) external onlyOwner {
        bool exists = false;
        for(uint i = 0; i < basketFeeds[block.chainid].length; i++) {
            if(basketFeeds[block.chainid][i] == feed) {
                exists = true;
                break;
            }
        }
        if(!exists) {
            revert BasketPrice__FeedNotFound();
        }
        feedWeights[block.chainid][feed]=weight;
        emit WeightChanged(block.chainid, feed, weight);
    }


    /// @notice Get the feed address at a given index
    /// @param index The index in the basketFeeds array
    /// @return feed The address of the feed
    function getPriceFeed(uint256 index) external view returns(address) {
        return basketFeeds[block.chainid][index];
    }


    /// @notice Get the weight assigned to a specific feed
    /// @param priceFeed The address of the feed
    /// @return weight The weight value assigned to the feed
    function getFeedWeight(address priceFeed) external view returns(uint256) {
        return feedWeights[block.chainid][priceFeed];
    }

}