//SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

//////////////////////////
//      imports         //
//////////////////////////
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {BasketPrice} from "src/BasketPrice.sol";


contract MultiToken is ERC20,Ownable {



    error MultiToken__ZeroAddress();
    error MultiToken__AmountMustBeGreaterThanZero();
    error MultiToken__AmountExceedsBalance();
    BasketPrice private basket;
    
    
    
    constructor() ERC20("MultiToken","MTK") Ownable(msg.sender){
        basket=new BasketPrice();
    
        }

    function mint(address to,uint256 amount) public onlyOwner returns(bool){
        if(to == address(0)){
            revert MultiToken__ZeroAddress();
        }
        if(amount == 0){
            revert MultiToken__AmountMustBeGreaterThanZero();
        }
        _mint(to,amount);
        return true;
    }

    function burn(address from,uint256 amount) public onlyOwner returns(bool){
        uint256 balance=balanceOf(from);
        if(from == address(0)){
            revert MultiToken__ZeroAddress();
        }
        if(amount == 0){
            revert MultiToken__AmountMustBeGreaterThanZero();
        }  
        if (amount > balance) {
            revert MultiToken__AmountExceedsBalance();
        }
        _burn(from,amount);
        return true;

    }

    function transfer(address to,uint256 amount) public override returns(bool){
        if(to == address(0)){
            revert MultiToken__ZeroAddress();

        }
        if(amount == 0){
            revert MultiToken__AmountMustBeGreaterThanZero();
        }

        if(amount > balanceOf(msg.sender))
        {
            revert MultiToken__AmountExceedsBalance();
        }
        return super.transfer(to,amount);
    }

    function transferFrom(address from,address to,uint256 amount) public override returns(bool){
        if(to == address(0) || from == address(0))
        {
            revert MultiToken__ZeroAddress();
        }
        if(amount == 0){
            revert MultiToken__AmountMustBeGreaterThanZero();
        }
        if(amount > balanceOf(from))
        {
            revert MultiToken__AmountExceedsBalance();
        }
        return super.transferFrom(from,to,amount);
    }



    function _getTokenPrice() public view returns(uint256 ){
        return basket.getBasketPrice();
    }
}