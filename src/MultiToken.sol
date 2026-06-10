//SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

//////////////////////////
//      imports         //
//////////////////////////
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {BasketPrice} from "src/BasketPrice.sol";

/// @title MultiToken
/// @author Nixit Vaghani
/// @notice ERC20 stablecoin backed by a basket of collateral feeds.
/// @dev Extends OpenZeppelin ERC20 and Ownable. Only the owner (engine) can mint/burn.
///      Includes custom error handling for zero addresses, zero amounts, and insufficient balances.
contract MultiToken is ERC20,Ownable {


    /// @notice throws an error when a zero address is provided
    error MultiToken__ZeroAddress();
    
    /// @notice throws an error when amount is less than zero
    error MultiToken__AmountMustBeGreaterThanZero();

    /// @notice throws an error when burn amount exceeds user balance
    error MultiToken__AmountExceedsBalance();

    /// @notice BasketPrice contract used to fetch basket valuation
    BasketPrice private basket;
    
    
    
    constructor() ERC20("MultiToken","MTK") Ownable(msg.sender){
        basket=new BasketPrice();
    
        }

    /// @notice Mint new tokens to a recipient
    /// @dev Restricted to owner (engine). Validates non‑zero address and amount.
    /// @param to The recipient address
    /// @param amount The number of tokens to mint
    /// @return success True if mint succeeded
    /// @custom:error MultiToken__ZeroAddress Thrown if `to` is zero address
    /// @custom:error MultiToken__AmountMustBeGreaterThanZero Thrown if `amount` is zero
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

    /// @notice Burn tokens from a holder
    /// @dev Restricted to owner (engine). Validates non‑zero address, amount, and sufficient balance.
    /// @param from The address whose tokens will be burned
    /// @param amount The number of tokens to burn
    /// @return success True if burn succeeded
    /// @custom:error MultiToken__ZeroAddress Thrown if `from` is zero address
    /// @custom:error MultiToken__AmountMustBeGreaterThanZero Thrown if `amount` is zero
    /// @custom:error MultiToken__AmountExceedsBalance Thrown if `amount` exceeds balance
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

    /// @notice Transfer tokens to another address
    /// @dev Overrides ERC20 transfer with additional checks
    /// @param to The recipient address
    /// @param amount The number of tokens to transfer
    /// @return success True if transfer succeeded
    /// @custom:error MultiToken__ZeroAddress Thrown if `to` is zero address
    /// @custom:error MultiToken__AmountMustBeGreaterThanZero Thrown if `amount` is zero
    /// @custom:error MultiToken__AmountExceedsBalance Thrown if `amount` exceeds sender balance
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

    
    /// @notice Transfer tokens from one address to another using allowance
    /// @dev Overrides ERC20 transferFrom with additional checks
    /// @param from The address to transfer tokens from
    /// @param to The recipient address
    /// @param amount The number of tokens to transfer
    /// @return success True if transfer succeeded
    /// @custom:error MultiToken__ZeroAddress Thrown if `from` or `to` is zero address
    /// @custom:error MultiToken__AmountMustBeGreaterThanZero Thrown if `amount` is zero
    /// @custom:error MultiToken__AmountExceedsBalance Thrown if `amount` exceeds `from` balance
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

    /// @notice Get the current basket price from BasketPrice contract
    /// @dev Normalized to 18 decimals
    /// @return tokenPrice The basket price in 18 decimals
    function _getTokenPrice() public view returns(uint256 ){
        return basket.getBasketPrice();
    }
}