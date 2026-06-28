//SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {MultiToken} from "src/MultiToken.sol";
import {BasketPrice} from "src/BasketPrice.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {HelperConfig} from "script/HelperConfig.s.sol";
import {VolatilityShield} from "src/VolatilityShield.sol";

/// @title MTKEngine
/// @author Nixit Vaghani
/// @notice Core engine for minting and burning MTK stablecoin.
/// @dev Handles collateral deposits, withdrawals, and integrates basket + price feeds.
///      Manages user collateral balances, tracks user debt, ensures proper mint/burn lifecycle.
///      Integrates VolatilityShield for volatility-aware collateral ratio scaling.
///      Implements Health Factor tracking and Liquidation engine.

contract MTKEngine {

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

    // ──────────────────────────────────────────────
    //  Events
    // ──────────────────────────────────────────────

    /// @notice emitted when collateral is deposited successfully
    event DepositedSuccessfully(address indexed user, address indexed collateral, uint256 collateralAmount, uint256 tokenAmountMinted);
    /// @notice emitted when collateral is withdrawn successfully by burning MTK
    event WithdrawSuccessful(address indexed user, address indexed collateral, uint256 burnAmount, uint256 collateralReturned);
    /// @notice emitted when collateral is redeemed without burning MTK
    event CollateralRedeemed(address indexed user, address indexed collateral, uint256 indexed amount, uint256 chainId);
    /// @notice emitted when a deposit is adjusted by the volatility shield
    event VolatilityAdjustedDeposit(address indexed user, uint256 volatilityIndex, uint256 effectiveCR, uint256 dampenedMint);
    /// @notice emitted when an under-collateralized position is liquidated
    event Liquidated(address indexed liquidator, address indexed user, address indexed collateral, uint256 debtCovered, uint256 collateralRewarded);

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
    uint256 private constant LIQUIDATION_BONUS = 1e17;      // 10%

    /// @notice mapping : user -> chainId -> collateral -> balance
    mapping(address => mapping(uint256 => mapping(address => uint256))) public userCollateralBalance;

    /// @notice mapping : user -> total MTK minted (debt)
    mapping(address => uint256) public userDebtBalance;

    /// @notice List of allowed collateral tokens for calculating total collateral value
    address[] public collateralTokens;

    // ──────────────────────────────────────────────
    //  Constructor
    // ──────────────────────────────────────────────

    constructor(
        address basketAddress,
        address multiAddress,
        address helperConfigAddress,
        address volatilityShieldAddress,
        address[] memory _collateralTokens
    ){
        mtk = MultiToken(multiAddress);
        basket = BasketPrice(basketAddress);
        helperConfig = HelperConfig(helperConfigAddress);
        volatilityShield = VolatilityShield(volatilityShieldAddress);
        collateralTokens = _collateralTokens;
    } 

    // ──────────────────────────────────────────────
    //  Core Functions
    // ──────────────────────────────────────────────

    /// @notice Deposit collateral and mint MTK stablecoin with volatility-aware adjustments
    /// @dev Transfers collateral from user, calculates USD value, computes allowed debt based on 
    ///      volatility-adjusted CR, and applies dampening and mint caps if necessary.
    /// @param collateral The address of the collateral token
    /// @param collateralAmount The amount of collateral to deposit (must be > 0)
    /// @custom:error MTKEngine__AmountMustBeMoreThanZero Thrown if collateralAmount <= 0
    /// @custom:error MTKEngine__CollateralNotAllowed Thrown if collateral is not allowed
    /// @custom:error MTKEngine__MintingRestrictedHighVolatility Thrown if minting is capped during HIGH volatility
    /// @custom:error MTKEngine__BreaksHealthFactor Thrown if the deposit leaves the user under-collateralized
    function deposit(address collateral, uint256 collateralAmount) public {
        uint256 chainId = block.chainid;
        if(collateralAmount <= 0) revert MTKEngine__AmountMustBeMoreThanZero();
        if(helperConfig.getCollateralAllowed(chainId, collateral) == false) revert MTKEngine__CollateralNotAllowed();
        
        IERC20(collateral).transferFrom(msg.sender, address(this), collateralAmount);
        userCollateralBalance[msg.sender][chainId][collateral] += collateralAmount;

        uint256 collateralPrice = helperConfig.getCollateralPrice(collateral);
        uint256 collateralValueUSD = collateralAmount * collateralPrice / 1e18; 
        
        uint256 effectiveCR = volatilityShield.getEffectiveCollateralRatio(baseCollateralRatio);
        
        // Max Debt USD allowed = collateralValueUSD / effectiveCR
        uint256 maxDebtUSD = (collateralValueUSD * 1e18) / effectiveCR;
        
        uint256 basketPrice = basket.getBasketPrice();
        uint256 tokenAmountNormal = (maxDebtUSD * 1e18) / basketPrice;

        uint256 dampeningFactor = volatilityShield.getDampeningFactor();
        uint256 tokenAmount = tokenAmountNormal * dampeningFactor / 1e18;

        if(!volatilityShield.checkMintAllowed(tokenAmount, mtk.totalSupply())) {
            revert MTKEngine__MintingRestrictedHighVolatility();
        }

        (uint256 volatilityIndex, ) = volatilityShield.getVolatilityIndex();

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
    /// @custom:error MTKEngine__AmountMustBeMoreThanZero Thrown if burnAmount <= 0
    /// @custom:error MTKEngine__CollateralNotAllowed Thrown if collateral is not allowed
    /// @custom:error MTKEngine__NotEnoughCollateralBalance Thrown if user's collateral balance is insufficient
    /// @custom:error MTKEngine__BreaksHealthFactor Thrown if the withdrawal leaves the user under-collateralized
    function withdraw(uint256 burnAmount, address collateral) external {
        uint256 chainId = block.chainid;
        if(burnAmount <= 0) revert MTKEngine__AmountMustBeMoreThanZero();
        if(helperConfig.getCollateralAllowed(chainId, collateral) == false) revert MTKEngine__CollateralNotAllowed();

        uint256 basketPrice = basket.getBasketPrice();
        uint256 usdValue = burnAmount * basketPrice / 1e18;

        uint256 collateralPrice = helperConfig.getCollateralPrice(collateral);
        uint256 collateralReturn = usdValue * 1e18 / collateralPrice;
        
        if(userCollateralBalance[msg.sender][chainId][collateral] < collateralReturn) {
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
    function redeemCollateral(address collateral, uint256 amount) public {
        if(amount == 0) revert MTKEngine__AmountMustBeMoreThanZero();
        if(helperConfig.getCollateralAllowed(block.chainid, collateral) == false) revert MTKEngine__CollateralNotAllowed();
        if(amount > userCollateralBalance[msg.sender][block.chainid][collateral]) revert MTKEngine__NotEnoughCollateralBalance();

        userCollateralBalance[msg.sender][block.chainid][collateral] -= amount;
        emit CollateralRedeemed(msg.sender, collateral, amount, block.chainid);
        
        bool success = IERC20(collateral).transfer(msg.sender, amount);
        if(!success) revert MTKEngine__TransferFailed();
        
        _revertIfHealthFactorIsBroken(msg.sender);
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
    function liquidate(address collateral, address user, uint256 debtToCover) external {
        uint256 startingHealthFactor = _healthFactor(user);
        if (startingHealthFactor >= LIQUIDATION_THRESHOLD) {
            revert MTKEngine__HealthFactorOk();
        }

        uint256 basketPrice = basket.getBasketPrice();
        uint256 debtValueUSD = (debtToCover * basketPrice) / 1e18;

        uint256 collateralPrice = helperConfig.getCollateralPrice(collateral);
        uint256 collateralEquivalent = (debtValueUSD * 1e18) / collateralPrice;

        uint256 bonusCollateral = (collateralEquivalent * LIQUIDATION_BONUS) / 1e18;
        uint256 totalCollateralToReward = collateralEquivalent + bonusCollateral;

        uint256 userCollateral = userCollateralBalance[user][block.chainid][collateral];
        if (totalCollateralToReward > userCollateral) {
            totalCollateralToReward = userCollateral; // Seize up to their max balance
        }

        userCollateralBalance[user][block.chainid][collateral] -= totalCollateralToReward;
        userDebtBalance[user] -= debtToCover;
        
        mtk.burn(msg.sender, debtToCover);

        bool success = IERC20(collateral).transfer(msg.sender, totalCollateralToReward);
        if(!success) revert MTKEngine__TransferFailed();

        uint256 endingHealthFactor = _healthFactor(user);
        if (endingHealthFactor <= startingHealthFactor) {
            revert MTKEngine__HealthFactorNotImproved();
        }

        emit Liquidated(msg.sender, user, collateral, debtToCover, totalCollateralToReward);
    }

    /// @notice Get total collateral value in USD and total MTK debt for a user
    function getAccountInformation(address user) public returns (uint256 totalCollateralValueUSD, uint256 totalDebt) {
        totalDebt = userDebtBalance[user];
        uint256 chainId = block.chainid;
        for (uint256 i = 0; i < collateralTokens.length; i++) {
            address token = collateralTokens[i];
            uint256 amount = userCollateralBalance[user][chainId][token];
            if (amount > 0) {
                uint256 price = helperConfig.getCollateralPrice(token);
                totalCollateralValueUSD += (amount * price) / 1e18;
            }
        }
    }

    /// @notice Computes user's Collateral Ratio
    /// @dev Returns CollateralValueUSD * 1e18 / DebtValueUSD
    function _healthFactor(address user) private returns (uint256) {
        (uint256 totalCollateralValueUSD, uint256 totalDebt) = getAccountInformation(user);
        if (totalDebt == 0) return type(uint256).max;
        
        uint256 basketPrice = basket.getBasketPrice();
        uint256 debtValueUSD = (totalDebt * basketPrice) / 1e18;
        
        return (totalCollateralValueUSD * 1e18) / debtValueUSD;
    }

    /// @notice Reverts if user's Health Factor drops below the liquidation threshold
    function _revertIfHealthFactorIsBroken(address user) internal {
        uint256 userHealthFactor = _healthFactor(user);
        if (userHealthFactor < LIQUIDATION_THRESHOLD) {
            revert MTKEngine__BreaksHealthFactor(userHealthFactor);
        }
    }
}