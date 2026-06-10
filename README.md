# MTK Engine

A Decentralized Stablecoin Framework . Stable value through basket-backed collaterals .

## Description

MTKEngine is a decentralized stablecoin framework built with Solidity. It enables users to deposit multiple types of collateral, mint stablecoins, and withdraw collateral, all backed by a weighted basket of Chainlink price feeds. The system ensures stability by normalizing feed prices to 18 decimals, enforcing strict collateral checks, and maintaining transparent lifecycle events. Together, the three core contracts — BasketPrice, MultiToken, and MTKEngine — provide a modular foundation for building secure, community‑driven stablecoin systems .

## Architecture Overview

The MTKEngine system is composed of three core contracts that work together to enable a basket‑backed stablecoin:

### BasketPrice.sol

- Aggregates multiple Chainlink PriceFeeds .
- Normalizes feed price to 18 decimals .
- Calculate an average weighted basket price for the tokens minting and burning .

### MultiToken.sol

- An ERC20 stablecoin contract (MTK) .
- Minting and Burning restricted to the engine (owner) .
- Includes custom error handling for zero addresses , zero amounts and insufficient balances .

### MTKEngine.sol

    - Core engine that manages depsoits and withdrawals .
    - Transfer collaterals from user and locks in the engine and mints MTK token for the sender .
    - Burn MTK token during withdrawal of collaterals .
    - Intgrates with the HelperConfig script to fetch the collateral prices and check if they  are allowed.
    - Emits lifecycle events during successful withdrawals and deposits .

## Features

### ✅ Current Features

#### Basket Price

 - Add and manage multiple Chainlink price feeds.
 - Normalize feed prices to 18 decimals.
 - Calculate weighted average basket price.

#### Multi Token

 - ERC20 stablecoin with minting and burning restricted to the engine.
 - Custom error handling for zero addresses, zero amounts, and insufficient balances.
 - Safe transfer and transferFrom overrides with validation checks.

#### MTKEngine

 - Deposit collateral → mint MTK stablecoins.
 - Withdraw collateral → burn MTK and release collateral.
 - Tracks user collateral balances securely.
 - Integrates with [ HelperConfig ] to validate allowed collateral and fetch prices.
 - Events for success

### 🚀 Planned Features

#### Rebalancing Logic

 - Detect under‑collateralization.
 - Implement liquidation or partial burn policies.
 - Automatic adjustment of collateral ratios.

#### Multi‑Collateral Expansion

 - Support for ETH, USDC, BTC, and other assets.
 - Flexible collateral onboarding via governance.

#### Governance & DAO Integration

 - Community voting on collateral weights and parameters.
 - Upgradeable engine for future improvements.

#### Advanced Stability Mechanisms

 - Volatility shields and thresholds.
 - Dynamic mint/burn factors based on market conditions.

## Status disclaimer

This repository is not yet complete and is under active development.
Contracts, features, and documentation may change as the project evolves.

👉 Please always check if the repository has been updated before using, testing, or contributing.

## Contact
For questions, feedback, or collaboration, feel free to reach out:

Email-id : [Email Me](retrascout09@gmail.com)
