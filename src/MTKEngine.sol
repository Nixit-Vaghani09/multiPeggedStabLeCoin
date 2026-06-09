//SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {MultiToken} from "src/MultiToken.sol";
import {BasketPrice} from "src/BasketPrice.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {HelperConfig} from "script/HelperConfig.s.sol";

contract MTKEngine {
    error MTKEngine__AmountMustBeMoreThanZero();
    error MTKEngine__AmountMustBeGreaterThanZero();
    error MTKEngine__NotEnoughCollateralBalance();
    error MTKEngine__CollateralNotAllowed();

    event DepositedSuccessfully();
    event WithdrawSuccessful();
    
    MultiToken  mtk;
    BasketPrice basket;
    IERC20 collateralToken;
    HelperConfig helperConfig;

    
    mapping(address => mapping(address=>uint256)) public userCollateralBalance;
    constructor(address basketAddress,address multiAddress,address collateralAddress,address helperConfigAddress){
        mtk= MultiToken(multiAddress);
        basket= BasketPrice(basketAddress);
        collateralToken= IERC20(collateralAddress);
        helperConfig=HelperConfig(helperConfigAddress);

    } 

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

    function withdraw(uint256 burnAmount,address collateral) external {
        if(burnAmount<=0)
        {
            revert MTKEngine__AmountMustBeGreaterThanZero();
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
        IERC20(collateral).transfer(msg.sender, collateralReturn);
        emit WithdrawSuccessful();
    }

}