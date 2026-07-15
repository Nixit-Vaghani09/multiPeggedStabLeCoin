//SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {Script} from "lib/forge-std/src/Script.sol";
import {MultiToken} from "src/MultiToken.sol";
import {VolatilityShield} from "src/VolatilityShield.sol";
import {MTKEngine} from "src/MTKEngine.sol";
import {BasketPrice} from "src/BasketPrice.sol";
import {HelperConfig} from "script/HelperConfig.s.sol";

contract DeployMTK is Script {
    function run() external returns (MultiToken, MTKEngine, BasketPrice, VolatilityShield, HelperConfig) {
        vm.startBroadcast();

        HelperConfig helperConfig = new HelperConfig();
        VolatilityShield volatilityShield = new VolatilityShield(address(helperConfig));
        BasketPrice basket = new BasketPrice(address(helperConfig), address(volatilityShield));
        MultiToken mtk = new MultiToken(address(basket));
        MTKEngine mtkEngine =
            new MTKEngine(address(basket), address(mtk), address(helperConfig), address(volatilityShield));

        vm.stopBroadcast();
        return (mtk, mtkEngine, basket, volatilityShield, helperConfig);
    }
}
