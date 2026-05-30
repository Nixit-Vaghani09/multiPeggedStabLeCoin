//SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

//////////////////////////
//      imports         //
//////////////////////////
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";



contract MultiToken is ERC20,Ownable {



    error MultiToken__MintToZeroAddress();
    error MultiToken__AmountMustBeGreaterThanZero();
    error MultiToken__AmountExceedsBalance();
    
    
    mapping(address => uint256) private
    
    
    constructor() ERC20("MultiToken","MTK") Ownable(msg.sender){

    }

    function mint(address to,uint256 amount) public onlyOwner {
        if(to == address(0)){
            revert MultiToken__MintToZeroAddress();
        }
        if(amount == 0){
            revert MultiToken__AmountMustBeGreaterThanZero();
        }
        _mint(to,amount);
    }

    function burn(address from,uint256 amount) public onlyOwner {
        uint256 balance=balanceOf(from);
        if(from == address(0)){
            revert MultiToken__MintToZeroAddress();
        }
        if(amount == 0){
            revert MultiToken__AmountMustBeGreaterThanZero();
        }  
        if (amount > balance) {
            revert MultiToken__AmountExceedsBalance();
        }
        _burn(from,amount);

    }

    function transfer(address to,uint256 amount) public override returns(bool){
        if(to == address(0)){
            revert MultiToken__MintToZeroAddress();

        }
        if(amount == 0){
            revert MultiToken__AmountMustBeGreaterThanZero();
        }
        return super.transfer(to,amount);
    }

    function transferFrom(address from,address to,uint256 amount) pulbic override returns(bool){
        if(to == address(0) || from == address(0))
        {
            revert MultiToken__MintToZeroAddress();
        }
        if(amount == 0){
            revert MultiToken__AmountMustBeGreaterThanZero();
        }
        return super.transferFrom(from,to,amount);
    }
}