// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import "forge-std/Script.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {HookMiner} from "@uniswap/v4-periphery/src/utils/HookMiner.sol";

import {AbritrumConstants} from "../src/contracts/Constants.sol";
import {SymbioteHook} from "../src/SymbioteHook.sol";
import {HookDeployer} from "../src/contracts/HookDeployer.sol";

contract HookScript is Script, AbritrumConstants {
    function setUp() public {}

    function run() public {
        uint160 flags = uint160(
            Hooks.BEFORE_SWAP_FLAG | Hooks.AFTER_SWAP_FLAG | Hooks.BEFORE_ADD_LIQUIDITY_FLAG
                | Hooks.AFTER_INITIALIZE_FLAG
        );

        uint160[] memory _flags = new uint160[](4);
        _flags[0] = Hooks.BEFORE_SWAP_FLAG;
        _flags[1] = Hooks.AFTER_SWAP_FLAG;
        _flags[2] = Hooks.BEFORE_ADD_LIQUIDITY_FLAG;
        _flags[3] = Hooks.AFTER_INITIALIZE_FLAG;

        bytes memory constructorArgs = abi.encode(0xEC08EfF77496601BE56c11028A516366DbF03F13, POOL_MANAGER, WETH, AAVE_POOL);
        (address hookAddress, bytes32 salt) =
            HookMiner.find(address(HOOK_DEPLOYER), flags, type(SymbioteHook).creationCode, constructorArgs);


        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");
        vm.broadcast(deployerPrivateKey);
        address hook =
            HOOK_DEPLOYER.safeDeploy(type(SymbioteHook).creationCode, constructorArgs, salt, hookAddress, _flags);

        require(hook == hookAddress, "Hook address mismatch");
    }
}
