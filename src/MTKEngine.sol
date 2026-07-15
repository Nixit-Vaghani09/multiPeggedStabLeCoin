//SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {MultiToken} from "src/MultiToken.sol";
import {BasketPrice} from "src/BasketPrice.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {HelperConfig} from "script/HelperConfig.s.sol";
import {VolatilityShield} from "src/VolatilityShield.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

/// @title MTKEngine
/// @author Nixit Vaghani
/// @notice Core engine for minting and burning MTK stablecoin.
/// @dev Handles collateral deposits, withdrawals, and integrates basket + price feeds.
///      Manages user collateral balances, tracks user debt, ensures proper mint/burn lifecycle.
///      Integrates VolatilityShield for volatility-aware collateral ratio scaling.
///      Implements Health Factor tracking and Liquidation engine.

contract MTKEngine is ReentrancyGuard {
    // ──────────────────────────────────────────────
    //  Errors
    // ──────────────────────────────────────────────

    /// @notice error thrown if the amount is less than or equal to zero
    error MTKEngine__AmountMustBeMoreThanZero();
    /// @notice error thrown if the collateral balance of the user is less than the amount requested
    error MTKEngine__NotEnoughCollateralBalance();
    /// @notice error thrown if the collateral doesn't exist currently for our system
    error MTKEngine__CollateralNotAllowed();
    error MTKEngine__TransferFailed();
    /// @notice error thrown when minting is restricted due to high volatility
    error MTKEngine__MintingRestrictedHighVolatility();
    /// @notice error thrown when collateral is insufficient after volatility-adjusted CR
    error MTKEngine__InsufficientCollateralRatio();
    /// @notice error thrown if an action causes the user's Health Factor to drop below the threshold
    error MTKEngine__BreaksHealthFactor(uint256 healthFactor);
    /// @notice error thrown if a liquidator tries to liquidate a healthy position
    error MTKEngine__HealthFactorOk();
    /// @notice error thrown if liquidation did not improve the user's Health Factor
    error MTKEngine__HealthFactorNotImproved();
    error MTKEngine__NotEnoughDebt();

    // ──────────────────────────────────────────────
    //  Events
    // ──────────────────────────────────────────────

    /// @notice emitted when collateral is deposited successfully
    event DepositedSuccessfully(
        address indexed user, address indexed collateral, uint256 collateralAmount, uint256 tokenAmountMinted
    );
    /// @notice emitted when collateral is withdrawn successfully by burning MTK
    event WithdrawSuccessful(
        address indexed user, address indexed collateral, uint256 burnAmount, uint256 collateralReturned
    );
    /// @notice emitted when collateral is redeemed without burning MTK
    event CollateralRedeemed(address indexed user, address indexed collateral, uint256 indexed amount, uint256 chainId);
    /// @notice emitted when a deposit is adjusted by the volatility shield
    event VolatilityAdjustedDeposit(
        address indexed user, uint256 volatilityIndex, uint256 effectiveCR, uint256 dampenedMint
    );
    /// @notice emitted when an under-collateralized position is liquidated
    event Liquidated(
        address indexed liquidator,
        address indexed user,
        address indexed collateral,
        uint256 debtCovered,
        uint256 collateralRewarded
    );
    /// @notice emitted when collateral is deposited without minting
    event DepositedCollateralSuccessfully(
        address indexed depositor, address indexed collateral, uint256 indexed amount
    );

    // ──────────────────────────────────────────────
    //  State Variables
    // ──────────────────────────────────────────────

    //// @dev Reference to the `MultiToken` contract
    MultiToken mtk;
    //// @dev Reference to the `BasketPrice` contract
    BasketPrice basket;
    //// @dev Reference to the `HelperConfig` contract to check if collateral is valid and fetch its price
    HelperConfig helperConfig;
    /// @dev Reference to the VolatilityShield contract for volatility-aware logic
    VolatilityShield public volatilityShield;

    /// @notice Base collateral ratio in 1e18 (2e18 = 200%)
    /// @dev Scaled up by VolatilityShield during volatile markets
    uint256 public baseCollateralRatio = 2e18;

    // Liquidation Constants
    uint256 private constant LIQUIDATION_THRESHOLD = 15e17; // 150%
    uint256 public liquidation_bonus = 1e17; // 10%
    uint256 private constant PRECISION = 1e18;

    uint256 private constant MIN_CR = 1e18;
    uint256 private constant MAX_CR = 5e18;

    uint256 private constant MIN_BASKETPRICE = 1;
    uint256 private constant MAX_BASKETPRICE = 1e12;

    /// @notice mapping : user -> chainId -> collateral -> balance
    mapping(address => mapping(uint256 => mapping(address => uint256))) public userCollateralBalance;

    /// @notice mapping : user -> total MTK minted (debt)
    mapping(address => uint256) public userDebtBalance;

    // ──────────────────────────────────────────────
    //  Constructor
    // ──────────────────────────────────────────────

    constructor(
        address basketAddress,
        address multiAddress,
        address helperConfigAddress,
        address volatilityShieldAddress
    ) {
        mtk = MultiToken(multiAddress);
        basket = BasketPrice(basketAddress);
        helperConfig = HelperConfig(helperConfigAddress);
        volatilityShield = VolatilityShield(volatilityShieldAddress);
    }

    // ──────────────────────────────────────────────
    //  Core Functions
    // ──────────────────────────────────────────────

    /// @notice Deposit collateral and mint MTK stablecoin with volatility-aware adjustments
    /// @dev Transfers collateral from user, calculates USD value, computes allowed debt based on
    ///      volatility-adjusted CR, and applies dampening and mint caps if necessary.
    /// @param collateral The address of the collateral token
    /// @param collateralAmount The amount of collateral to deposit (must be > 0)
    function deposit(address collateral, uint256 collateralAmount) public nonReentrant {
        uint256 chainId = block.chainid;
        if (collateralAmount <= 0) revert MTKEngine__AmountMustBeMoreThanZero();
        if (!helperConfig.getCollateralAllowed(chainId, collateral)) revert MTKEngine__CollateralNotAllowed();

        IERC20(collateral).transferFrom(msg.sender, address(this), collateralAmount);
        userCollateralBalance[msg.sender][chainId][collateral] += collateralAmount;

        uint256 collateralPrice = helperConfig.getCollateralPrice(chainId, collateral);
        uint256 collateralValueUSD = collateralAmount * collateralPrice / PRECISION;

        uint256 effectiveCR = volatilityShield.getEffectiveCollateralRatio(baseCollateralRatio, collateral, chainId);

        // Max Debt USD allowed = collateralValueUSD / effectiveCR
        uint256 maxDebtUSD = (collateralValueUSD * PRECISION) / effectiveCR;

        uint256 basketPrice = basket.getBasketPrice(chainId);
        _validateBasketPrice(basketPrice);
        uint256 tokenAmountNormal = (maxDebtUSD * PRECISION) / basketPrice;

        uint256 dampeningFactor = volatilityShield.getDampeningFactor(chainId, collateral);
        uint256 tokenAmount = tokenAmountNormal * dampeningFactor / PRECISION;

        if (!volatilityShield.checkMintAllowed(chainId, collateral, tokenAmount, mtk.totalSupply())) {
            revert MTKEngine__MintingRestrictedHighVolatility();
        }

        (uint256 volatilityIndex,) = volatilityShield.getVolatilityIndex(chainId, collateral);

        mtk.mint(msg.sender, tokenAmount);
        userDebtBalance[msg.sender] += tokenAmount;

        _revertIfHealthFactorIsBroken(msg.sender);

        emit DepositedSuccessfully(msg.sender, collateral, collateralAmount, tokenAmount);
        emit VolatilityAdjustedDeposit(msg.sender, volatilityIndex, effectiveCR, tokenAmount);
    }

    /// @notice Withdraw collateral by burning MTK stablecoin
    /// @dev Burns MTK from user, calculates equivalent USD value, and releases collateral.
    ///      Verifies the user's Health Factor remains above the threshold after withdrawal.
    /// @param burnAmount The amount of MTK stablecoin to burn (must be > 0)
    /// @param collateral The address of the collateral token to withdraw
    function withdraw(uint256 burnAmount, address collateral) external nonReentrant {
        uint256 chainId = block.chainid;
        if (burnAmount <= 0) revert MTKEngine__AmountMustBeMoreThanZero();
        if (helperConfig.getCollateralAllowed(chainId, collateral) == false) revert MTKEngine__CollateralNotAllowed();

        uint256 basketPrice = basket.getBasketPrice(chainId);
        _validateBasketPrice(basketPrice);
        uint256 usdValue = burnAmount * basketPrice / PRECISION;

        uint256 collateralPrice = helperConfig.getCollateralPrice(chainId, collateral);
        uint256 collateralReturn = usdValue * PRECISION / collateralPrice;

        if (userCollateralBalance[msg.sender][chainId][collateral] < collateralReturn) {
            revert MTKEngine__NotEnoughCollateralBalance();
        }

        userCollateralBalance[msg.sender][chainId][collateral] -= collateralReturn;

        if (burnAmount > userDebtBalance[msg.sender]) {
            userDebtBalance[msg.sender] = 0;
        } else {
            userDebtBalance[msg.sender] -= burnAmount;
        }

        mtk.burn(msg.sender, burnAmount);
        IERC20(collateral).transfer(msg.sender, collateralReturn);

        _revertIfHealthFactorIsBroken(msg.sender);

        emit WithdrawSuccessful(msg.sender, collateral, burnAmount, collateralReturn);
    }

    /// @notice Redeem collateral directly without burning MTK
    /// @dev Allows users to withdraw excess collateral as long as their Health Factor remains safe.
    /// @param collateral The address of the collateral token to redeem
    /// @param amount The amount of collateral to redeem (must be > 0)
    function redeemCollateral(address collateral, uint256 amount) public nonReentrant {
        if (amount == 0) revert MTKEngine__AmountMustBeMoreThanZero();
        if (helperConfig.getCollateralAllowed(block.chainid, collateral) == false) {
            revert MTKEngine__CollateralNotAllowed();
        }
        if (amount > userCollateralBalance[msg.sender][block.chainid][collateral]) {
            revert MTKEngine__NotEnoughCollateralBalance();
        }

        userCollateralBalance[msg.sender][block.chainid][collateral] -= amount;
        emit CollateralRedeemed(msg.sender, collateral, amount, block.chainid);

        bool success = IERC20(collateral).transfer(msg.sender, amount);
        if (!success) revert MTKEngine__TransferFailed();

        _revertIfHealthFactorIsBroken(msg.sender);
    }

    /// @notice Burn MTK tokens to reduce debt
    /// @param amount The amount of MTK to burn (must be > 0 and <= user debt)
    function burnToken(uint256 amount) public nonReentrant {
        if (amount == 0) revert MTKEngine__AmountMustBeMoreThanZero();
        if (amount > userDebtBalance[msg.sender]) revert MTKEngine__NotEnoughDebt();
        mtk.burn(msg.sender, amount);
        userDebtBalance[msg.sender] -= amount;
    }

    /// @notice Deposit collateral without minting MTK (add collateral to existing position)
    /// @param collateral The collateral token address
    /// @param amount The amount of collateral to deposit
    function depositCollateral(address collateral, uint256 amount) external nonReentrant {
        if (amount == 0) revert MTKEngine__AmountMustBeMoreThanZero();
        uint256 chainId = block.chainid;
        if (!helperConfig.getCollateralAllowed(chainId, collateral)) revert MTKEngine__CollateralNotAllowed();

        IERC20(collateral).transferFrom(msg.sender, address(this), amount);
        userCollateralBalance[msg.sender][chainId][collateral] += amount;
        emit DepositedCollateralSuccessfully(msg.sender, collateral, amount);
    }

    // ──────────────────────────────────────────────
    //  Liquidation & Health Factor
    // ──────────────────────────────────────────────

    /// @notice Liquidate an under-collateralized position
    /// @dev Repays debt for a user whose Health Factor is < 150%, and rewards the liquidator
    ///      with equivalent collateral + a 10% bonus.
    /// @param collateral The collateral token to seize
    /// @param user The user who is under-collateralized
    /// @param debtToCover The amount of MTK debt the liquidator wants to repay
    function liquidate(address collateral, address user, uint256 debtToCover) external nonReentrant {
        uint256 startingHealthFactor = _healthFactor(user);
        if (startingHealthFactor >= LIQUIDATION_THRESHOLD) {
            revert MTKEngine__HealthFactorOk();
        }

        uint256 basketPrice = basket.getBasketPrice(block.chainid);
        _validateBasketPrice(basketPrice);
        uint256 debtValueUSD = (debtToCover * basketPrice) / PRECISION;

        uint256 collateralPrice = helperConfig.getCollateralPrice(block.chainid, collateral);
        uint256 collateralEquivalent = (debtValueUSD * PRECISION) / collateralPrice;

        uint256 bonusCollateral = (collateralEquivalent * liquidation_bonus) / PRECISION;
        uint256 totalCollateralToReward = collateralEquivalent + bonusCollateral;

        uint256 userCollateral = userCollateralBalance[user][block.chainid][collateral];
        if (totalCollateralToReward > userCollateral) {
            totalCollateralToReward = userCollateral; // Seize up to their max balance
        }

        userCollateralBalance[user][block.chainid][collateral] -= totalCollateralToReward;
        userDebtBalance[user] -= debtToCover;

        mtk.burn(msg.sender, debtToCover);

        bool success = IERC20(collateral).transfer(msg.sender, totalCollateralToReward);
        if (!success) revert MTKEngine__TransferFailed();

        uint256 endingHealthFactor = _healthFactor(user);
        if (endingHealthFactor <= startingHealthFactor) {
            revert MTKEngine__HealthFactorNotImproved();
        }

        emit Liquidated(msg.sender, user, collateral, debtToCover, totalCollateralToReward);
    }

    /// @notice Get total collateral value in USD and total MTK debt for a user
    function getAccountInformation(address user)
        public
        view
        returns (uint256 totalCollateralValueUSD, uint256 totalDebt)
    {
        totalDebt = userDebtBalance[user];
        uint256 chainId = block.chainid;
        address[] memory collaterals = helperConfig.getEnabledCollaterals(chainId);
        for (uint256 i = 0; i < collaterals.length; i++) {
            address token = collaterals[i];
            uint256 amount = userCollateralBalance[user][chainId][token];
            if (amount > 0) {
                uint256 price = helperConfig.getCollateralPrice(chainId, token);
                totalCollateralValueUSD += (amount * price) / PRECISION;
            }
        }
    }

    function getHealthFactor() external view returns (uint256) {
        return _healthFactor(msg.sender);
    }

    /// @notice Computes user's Health Factor
    /// @dev Returns (maxDebtAllowed * 1e18) / (debtInUSD). Values >= LIQUIDATION_THRESHOLD are healthy.
    function _healthFactor(address user) private view returns (uint256) {
        uint256 debt = userDebtBalance[user];
        if (debt == 0) {
            return type(uint256).max;
        }

        uint256 chainId = block.chainid;
        uint256 totalCollateralValueUSD = 0;
        address[] memory collaterals = helperConfig.getEnabledCollaterals(chainId);
        for (uint256 i = 0; i < collaterals.length; i++) {
            uint256 amt = userCollateralBalance[user][chainId][collaterals[i]];
            if (amt == 0) continue;
            uint256 price = helperConfig.getCollateralPrice(chainId, collaterals[i]);
            totalCollateralValueUSD += (amt * price) / PRECISION;
        }

        uint256 basketPrice = basket.getBasketPrice(chainId);
        _validateBasketPrice(basketPrice);

        // healthFactor = shieldedCR (collateral ratio dampened by current volatility)
        uint256 debtValueUSD = (debt * basketPrice) / PRECISION;
        uint256 rawCR = _effectiveCR(debtValueUSD, totalCollateralValueUSD);
        uint256 dampeningFactor = volatilityShield.getSystemDampeningFactor(chainId);
        uint256 shieldedCR = volatilityShield.adjustCR(rawCR, dampeningFactor);
        return shieldedCR;
    }

    /// @notice Reverts if user's Health Factor drops below the liquidation threshold
    function _revertIfHealthFactorIsBroken(address user) internal view {
        uint256 userHealthFactor = _healthFactor(user);
        if (userHealthFactor < LIQUIDATION_THRESHOLD) {
            revert MTKEngine__BreaksHealthFactor(userHealthFactor);
        }
    }

    function getPrecision() external pure returns (uint256) {
        return PRECISION;
    }

    function _effectiveCR(uint256 debtValue, uint256 collateralValue) internal pure returns (uint256) {
        if (debtValue == 0) return type(uint256).max;
        uint256 cr = (collateralValue * PRECISION) / debtValue;
        require(cr > MIN_CR, "Collateral Ratio less than minimum value of 100%");
        require(cr < MAX_CR, "Collateral Ratio more than maximum value of 500%");
        return cr;
    }

    function _validateBasketPrice(uint256 price) internal pure {
        require(MIN_BASKETPRICE * PRECISION <= price, "basket price is too low");
        require(MAX_BASKETPRICE * PRECISION >= price, "basket price is too high");
    }
}
