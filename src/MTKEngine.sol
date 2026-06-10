//SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {MultiToken} from "src/MultiToken.sol";
import {BasketPrice} from "src/BasketPrice.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {HelperConfig} from "script/HelperConfig.s.sol";


/// @title MTKEngine
/// @author Nixit Vaghani
/// @notice Core engine for minting and burning MTK stablecoin.
/// @dev Handles collateral deposits, withdrawals, and integrates basket + price feeds.
///      Manages user collateral balances and ensures proper mint/burn lifecycle.

contract MTKEngine {

    /// @notice error thrown if the amount is less than or equal to zero
    error MTKEngine__AmountMustBeMoreThanZero();

    /// @notice error thrown if the collateral balance of the user is less than the 
    ///         amount of token the user has
    error MTKEngine__NotEnoughCollateralBalance();

    /// @notice error thrown if the collateral doesn't exsist currently for our system
    error MTKEngine__CollateralNotAllowed();

    /// @notice emmitted when the collateral is deposited successfully
    event DepositedSuccessfully();
    
    /// @notice emmitted when the collateral is withdrawn successfully
    event WithdrawSuccessful();
    

    //// @dev Reference to the `MultiToken`  contract
    MultiToken  mtk;
    //// @dev Refrence to the `BasketPrice` contract 
    BasketPrice basket;
    
    //// @dev Reference to the `HelperConfig` contract 
    /// @notice to the check if the collateral is valid and fetch its price .
    HelperConfig helperConfig;

    /// @notice mapping : user -> collateral -> balance
    mapping(address => mapping(address=>uint256)) public userCollateralBalance;

    constructor(address basketAddress,address multiAddress,address helperConfigAddress){
        mtk= MultiToken(multiAddress);
        basket= BasketPrice(basketAddress);
        
        helperConfig=HelperConfig(helperConfigAddress);

    } 

    /// @notice Deposit collateral and mint MTK stablecoin
    /// @dev Transfers collateral from user, updates balance, calculates USD value, and mints MTK
    /// @param collateral The address of the collateral token
    /// @param collateralAmount The amount of collateral to deposit (must be > 0)
    /// @custom:error MTKEngine__AmountMustBeMoreThanZero Thrown if collateralAmount <= 0
    /// @custom:error MTKEngine__CollateralNotAllowed Thrown if collateral is not allowed
    /// @custom:event DepositedSuccessfully Emitted when deposit succeeds
    function deposit(address collateral,uint256 collateralAmount) public {
        if(collateralAmount<=0)
        {
            revert MTKEngine__AmountMustBeMoreThanZero();
        }
        if(helperConfig.getCollateralAllowed(collateral) == false)
        {
            revert MTKEngine__CollateralNotAllowed();
        }
        //transfer collateral to engine 
        IERC20(collateral).transferFrom(msg.sender,address(this),collateralAmount);

        //update user collateral balance .
        userCollateralBalance[msg.sender][collateral]+=collateralAmount;

        //get normalized 18 decimal collateral prize
        uint256 collateralPrice = helperConfig.getCollateralPrice(collateral);

        uint256 collateralValueUSD=collateralAmount * collateralPrice / 1e18; 
        //mint the token for the user
        uint256 basketPrice=basket.getBasketPrice();
        uint256 tokenAmount=collateralValueUSD * 1e18 / basketPrice;
        mtk.mint(msg.sender,tokenAmount);
        emit DepositedSuccessfully();
    }

    /// @notice Withdraw collateral by burning MTK stablecoin
    /// @dev Burns MTK from user, calculates USD value, and releases equivalent collateral
    /// @param burnAmount The amount of MTK stablecoin to burn (must be > 0)
    /// @param collateral The address of the collateral token to withdraw
    /// @custom:error MTKEngine__AmountMustBeGreaterThanZero Thrown if burnAmount <= 0
    /// @custom:error MTKEngine__CollateralNotAllowed Thrown if collateral is not allowed
    /// @custom:error MTKEngine__NotEnoughCollateralBalance Thrown if user’s collateral balance is insufficient
    /// @custom:event WithdrawSuccessful Emitted when withdrawal succeeds
    function withdraw(uint256 burnAmount,address collateral) external {
        if(burnAmount<=0)
        {
            revert MTKEngine__AmountMustBeMoreThanZero();
        }
        if(helperConfig.getCollateralAllowed(collateral) == false)
        {
            revert MTKEngine__CollateralNotAllowed();
        }


        uint256 basketPrice = basket.getBasketPrice();
        uint256 usdValue = burnAmount * basketPrice /1e18;

        // Calculate collateral to release (placeholder math)
        uint256 collateralPrice = helperConfig.getCollateralPrice(collateral);
        uint256 collateralReturn = usdValue *1e18/ collateralPrice;

        if(userCollateralBalance[msg.sender][collateral] < collateralReturn) 
        {
            revert MTKEngine__NotEnoughCollateralBalance();
        }

        userCollateralBalance[msg.sender][collateral] -= collateralReturn;

        // Burn stablecoin
        mtk.burn(msg.sender, burnAmount);

        //transfer the collateral
        IERC20(collateral).transfer(msg.sender, collateralReturn);
        emit WithdrawSuccessful();
    }

}