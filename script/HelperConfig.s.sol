//SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {Script} from "lib/forge-std/src/Script.sol";
import {AggregatorV3Interface} from "@chainlink/contracts/src/v0.8/shared/interfaces/AggregatorV3Interface.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";

contract HelperConfig is Script, Ownable {
    constructor() Ownable(msg.sender) {}
    error HelperConfig__addressCantBeZero();
    error HelperConfig__CollateralDoesntExsist();
    error HelperConfig__PriceMustBeGreateThanZero();

    event CollateralAdded(uint256 chainId, address collateral, address pricefeed);

    struct CollateralConfig {
        address priceFeed;
        uint8 decimals;
        bool allowed;
    }

    mapping(uint256 chainId => mapping(address => CollateralConfig)) private collateralConfigs;
    mapping(uint256 chainId => address[]) private allCollaterals;
    mapping(uint256 chainId => address) pythAddresses;
    mapping(address collateral => bytes32 pythId) pythIds;

    // _______________________________________________________________
    //                  update functions
    //________________________________________________________________
    function addCollateral(uint256 chainId, address collateral, address pricefeed, bytes32 pythPriceId)
        public
        onlyOwner
    {
        if (collateral == address(0) || pricefeed == address(0)) {
            revert HelperConfig__addressCantBeZero();
        }

        uint8 collateralDecimals = AggregatorV3Interface(pricefeed).decimals();
        collateralConfigs[chainId][collateral] =
            CollateralConfig({priceFeed: pricefeed, decimals: collateralDecimals, allowed: true});
        pythIds[collateral] = pythPriceId;
        allCollaterals[chainId].push(collateral);
        emit CollateralAdded(chainId, collateral, pricefeed);
    }

    function addPythAddress(uint256 chainId, address pythAddress) public onlyOwner {
        if (pythAddress == address(0)) {
            revert HelperConfig__addressCantBeZero();
        }
        pythAddresses[chainId] = pythAddress;
    }

    function updatePythId(address collateral, bytes32 pythId) external onlyOwner {
        pythIds[collateral] = pythId;
    }

    function updatePriceFeed(uint256 chainId, address collateral, address priceFeed) external onlyOwner {
        if (collateral == address(0) || priceFeed == address(0)) {
            revert HelperConfig__addressCantBeZero();
        }
        collateralConfigs[chainId][collateral].priceFeed = priceFeed;
    }

    function updatePythAddress(uint256 chainId, address pythAddress) public onlyOwner {
        pythAddresses[chainId] = pythAddress;
    }

    function setCollateralEnabled(uint256 chainId, address collateral, bool enabled) external onlyOwner {
        collateralConfigs[chainId][collateral].allowed = enabled;
    }

    //____________________________________________________________________
    //                         getter functions
    //____________________________________________________________________

    //__________________________Price_________________________________

    function getNormalizedPrice(uint256 chainId, address collateral) internal view returns (uint256) {
        if (collateralConfigs[chainId][collateral].allowed == false) {
            revert HelperConfig__CollateralDoesntExsist();
        }

        (, int256 price,,,) = AggregatorV3Interface(collateralConfigs[chainId][collateral].priceFeed).latestRoundData();
        if (price <= 0) {
            revert HelperConfig__PriceMustBeGreateThanZero();
        }
        uint256 decimal = collateralConfigs[chainId][collateral].decimals;
        return uint256(price) * (1e18 / 10 ** decimal);
    }

    function getCollateralPrice(uint256 chainId, address collateral) external view returns (uint256) {
        CollateralConfig memory config = collateralConfigs[chainId][collateral];
        if (config.allowed == false) {
            revert HelperConfig__CollateralDoesntExsist();
        }
        uint256 price = getNormalizedPrice(chainId, collateral);
        return price;
    }

    // ___________________priceFeed________________________

    function getEnabledCollateralPriceFeeds(uint256 chainId) external view returns (address[] memory enabled) {
        uint256 count;
        address[] memory collaterals = allCollaterals[chainId];

        for (uint256 i = 0; i < collaterals.length; i++) {
            if (collateralConfigs[chainId][collaterals[i]].allowed) {
                count++;
            }
        }

        enabled = new address[](count);
        uint256 idx;
        for (uint256 i = 0; i < collaterals.length; i++) {
            if (collateralConfigs[chainId][collaterals[i]].allowed) {
                enabled[idx++] = collateralConfigs[chainId][collaterals[i]].priceFeed;
            }
        }
    }

    function getFeed(uint256 chainId, address collateral) external view returns (address, uint8) {
        if (collateralConfigs[chainId][collateral].allowed == false) {
            revert HelperConfig__CollateralDoesntExsist();
        }

        return (collateralConfigs[chainId][collateral].priceFeed, collateralConfigs[chainId][collateral].decimals);
    }

    //______________________Collaterals______________________________

    function getAllCollaterals(uint256 chainId) external view returns (address[] memory) {
        return allCollaterals[chainId];
    }

    function getEnabledCollaterals(uint256 chainId) external view returns (address[] memory enabled) {
        uint256 count;
        address[] memory collaterals = allCollaterals[chainId];
        for (uint256 i = 0; i < collaterals.length; i++) {
            if (collateralConfigs[chainId][collaterals[i]].allowed) {
                count++;
            }
        }
        enabled = new address[](count);
        uint256 idx;
        for (uint256 i = 0; i < collaterals.length; i++) {
            if (collateralConfigs[chainId][collaterals[i]].allowed) {
                enabled[idx++] = collaterals[i];
            }
        }
    }

    function getCollateralAllowed(uint256 chainId, address collateral) external view returns (bool) {
        return collateralConfigs[chainId][collateral].allowed;
    }

    //________________________pythId__________________________

    function getPythPriceId(address collateral, uint256 chainId) external view returns (bytes32) {
        if (collateralConfigs[chainId][collateral].allowed == false) {
            revert HelperConfig__CollateralDoesntExsist();
        }
        return pythIds[collateral];
    }

    function getPythAddress(uint256 chainId) external view returns (address) {
        return pythAddresses[chainId];
    }
}
