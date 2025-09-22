// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import "forge-std/Script.sol";
import {IV4Router} from "@uniswap/v4-periphery/src/interfaces/IV4Router.sol";
import {Actions} from "@uniswap/v4-periphery/src/libraries/Actions.sol";
import {Commands} from "../src/libraries/Commands.sol";
import {ArbitrumConstants} from "../src/contracts/Constants.sol";
import {Currency, PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {IHooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";

contract HookSwapScript is Script, ArbitrumConstants {
    PoolKey internal poolKey;

    function run() public {
        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");

        // setup poolKey (must match the one used during deployment!)
        poolKey = PoolKey({
            currency0: Currency.wrap(address(0)), // ETH
            currency1: Currency.wrap(address(USDC)),
            fee: 3000,
            tickSpacing: 50,
            hooks: IHooks(address(0x3b7FC24025De469e70ad739A62F81ac3Ac25c8c0)) // put deployed hook address here
        });

        // example: swap 0.1 ETH -> USDC
        _swap(0.0001 ether, true, deployerPrivateKey);
    }

    function _swap(uint128 amountIn, bool zeroForOne, uint256 deployerPrivateKey) private {
        bytes memory commands = abi.encodePacked(uint8(Commands.V4_SWAP));
        bytes memory actions =
            abi.encodePacked(uint8(Actions.SWAP_EXACT_IN_SINGLE), uint8(Actions.SETTLE_ALL), uint8(Actions.TAKE_ALL));

        bytes[] memory params = new bytes[](3);
        params[0] = abi.encode(
            IV4Router.ExactInputSingleParams({
                poolKey: poolKey,
                zeroForOne: zeroForOne,
                amountIn: amountIn,
                amountOutMinimum: 0,
                hookData: bytes("")
            })
        );

        params[1] = abi.encode(zeroForOne ? poolKey.currency0 : poolKey.currency1, amountIn);
        params[2] = abi.encode(zeroForOne ? poolKey.currency1 : poolKey.currency0, 0);

        bytes[] memory inputs = new bytes[](1);
        inputs[0] = abi.encode(actions, params);
        uint256 deadline = block.timestamp + 60;
        vm.startBroadcast(deployerPrivateKey);

        if (!zeroForOne) {
            // Approve USDC (currency1) to Router via Permit2
            PERMIT2.approve(
                Currency.unwrap(poolKey.currency1), address(ROUTER), type(uint160).max, uint48(block.timestamp + 1 days)
            );
        }

        ROUTER.execute{value: zeroForOne ? amountIn : 0}(commands, inputs, deadline);

        vm.stopBroadcast();
    }
}
