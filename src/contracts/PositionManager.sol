// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {ERC721} from "@solmate/tokens/ERC721.sol";
import {IPositionManager, ModifyLiquidityParams, PoolKey} from "../interfaces/IPositionManager.sol";
import {SafeCallback} from "@uniswap/v4-periphery/src/base/SafeCallback.sol";

import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";

import {CalldataLibrary, ResolveDeltaLibrary} from "../libraries/index.sol";

contract PositionManager is ERC721, IPositionManager, SafeCallback {
    using CalldataLibrary for bytes;
    using ResolveDeltaLibrary for BalanceDelta;

    uint256 public nextTokenId = 1;

    constructor(address _poolManager)
        ERC721("cXc Uniswap v4 Positions", "cXc-UNI-V4-POSM")
        SafeCallback(_poolManager)
    {}

    function _setMsgSender() internal {
        address sender = msg.sender;
        assembly {
            tstore(0x0, sender)
        }
    }

    function _msgSender() internal view returns (address sender) {
        assembly {
            sender := tload(0x0)
        }
    }

    function modifyLiquidity(PoolKey memory key, ModifyLiquidityParams calldata params, bytes memory hookData)
        external
    {
        _setMsgSender();
        poolManager.unlock(abi.encodeWithSelector(this.modifyLiquidity.selector, key, params, hookData));
    }

    function _modifyLiquidity(PoolKey memory key, ModifyLiquidityParams memory params, bytes memory hookData)
        internal
    {
        uint256 tokenId;
        unchecked {
            tokenId = nextTokenId++;
        }
        _mint(_msgSender(), tokenId);
        params.salt = bytes32(tokenId);
        (BalanceDelta callerDelta, BalanceDelta fees) = poolManager.modifyLiquidity(key, params, hookData);
        callerDelta.resolve(_msgSender(), key, poolManager);
        fees.resolve(_msgSender(), key, poolManager);
    }

    function tokenURI(uint256 /*tokenId**/ ) public pure override returns (string memory) {
        return "";
    }

    function _unlockCallback(bytes calldata data) internal override returns (bytes memory) {
        if (data.getSelector() == this.modifyLiquidity.selector) {
            (PoolKey memory key, ModifyLiquidityParams memory params, bytes memory hookData) =
                data.getModifyLiquidityParams();
            _modifyLiquidity(key, params, hookData);
        }
        return abi.encode(true);
    }

    fallback(bytes calldata) external returns (bytes memory) {}

    receive() external payable {}
}
