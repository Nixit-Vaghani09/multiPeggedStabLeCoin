//SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import{Script} from "lib/forge-std/src/Script.sol";
import {MultiToken} from "src/MultiToken.sol";

contract DeployMTK is Script{
    function run() external returns(MultiToken){
        vm.startBroadcast();
        MultiToken mtk=new MultiToken();
        vm.stopBroadcast();
        return mtk;
    }
}