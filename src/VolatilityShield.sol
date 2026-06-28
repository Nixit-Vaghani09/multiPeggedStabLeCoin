//SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {IPyth} from "@pythnetwork/pyth-sdk-solidity/IPyth.sol";
import {PythStructs} from "@pythnetwork/pyth-sdk-solidity/PythStructs.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";

/// @title VolatilityShield
/// @author Nixit Vaghani
/// @notice Reads Pyth confidence intervals to classify market volatility and expose
///         collateral-ratio scaling, rebase dampening, and minting restriction logic.
/// @dev All threshold math uses basis points (10000 = 100%). Volatility index V is
///      computed as (conf * 10000) / |price|, giving a bps ratio of confidence to price.
contract VolatilityShield is Ownable {

    // ──────────────────────────────────────────────
    //  Errors
    // ──────────────────────────────────────────────

    error VolatilityShield__InvalidThresholds();
    error VolatilityShield__ZeroAddress();
    error VolatilityShield__StalePrice();
    error VolatilityShield__InvalidPrice();

    // ──────────────────────────────────────────────
    //  Events
    // ──────────────────────────────────────────────

    event ThresholdsUpdated(uint256 lowVolThreshold, uint256 highVolThreshold);
    event AlphaUpdated(uint256 alphaSensitivity);
    event MintCapUpdated(uint256 mintCapBps);
    event MaxStalenessUpdated(uint256 maxStaleness);
    event PythConfigUpdated(address pythAddress, bytes32 pythPriceId);

    // ──────────────────────────────────────────────
    //  Types
    // ──────────────────────────────────────────────

    /// @notice Volatility classification bands
    enum VolatilityBand {
        LOW,     // Normal operations
        MEDIUM,  // Reduced aggressiveness
        HIGH     // Restrict minting
    }

    // ──────────────────────────────────────────────
    //  State
    // ──────────────────────────────────────────────

    /// @notice The Pyth oracle contract
    IPyth public pyth;

    /// @notice The Pyth price feed ID to monitor (e.g. ETH/USD)
    bytes32 public pythPriceId;

    /// @notice Volatility index (bps) below which volatility is classified as LOW
    /// @dev Default: 200 bps = 2% of price
    uint256 public lowVolThreshold = 200;

    /// @notice Volatility index (bps) at or above which volatility is classified as HIGH
    /// @dev Default: 500 bps = 5% of price
    uint256 public highVolThreshold = 500;

    /// @notice Sensitivity factor α for collateral ratio scaling (in 1e4 precision)
    /// @dev Default: 5000 = 0.5 → CR_effective = CR_base × (1 + 0.5 × V)
    uint256 public alphaSensitivity = 5000;

    /// @notice Maximum staleness (seconds) for Pyth price data
    uint256 public maxStaleness = 60;

    /// @notice Maximum mint as basis points of total supply during HIGH volatility
    /// @dev Default: 1000 bps = 10%
    uint256 public mintCapBps = 1000;

    /// @dev Precision constant for basis points
    uint256 private constant BPS = 10000;

    /// @dev Precision constant for 18-decimal math
    uint256 private constant PRECISION = 1e18;

    // ──────────────────────────────────────────────
    //  Constructor
    // ──────────────────────────────────────────────

    /// @param _pythAddress The on-chain Pyth contract address
    /// @param _pythPriceId The bytes32 Pyth price feed ID to monitor
    constructor(address _pythAddress, bytes32 _pythPriceId) Ownable(msg.sender) {
        if (_pythAddress == address(0)) revert VolatilityShield__ZeroAddress();
        pyth = IPyth(_pythAddress);
        pythPriceId = _pythPriceId;
    }

    // ──────────────────────────────────────────────
    //  Core View Functions
    // ──────────────────────────────────────────────

    /// @notice Compute the volatility index and classify into a band
    /// @return V The volatility index in basis points (conf * 10000 / |price|)
    /// @return band The volatility classification (LOW, MEDIUM, HIGH)
    function getVolatilityIndex() public view returns (uint256 V, VolatilityBand band) {
        PythStructs.Price memory pythPrice = pyth.getPriceNoOlderThan(pythPriceId, maxStaleness);

        if (pythPrice.price <= 0) revert VolatilityShield__InvalidPrice();

        uint256 absPrice = uint256(uint64(pythPrice.price));
        uint256 conf = uint256(pythPrice.conf);

        // V = (conf * 10000) / |price|  → result in basis points
        V = (conf * BPS) / absPrice;

        if (V < lowVolThreshold) {
            band = VolatilityBand.LOW;
        } else if (V < highVolThreshold) {
            band = VolatilityBand.MEDIUM;
        } else {
            band = VolatilityBand.HIGH;
        }
    }

    /// @notice Calculate effective collateral ratio with volatility scaling
    /// @dev CR_effective = CR_base × (1 + α · V / 10000)
    ///      All math in 1e18 precision. α is in 1e4, V is in bps.
    /// @param CRbase The base collateral ratio in 1e18 (e.g. 1e18 = 100%)
    /// @return CReffective The volatility-adjusted collateral ratio in 1e18
    function getEffectiveCollateralRatio(uint256 CRbase) external view returns (uint256 CReffective) {
        (uint256 V, ) = getVolatilityIndex();

        // scalingFactor = 1 + (alpha * V) / (BPS * BPS)
        // In 1e18: PRECISION + (alphaSensitivity * V * PRECISION) / (BPS * BPS)
        uint256 scalingNumerator = alphaSensitivity * V * PRECISION;
        uint256 scalingFactor = PRECISION + (scalingNumerator / (BPS * BPS));

        CReffective = (CRbase * scalingFactor) / PRECISION;
    }

    /// @notice Get the dampening factor f(V) for rebase supply adjustments
    /// @dev Returns a multiplier in 1e18 precision:
    ///      LOW    → 1.0  (1e18)   — no dampening
    ///      MEDIUM → 0.5  (5e17)   — 50% dampening
    ///      HIGH   → 0.1  (1e17)   — 90% dampening
    /// @return factor The dampening multiplier in 1e18
    function getDampeningFactor() external view returns (uint256 factor) {
        (, VolatilityBand band) = getVolatilityIndex();

        if (band == VolatilityBand.LOW) {
            factor = PRECISION;           // 1.0
        } else if (band == VolatilityBand.MEDIUM) {
            factor = PRECISION / 2;       // 0.5
        } else {
            factor = PRECISION / 10;      // 0.1
        }
    }

    /// @notice Check whether a mint of `mintAmount` is allowed given current volatility
    /// @dev During HIGH volatility, mints are capped at `mintCapBps` of `currentTotalSupply`.
    ///      During LOW/MEDIUM volatility, all mints are allowed.
    ///      If totalSupply is 0, mints are always allowed (bootstrapping).
    /// @param mintAmount The proposed mint amount
    /// @param currentTotalSupply The current total supply of the stablecoin
    /// @return allowed True if the mint is permitted
    function checkMintAllowed(uint256 mintAmount, uint256 currentTotalSupply) external view returns (bool allowed) {
        (, VolatilityBand band) = getVolatilityIndex();

        if (band != VolatilityBand.HIGH) {
            return true;
        }

        // During HIGH volatility, allow bootstrapping (totalSupply == 0)
        if (currentTotalSupply == 0) {
            return true;
        }

        // Cap: mintAmount <= currentTotalSupply * mintCapBps / BPS
        uint256 maxMint = (currentTotalSupply * mintCapBps) / BPS;
        return mintAmount <= maxMint;
    }

    // ──────────────────────────────────────────────
    //  Owner Configuration
    // ──────────────────────────────────────────────

    /// @notice Update volatility band thresholds
    /// @param _lowVolThreshold New low volatility threshold (bps)
    /// @param _highVolThreshold New high volatility threshold (bps)
    function setThresholds(uint256 _lowVolThreshold, uint256 _highVolThreshold) external onlyOwner {
        if (_lowVolThreshold >= _highVolThreshold) revert VolatilityShield__InvalidThresholds();
        lowVolThreshold = _lowVolThreshold;
        highVolThreshold = _highVolThreshold;
        emit ThresholdsUpdated(_lowVolThreshold, _highVolThreshold);
    }

    /// @notice Update the alpha sensitivity factor
    /// @param _alphaSensitivity New alpha value in 1e4 precision
    function setAlpha(uint256 _alphaSensitivity) external onlyOwner {
        alphaSensitivity = _alphaSensitivity;
        emit AlphaUpdated(_alphaSensitivity);
    }

    /// @notice Update the minting cap for HIGH volatility
    /// @param _mintCapBps New cap in basis points of total supply
    function setMintCap(uint256 _mintCapBps) external onlyOwner {
        mintCapBps = _mintCapBps;
        emit MintCapUpdated(_mintCapBps);
    }

    /// @notice Update maximum staleness for Pyth data
    /// @param _maxStaleness New max staleness in seconds
    function setMaxStaleness(uint256 _maxStaleness) external onlyOwner {
        maxStaleness = _maxStaleness;
        emit MaxStalenessUpdated(_maxStaleness);
    }

    /// @notice Update the Pyth oracle address and price feed ID
    /// @param _pythAddress New Pyth contract address
    /// @param _pythPriceId New Pyth price feed ID
    function setPythConfig(address _pythAddress, bytes32 _pythPriceId) external onlyOwner {
        if (_pythAddress == address(0)) revert VolatilityShield__ZeroAddress();
        pyth = IPyth(_pythAddress);
        pythPriceId = _pythPriceId;
        emit PythConfigUpdated(_pythAddress, _pythPriceId);
    }
}
