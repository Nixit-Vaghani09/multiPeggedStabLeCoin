// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {IPyth} from "@pythnetwork/pyth-sdk-solidity/IPyth.sol";
import {PythStructs} from "@pythnetwork/pyth-sdk-solidity/PythStructs.sol";

/// @title MockPyth
/// @notice Mock implementation of the Pyth oracle interface for testing.
/// @dev Allows tests to set arbitrary price, confidence, exponent, and publish time values.
contract MockPyth is IPyth {

    int64 private _price;
    uint64 private _conf;
    int32 private _expo;
    uint256 private _publishTime;

    /// @notice Error thrown when price data is stale
    error StalePrice();

    constructor(int64 price_, uint64 conf_, int32 expo_) {
        _price = price_;
        _conf = conf_;
        _expo = expo_;
        _publishTime = block.timestamp;
    }

    /// @notice Set the mock price data
    /// @param price_ The price value
    /// @param conf_ The confidence interval
    /// @param expo_ The price exponent
    function setPrice(int64 price_, uint64 conf_, int32 expo_) external {
        _price = price_;
        _conf = conf_;
        _expo = expo_;
        _publishTime = block.timestamp;
    }

    /// @notice Set the publish time explicitly (for staleness testing)
    /// @param publishTime_ The publish timestamp
    function setPublishTime(uint256 publishTime_) external {
        _publishTime = publishTime_;
    }

    /// @notice Implements IPyth.getPriceNoOlderThan
    /// @dev Reverts if the stored publish time is older than `age` seconds from now
    function getPriceNoOlderThan(bytes32, uint256 age) external view override returns (PythStructs.Price memory) {
        if (block.timestamp - _publishTime > age) {
            revert StalePrice();
        }
        return PythStructs.Price({
            price: _price,
            conf: _conf,
            expo: _expo,
            publishTime: _publishTime
        });
    }

    function getPriceUnsafe(bytes32) external view override returns (PythStructs.Price memory) {
        revert("Not implemented");
    }

    function getEmaPriceUnsafe(bytes32) external view override returns (PythStructs.Price memory) {
        revert("Not implemented");
    }

    function getEmaPriceNoOlderThan(bytes32, uint) external view override returns (PythStructs.Price memory) {
        revert("Not implemented");
    }

    function updatePriceFeeds(bytes[] calldata) external payable override {
        revert("Not implemented");
    }

    function updatePriceFeedsIfNecessary(bytes[] calldata, bytes32[] calldata, uint64[] calldata) external payable override {
        revert("Not implemented");
    }

    function getUpdateFee(bytes[] calldata) external view override returns (uint) {
        revert("Not implemented");
    }

    function getTwapUpdateFee(bytes[] calldata) external view override returns (uint) {
        revert("Not implemented");
    }

    function parsePriceFeedUpdates(bytes[] calldata, bytes32[] calldata, uint64, uint64) external payable override returns (PythStructs.PriceFeed[] memory) {
        revert("Not implemented");
    }

    function parsePriceFeedUpdatesUnique(bytes[] calldata, bytes32[] calldata, uint64, uint64) external payable override returns (PythStructs.PriceFeed[] memory) {
        revert("Not implemented");
    }

    function parsePriceFeedUpdatesWithConfig(bytes[] calldata, bytes32[] calldata, uint64, uint64, bool, bool, bool) external payable override returns (PythStructs.PriceFeed[] memory, uint64[] memory) {
        revert("Not implemented");
    }

    function parseTwapPriceFeedUpdates(bytes[] calldata, bytes32[] calldata) external payable override returns (PythStructs.TwapPriceFeed[] memory) {
        revert("Not implemented");
    }
}
