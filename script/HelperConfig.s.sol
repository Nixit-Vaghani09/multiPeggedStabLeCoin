//SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {Script} from "lib/forge-std/src/Script.sol";
import {AggregatorV3Interface} from "@chainlink/contracts/src/v0.8/shared/interfaces/AggregatorV3Interface.sol";

contract HelperConfig is Script {
    error HelperConfig__addressCantBeZero();
    error HelperConfig__CollateralDoesntExsist();
    error HelperConfig__PriceMustBeGreateThanZero();

    event CollateralAdded(uint256 chainId,address collateral, address pricefeed);

    struct CollateralConfig {
        address priceFeed;
        uint8 decimals;
        bool allowed;
    }

    mapping(uint256 chainId => mapping(address => CollateralConfig)) private collateralConfigs;

    //would be an onlyowner
    function addConfig(address collateral, address pricefeed) public {
        if (collateral == address(0) || pricefeed == address(0)) {
            revert HelperConfig__addressCantBeZero();
        }

        uint8 collateralDecimals = AggregatorV3Interface(pricefeed).decimals();
        uint256 chainId = block.chainid;
        collateralConfigs[chainId][collateral] = CollateralConfig({
            priceFeed: pricefeed,
            decimals: collateralDecimals,
            allowed: true
        });
        emit CollateralAdded(chainId,collateral, pricefeed);
    }

    function getNormalizedPrice(address collateral) internal returns (uint256) {
        if (collateralConfigs[block.chainid][collateral].allowed == false) {
            revert HelperConfig__CollateralDoesntExsist();
        }

        (, int256 price, , , ) = AggregatorV3Interface(
            collateralConfigs[block.chainid][collateral].priceFeed
        ).latestRoundData();
        if (price <= 0) {
            revert HelperConfig__PriceMustBeGreateThanZero();
        }
        uint256 decimal = collateralConfigs[block.chainid][collateral].decimals;
        return uint256(price) * (1e18 / 10 ** decimal);
    }

    function getFeed(
        address collateral
    ) external view returns (address, uint8) {
        if (collateralConfigs[block.chainid][collateral].allowed == false) {
            revert HelperConfig__CollateralDoesntExsist();
        }

        return (
            collateralConfigs[block.chainid][collateral].priceFeed,
            collateralConfigs[block.chainid][collateral].decimals
        );
    }

    function getCollateralPrice(address collateral) external returns (uint256) {
        CollateralConfig memory config = collateralConfigs[block.chainid][collateral];
        if (config.allowed == false) {
            revert HelperConfig__CollateralDoesntExsist();
        }
        uint256 price = getNormalizedPrice(collateral);
        return price;
    }

    function getCollateralAllowed(
        uint256 chainId,address collateral
    ) external view returns (bool) {
        return collateralConfigs[chainId][collateral].allowed;
    }
}
