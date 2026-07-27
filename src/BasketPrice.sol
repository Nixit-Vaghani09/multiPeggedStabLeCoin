// Layout of Contract:
// version
// imports
// errors
// interfaces, libraries, contracts
// Type declarations
// State variables
// Events
// Modifiers
// Functions

// Layout of Functions:
// constructor
// receive function (if exists)
// fallback function (if exists)
// external
// public
// internal
// private
// internal & private view & pure functions
// external & public view & pure functions

//SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {AggregatorV3Interface} from "@chainlink/contracts/src/v0.8/shared/interfaces/AggregatorV3Interface.sol";
import {HelperConfig} from "../script/HelperConfig.s.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {VolatilityShield} from "src/VolatilityShield.sol";

/// @title BasketPrice
/// @author Nixit Vaghani
/// @notice Core logic to manage a basket of Chainlink price feeds with weights.
/// @dev Provides weighted average basket price normalized to 18 decimals.
///      Allows adding collaterals, changing weights, and querying feed details.

contract BasketPrice is Ownable {
    /////////////////////////////
    //          errors         //
    /////////////////////////////
    error BasketPrice__FeedAlreadyExists();
    error BasketPrice__FeedNotFound();
    error BasketPrice__WeightSumZero();

    /////////////////////////////
    //   type declarations     //
    /////////////////////////////

    HelperConfig public helperConfig;
    VolatilityShield public volatilityShield;

    /////////////////////////////
    //     state Variables     //
    /////////////////////////////
    uint256 private constant PRECISION = 1e18;

    /////////////////////////////
    //        mappings         //
    /////////////////////////////

    /// @notice List of collateral addresses in the basket mapped by chainId
    mapping(uint256 => address[]) public basketCollaterals;

    /// @notice Mapping of chainId -> collateral address -> weight
    mapping(uint256 => mapping(address => uint256)) public collateralWeights;
    /////////////////////////////////
    //           events            //
    /////////////////////////////////
    event FeedAdded(uint256 indexed chainId, address indexed collateral, uint256 weight);
    event WeightChanged(uint256 indexed chainId, address indexed collateral, uint256 weight);
    event BasketPriceCalculated(uint256 indexed chainId, uint256 price);

    ///////////////////////////////
    //        functions          //
    ///////////////////////////////

    ///////////////////////////////
    //         constructor       //
    ///////////////////////////////
    /// @param _helperConfig   address of the helperConfig contract
    /// @param _volatilityShield  address of the volatilityShield contract
    constructor(address _helperConfig, address _volatilityShield) Ownable(msg.sender) {
        helperConfig = HelperConfig(_helperConfig);
        volatilityShield = VolatilityShield(_volatilityShield);
    }

    /// @notice Add a new collateral to the basket with a given weight
    /// @param collateral The address of the collateral token
    /// @param weight The weight assigned to this collateral in the basket calculation
    function addCollateral(address collateral, uint256 weight) external onlyOwner {
        _addCollateral(collateral, weight);
    }

    /// @notice Get the weighted average basket price
    /// @dev Normalizes each feed price to 18 decimals before applying weights
    /// @param chainId The chain ID to query collaterals for
    /// @return basketPrice The weighted average price of all collaterals in the basket (18 decimals)
    function getBasketPrice(uint256 chainId) external view returns (uint256) {
        return _getBasketPrice(chainId);
    }

    /// @notice Change the weight of an existing collateral
    /// @param collateral The collateral address whose weight is to be updated
    /// @param weight The new weight value
    function changeWeight(address collateral, uint256 weight) external onlyOwner {
        _changeWeight(collateral, weight);
    }

    //////////////////////////////
    //    internal functions    //
    //////////////////////////////
    /// @notice Helper function to fetch price and decimals from a Chainlink feed for a collateral
    /// @param chainId The chain ID
    /// @param index The index of the collateral in basketCollaterals
    /// @return price The latest price from the feed
    /// @return decimals The decimals used by the feed
    function _getPrice(uint256 chainId, uint256 index) internal view returns (uint256, uint8) {
        address collateral = basketCollaterals[chainId][index];
        (address priceFeed, uint8 decimals) = helperConfig.getFeed(chainId, collateral);
        (, int256 price,,,) = AggregatorV3Interface(priceFeed).latestRoundData();
        return (uint256(price), decimals);
    }

    function _addCollateral(address collateral, uint256 weight) internal {
        for (uint256 i = 0; i < basketCollaterals[block.chainid].length; i++) {
            if (basketCollaterals[block.chainid][i] == collateral) {
                revert BasketPrice__FeedAlreadyExists();
            }
        }
        basketCollaterals[block.chainid].push(collateral);
        collateralWeights[block.chainid][collateral] = weight;
        emit FeedAdded(block.chainid, collateral, weight);
    }

    function _getBasketPrice(uint256 chainId) internal view returns (uint256) {
        uint256 total = 0;
        uint256 totalWeight = 0;

        for (uint256 i = 0; i < basketCollaterals[chainId].length; i++) {
            (uint256 price, uint8 decimals) = _getPrice(chainId, i);

            // Normalize to 18 decimals
            price = price * (PRECISION / 10 ** decimals);
            total += uint256(price) * collateralWeights[chainId][basketCollaterals[chainId][i]];
            totalWeight += collateralWeights[chainId][basketCollaterals[chainId][i]];
        }

        if (totalWeight == 0) {
            revert BasketPrice__WeightSumZero();
        }
        uint256 basketPrice = total / totalWeight;
        uint256 damp = volatilityShield.getSystemDampeningFactor(chainId);
        return (basketPrice * damp) / PRECISION;
    }

    function _changeWeight(address collateral, uint256 weight) internal {
        bool exists = false;
        for (uint256 i = 0; i < basketCollaterals[block.chainid].length; i++) {
            if (basketCollaterals[block.chainid][i] == collateral) {
                exists = true;
                break;
            }
        }
        if (!exists) {
            revert BasketPrice__FeedNotFound();
        }
        collateralWeights[block.chainid][collateral] = weight;
        emit WeightChanged(block.chainid, collateral, weight);
    }

    //////////////////////////////
    //    pure functions        //
    //////////////////////////////
    /// @notice Get the collateral address at a given index
    /// @param chainId The chain ID
    /// @param index The index in the basketCollaterals array
    /// @return The address of the collateral
    function getCollateral(uint256 chainId, uint256 index) public view returns (address) {
        return basketCollaterals[chainId][index];
    }

    /// @notice Get the weight assigned to a specific collateral
    /// @param collateral The address of the collateral
    /// @return weight The weight value assigned to the collateral
    function getFeedWeight(address collateral) public view returns (uint256) {
        return collateralWeights[block.chainid][collateral];
    }

    /// @notice Get the Chainlink price feed address for a collateral
    /// @param collateral The collateral token address
    /// @return feed The price feed address
    function getCollateralFeed(address collateral) public view returns (address) {
        (address feed,) = helperConfig.getFeed(block.chainid, collateral);
        return feed;
    }

    function getPrecision() public pure returns (uint256) {
        return PRECISION;
    }
}
