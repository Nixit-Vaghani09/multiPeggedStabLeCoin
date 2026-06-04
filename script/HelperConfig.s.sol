//SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {Script} from "lib/forge-std/src/Script.sol";
import {AggregatorV3Interface} from "@chainlink/contracts/src/v0.8/shared/interfaces/AggregatorV3Interface.sol";
contract HelperConfig is Script {
   
   error HelperConfig__addressCantBeZero();
   error HelperConfig__CollateralDoesntExsist();
   error HelperConfig__PriceMustBeGreateThanZero();

   event CollateralAdded(address collateral,address pricefeed);

    struct collateralConfig {
        address priceFeed;
        uint8 decimals;
        bool allowed;
    }

    mapping(address => collateralConfig) public collateralConfigs;
    

    //would be an onlyowner 
    function addConfig(address collateral,address pricefeed ) public
    {
        if(collateral == address(0) || pricefeed==address(0))
        {
            revert HelperConfig__addressCantBeZero();
        }

        uint8 collateralDecimals = AggregatorV3Interface(pricefeed).decimals();
        collateralConfigs[collateral]=collateralConfig({
            priceFeed: pricefeed,
            decimals: collateralDecimals,
            allowed: true
        });
        emit CollateralAdded(collateral,pricefeed);
    }

    function getNormalizedPrice(address collateral) internal returns(uint256){
        if(collateralConfigs[collateral].allowed == false)
        {
            revert HelperConfig__CollateralDoesntExsist();
        }

        (,int256 price,,,)=AggregatorV3Interface(collateralConfigs[collateral].priceFeed).latestRoundData();
        if(price<=0)
        {
            revert HelperConfig__PriceMustBeGreateThanZero();
        }
        return uint256(price)*(10**(18-collateralConfigs[collateral].decimals));
    }

    function getFeed(address collateral) external view returns(address,uint8){
        if(collateralConfigs[collateral].allowed == false)
        {
            revert HelperConfig__CollateralDoesntExsist();
        }

        return(collateralConfigs[collateral].priceFeed,collateralConfigs[collateral].decimals);
    }

    function getCollateralPrice(address collateral) external view returns(uint256) {
        collateralConfig memory config= collateralConfigs[collateral];
        if(config.allowed == false)
        {
            revert HelperConfig__CollateralDoesntExsist();
        }
        uint256 price = getNormalizedPrice(collateral);
        return price;
    }

    function getCollateralAllowed(address collateral)external view returns(bool){
        return collateralConfigs[collateral].allowed;
    }
}