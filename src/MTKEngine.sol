//SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {MultiToken} from "src/MultiToken.sol";
import {BasketPrice} from "src/BasketPrice.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
contract MTKEngine {
    error MTKEngine__AmountMustBeMoreThanZero();
    error MTKEngine__AmountMustBeGreaterThanZero();
    error MTKEngine__NotEnoughCollateralBalance();

    event DepositedSuccessfully();
    event WithdrawSuccessful();
    
    MultiToken  mtk;
    BasketPrice basket;
    IERC20 collateralToken;

    mapping(address=>uint256) public collateralBalances;

    constructor(address basketAddress,address multiAddress,address collateralAddress){
        mtk= MultiToken(multiAddress);
        basket= BasketPrice(basketAddress);
        collateralToken= IERC20(collateralAddress);

    } 

    function deposit(uint256 collateralAmount) public {
        if(collateralAmount==0)
        {
            revert MTKEngine__AmountMustBeMoreThanZero();
        }
        //transfer collateral to engine 
        collateralToken.transferFrom(msg.sender,address(this),collateralAmount);
        //update user collateral balance
        collateralBalances[msg.sender]+=collateralAmount;

        //mint the token for the user
        uint256 basketPrice=basket.getBasketPrice();
        uint256 tokenAmount=collateralAmount * basketPrice;
        mtk.mint(msg.sender,tokenAmount);
        emit DepositedSuccessfully();
    }

    function withdraw(uint256 burnAmount) external {
        if(burnAmount<0)
        {
            revert MTKEngine__AmountMustBeGreaterThanZero();
        }
        // Calculate collateral to release (placeholder math)
        uint256 basketPrice = basket.getBasketPrice();
        uint256 collateralReturn = burnAmount / basketPrice;

        if(collateralBalances[msg.sender] >= collateralReturn) 
        {
            revert MTKEngine__NotEnoughCollateralBalance();
        }

        collateralBalances[msg.sender] -= collateralReturn;
        collateralToken.transfer(msg.sender, collateralReturn);

        // Burn stablecoin
        mtk.burn(msg.sender, burnAmount);
        emit WithdrawSuccessful();
    }

}